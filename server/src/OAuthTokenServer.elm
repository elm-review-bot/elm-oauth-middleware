----------------------------------------------------------------------
--
-- OAuthTokenServer.elm
-- Top-level file for OAuthMiddleware redirectBackUri server.
-- Copyright (c) 2017 Bill St. Clair <billstclair@gmail.com>
-- Some rights reserved.
-- Distributed under the MIT License
-- See LICENSE.txt
--
----------------------------------------------------------------------


port module OAuthTokenServer exposing (main)

import Base64
import Debug
import Dict exposing (Dict)
import Erl
import Erl.Query as Q
import Http
import Json.Decode as JD
import Json.Encode as JE
import List.Extra as LE
import OAuth exposing (ResponseToken)
import OAuth.AuthorizationCode
import OAuth.Decode as OD exposing (AdjustRequest)
import OAuthMiddleware.EncodeDecode as ED exposing (RedirectState)
import OAuthMiddleware.ServerConfiguration
    exposing
        ( LocalServerConfiguration
        , RemoteServerConfiguration
        , configurationsDecoder
        , defaultLocalServerConfiguration
        )
import Platform
import Server.Http
import Time exposing (Time)


port getFile : String -> Cmd msg


port receiveFile : (Maybe String -> msg) -> Sub msg


port httpListen : Int -> Cmd msg


type alias RedirectDict =
    Dict ( String, String ) RemoteServerConfiguration


addConfigToDict : RemoteServerConfiguration -> RedirectDict -> RedirectDict
addConfigToDict config dict =
    Dict.insert ( config.clientId, config.tokenUri ) config dict


buildRedirectDict : List RemoteServerConfiguration -> RedirectDict
buildRedirectDict configs =
    List.foldl addConfigToDict Dict.empty configs


type alias Model =
    { configString : String
    , config : List RemoteServerConfiguration
    , redirectDict : RedirectDict
    , localConfig : LocalServerConfiguration
    }


type Msg
    = NoOp
    | ReceiveConfig (Maybe String)
    | ProbeConfig Time
    | NewRequest Server.Http.Request
    | ReceiveToken Server.Http.Id String (Maybe String) (Result Http.Error OAuth.ResponseToken)


init : ( Model, Cmd Msg )
init =
    ( { configString = ""
      , config = []
      , redirectDict = Dict.empty
      , localConfig = { defaultLocalServerConfiguration | httpPort = -4321 }
      }
    , getConfig
    )


configFile : String
configFile =
    "build/config.json"


getConfig : Cmd msg
getConfig =
    getFile configFile


receiveConfig : Maybe String -> Model -> ( Model, Cmd Msg )
receiveConfig file model =
    case file of
        Nothing ->
            if model.configString == "error" then
                model ! []
            else
                let
                    m1 =
                        Debug.log "Notice" ("Error reading " ++ configFile)
                in
                let
                    m2 =
                        if model.config == [] then
                            Debug.log "Fatal"
                                "Empty configuration makes me a very useless server."
                        else
                            ""
                in
                { model | configString = "error" }
                    ! []

        Just json ->
            if json == model.configString then
                model ! []
            else
                case JD.decodeString configurationsDecoder json of
                    Err msg ->
                        let
                            m =
                                Debug.log "Error" msg
                        in
                        let
                            m2 =
                                if model.config == [] then
                                    Debug.log "Fatal"
                                        "Empty configuration makes me a very useless server."
                                else
                                    ""
                        in
                        { model | configString = json }
                            ! []

                    Ok { local, remote } ->
                        let
                            m =
                                if remote == [] then
                                    Debug.log "Notice"
                                        "Empty remote configuration disabled server."
                                else
                                    Debug.log "Notice"
                                        ("Successfully parsed " ++ configFile)
                        in
                        updateLocalConfig
                            local
                            { model
                                | configString = json
                                , config = remote
                                , redirectDict = buildRedirectDict remote
                            }


