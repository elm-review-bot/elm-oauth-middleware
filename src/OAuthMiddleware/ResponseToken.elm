----------------------------------------------------------------------
--
-- ResponseToken.elm
-- The ResponseToken type and decoders for it.
-- Copyright (c) 2018 Bill St. Clair <billstclair@gmail.com>
-- Some rights reserved.
-- Distributed under the MIT License
-- See LICENSE.txt
--
----------------------------------------------------------------------


module OAuthMiddleware.ResponseToken exposing
    ( ResponseToken
    , responseTokenDecoder, stateDecoder
    , makeResponseToken
    )

{-| This module revives the `ResponseToken` type.

`ResponseToken` and its decoders were removed from truqu/elm-oauth2 version 4.0.0. This module is a copy of the version 3.0.0 code.


## Types

@docs ResponseToken


## Json Decoders

@docs responseTokenDecoder, stateDecoder


## Constructors

@docs makeToken, makeResponseToken

-}

import Json.Decode as Json
import OAuth exposing (..)
import OAuth.AuthorizationCode as AC


{-| The response obtained as a result of an authentication (implicit or not)

  - expiresIn (_RECOMMENDED_):
    The lifetime in seconds of the access token. For example, the value "3600" denotes that the
    access token will expire in one hour from the time the response was generated. If omitted, the
    authorization server SHOULD provide the expiration time via other means or document the default
    value.
  - refreshToken (_OPTIONAL_):
    The refresh token, which can be used to obtain new access tokens using the same authorization
    grant as described in [Section 6](https://tools.ietf.org/html/rfc6749#section-6).
  - scope (_OPTIONAL, if identical to the scope requested; otherwise, REQUIRED_):
    The scope of the access token as described by [Section 3.3](https://tools.ietf.org/html/rfc6749#section-3.3).
  - state (_REQUIRED if `state` was present in the authentication request_):
    The exact value received from the client
  - token (_REQUIRED_):
    The access token issued by the authorization server.

-}
type alias ResponseToken =
    { expiresIn : Maybe Int
    , refreshToken : Maybe Token
    , scope : List String
    , state : Maybe String
    , token : Token
    }


{-| Json decoder for a response.
-}
responseTokenDecoder : Json.Decoder ResponseToken
responseTokenDecoder =
    Json.map5 makeResponseToken
        AC.defaultTokenDecoder
        AC.defaultExpiresInDecoder
        AC.defaultRefreshTokenDecoder
        AC.defaultScopeDecoder
        stateDecoder


{-| Json decoder for a state
-}
stateDecoder : Json.Decoder (Maybe String)
stateDecoder =
    Json.maybe <| Json.field "state" Json.string


{-| Create a ResponseToken record from various parameters
-}
makeResponseToken : Token -> Maybe Int -> Maybe Token -> List String -> Maybe String -> ResponseToken
makeResponseToken token expiresIn refreshToken scope state =
    { token = token
    , expiresIn = expiresIn
    , refreshToken = refreshToken
    , scope = scope
    , state = state
    }