updateLocalConfig : LocalServerConfiguration -> Model -> ( Model, Cmd Msg )
updateLocalConfig config model =
    let
        cmd =
            if config.httpPort == model.localConfig.httpPort then
                Cmd.none
            else
                httpListen config.httpPort
    in
    ( { model | localConfig = config }
    , cmd
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ReceiveConfig file ->
            receiveConfig file model

        ProbeConfig _ ->
            model ! [ getConfig ]

        NewRequest request ->
            newRequest request model

        ReceiveToken id redirectBackUri state result ->
            let
                string =
                    case result of
                        Err err ->
                            ED.encodeResponseTokenError
                                { err = toString err
                                , state = state
                                }

                        Ok responseToken ->
                            ED.encodeResponseToken
                                { responseToken | state = state }

                base64 =
                    case Base64.encode string of
                        Ok b ->
                            b

                        Err _ ->
                            -- Can't happen
                            ""

                location =
                    redirectBackUri ++ "#" ++ base64

                response =
                    Server.Http.emptyResponse
                        Server.Http.foundStatus
                        id
                        |> Server.Http.addHeader "location" location
            in
            model
                ! [ Server.Http.send response ]

        NoOp ->
            model ! []


{-| The request comes from the authorization server, and is of the form:

...?code=<long code>&state=<from OAuthMiddleware.EncodeDecode.encodeRedirectState>

We can also get "?error=access_denied&state=<foo>"

-}
newRequest : Server.Http.Request -> Model -> ( Model, Cmd Msg )
newRequest request model =
    let
        url =
            Erl.parse request.url

        host =
            url.host

        query =
            url.query

        codes =
            Q.getValuesForKey "code" query

        states =
            Q.getValuesForKey "state" query
    in
    case ( codes, states ) of
        ( [ code ], [ state ] ) ->
            authRequest code state url request model

        _ ->
            model
                ! [ Server.Http.send <|
                        Server.Http.textResponse
                            Server.Http.badRequestStatus
                            "Bad request, missing code/state"
                            request.id
                  ]


adjustRequest : AdjustRequest ResponseToken
adjustRequest req =
    let
        headers =
            Http.header "Accept" "application/json" :: req.headers

        expect =
            Http.expectJson ED.responseTokenDecoder
    in
    { req | headers = headers, expect = expect }


tokenRequest : RedirectState -> String -> Model -> Result String (Http.Request OAuth.ResponseToken)
tokenRequest { clientId, tokenUri, redirectUri, scope, redirectBackUri } code model =
    let
        key =
            ( clientId, tokenUri )

        host =
            Erl.extractHost redirectBackUri

        protocol =
            Erl.extractProtocol redirectBackUri
    in
    case Dict.get key model.redirectDict of
        Nothing ->
            Err <|
                "Unknown (clientId, tokenUri): ("
                    ++ clientId
                    ++ ", "
                    ++ tokenUri
                    ++ ")"

        Just { clientSecret, redirectBackHosts } ->
            case LE.find (\rbh -> rbh.host == host) redirectBackHosts of
                Nothing ->
                    Err <| "Unknown redirect host: " ++ host

                Just { ssl } ->
                    if ssl && protocol /= "https" then
                        Err <| "https protocol required for redirect host: " ++ host
                    else
                        Ok <|
                            OAuth.AuthorizationCode.authenticateWithOpts
                                adjustRequest
                            <|
                                OAuth.AuthorizationCode
                                    { credentials =
                                        { clientId = clientId
                                        , secret = clientSecret
                                        }
                                    , code = code
                                    , redirectUri = redirectUri
                                    , scope = scope
                                    , state = Nothing --we already have this in our hand
                                    , url = tokenUri
                                    }


authRequest : String -> String -> Erl.Url -> Server.Http.Request -> Model -> ( Model, Cmd Msg )
authRequest code b64State url request model =
    let
        cmd =
            case Base64.decode b64State of
                Err _ ->
                    Server.Http.send <|
                        Server.Http.textResponse
                            Server.Http.badRequestStatus
                            ("State not base64 encoded: " ++ b64State)
                            request.id

                Ok state ->
                    case ED.decodeRedirectState state of
                        Err err ->
                            Server.Http.send <|
                                Server.Http.textResponse
                                    Server.Http.badRequestStatus
                                    ("Malformed state: " ++ state)
                                    request.id

                        Ok redirectState ->
                            case tokenRequest redirectState code model of
                                Err msg ->
                                    Server.Http.send <|
                                        Server.Http.textResponse
                                            Server.Http.badRequestStatus
                                            msg
                                            request.id

                                Ok tokenRequest ->
                                    Http.send
                                        (ReceiveToken
                                            request.id
                                            redirectState.redirectBackUri
                                            redirectState.state
                                        )
                                        tokenRequest
    in
    model ! [ cmd ]


routeRequest : Result String Server.Http.Request -> Msg
routeRequest incoming =
    case incoming of
        Ok request ->
            NewRequest request

        _ ->
            NoOp


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch <|
        List.concat
            [ [ Server.Http.listen routeRequest
              , receiveFile ReceiveConfig
              ]
            , let
                period =
                    model.localConfig.configSamplePeriod
              in
              if period <= 0 then
                []
              else
                [ Time.every (toFloat period * Time.second) ProbeConfig ]
            ]


main =
    Platform.program
        { init = init
        , update = update
        , subscriptions = subscriptions
        }
