{-# LANGUAGE OverloadedStrings, DoAndIfThenElse #-}

module TextToMath (
    app
) where

import Calculator
import Calculator.Data.Env
import Calculator.DeepSeq()
import Control.Applicative (optional, (<$>))
import Control.DeepSeq (($!!))
import Control.Monad (msum)
import Control.Monad.IO.Class (liftIO)
import Data.Acid (AcidState)
import Data.Acid.Advanced (query', update')
import Data.Aeson ((.=))
import Data.List (isPrefixOf, stripPrefix)
import Data.Map (Map)
import Data.Maybe (fromMaybe)
import Happstack.Server hiding (body, result)
import Serializer()
import System.UUID.V4 (uuid)
import UserState
import qualified Control.Exception.Lifted as CEL
import qualified Data.Aeson as Aeson (encode, decode)
import qualified Data.Aeson.Types as Aeson hiding (Result)
import qualified Data.ByteString.Char8 as Char8 (unpack)
import qualified Data.Map as Map

app :: AcidState UserDb -> ServerPart Response
app acid = msum
  [ dir "calculate" (calc acid)
  , dir "userInfo" (getUserInfo acid)       -- GET
  , dir "userInfo" (resetUserInfo acid)     -- DELETE
  , dir "userInfo" (modifyUserInfo acid)    -- POST (patch)
  ]

calc :: AcidState UserDb -> ServerPart Response
calc acid = do
        method POST
        rq <- askRq
        if contentType "application/json" rq then do
            maybeBody <- takeRequestBody rq
            case Aeson.decode $ unBody $ fromMaybe (Body "") maybeBody :: Maybe (Map String String) of
                Just b -> do
                    let input = fromMaybe "" $ Map.lookup "input" b
                    userId <- getUserId
                    User variables functions bound <- query' acid (UserState.GetUser userId)
                    --let crealVars = Map.map read variables
                    result <- liftIO $ getReturnText input $ Env variables functions bound
                    addCookie Session $ mkCookie "user-id" userId
                    case result of
                        Left err -> do
                            let res = jsonResponse [ "error" .= err ]
                            badRequest res
                        Right ans -> do let newVars = vars ans
                                        let newFuncs = funcs ans
                                        let newBound = boundVars ans
                                        update' acid (UserState.SetUser userId $ User newVars newFuncs $ Map.map snd newBound) -- (Map.map show newVars) newFuncs)
                                        let addedVars = Map.differenceWith takeFirst newVars variables -- crealVars
                                        let addedFuncs = Map.differenceWith takeFirst newFuncs functions
                                        let res = jsonResponse $ makeJSON addedVars addedFuncs (Map.map boundToJSON newBound) $ "result" .= answer ans
                                        ok res 
                Nothing -> badRequest $ toResponse ("Unable to parse body" :: String)
        else resp 415 $ toResponse ("Content type must be application/json" :: String)
        where takeFirst a b = if a /= b then Just a else Nothing
              makeJSON vs fs bvs res = [ "vars" .= vs
                                       , "funcs" .= fs
                                       , "bound" .= bvs
                                       , res
                                       ]

getUserInfo :: AcidState UserDb -> ServerPart Response
getUserInfo acid = do
    method GET
    userId <- getUserId
    User variables functions bound <- query' acid (UserState.GetUser userId)
    addCookie Session $ mkCookie "user-id" userId

    -- no op calculation to force bound vars to get calculed
    result <- liftIO $ getReturnText "0" (Env variables functions bound)
    case result of
        Left err -> ok $ jsonResponse [ "error" .= err ]
        Right ans -> ok $ jsonResponse [ "vars" .= vars ans
                                       , "funcs" .= funcs ans
                                       , "bound" .= Map.map boundToJSON (boundVars ans)
                                       ]
    
boundToJSON :: (Show a, Show b) => (a, b) -> Aeson.Value
boundToJSON v = Aeson.object [ "value" .= show (fst v)
                             , "expr" .= show (snd v)
                             ]

resetUserInfo :: AcidState UserDb -> ServerPart Response
resetUserInfo acid = do
    method DELETE
    userId <- getUserId
    update' acid $ UserState.SetUser userId UserState.newUser
    noContent $ toResponse ()

modifyUserInfo :: AcidState UserDb -> ServerPart Response
modifyUserInfo acid = do
    method POST
    rq <- askRq
    if contentType "application/json-patch+json" rq then do
        userId <- getUserId
        maybeBody <- takeRequestBody rq
        let b = unBody $ fromMaybe (Body "") maybeBody
        case Aeson.decode b of
            Just values ->
                if all isRemove values then do
                    user <- query' acid $ UserState.GetUser userId
                    let updatedUser = foldl runAction (Just user) values
                    case updatedUser of
                        Just u -> do
                            update' acid $ UserState.SetUser userId u
                            ok $ toResponse ()
                        Nothing ->
                            badRequest $ toResponse ("Unable to apply patch" :: String)
                else
                    badRequest $ toResponse ("Unpermitted operation" :: String)
            Nothing -> badRequest $ toResponse ("Unable to parse body" :: String)
    else resp 415 $ toResponse ("Content type must be application/json-patch+json" :: String)
    where isRemove m = case Map.lookup "op" m of
                            Just o -> o == "remove"
                            Nothing -> False

runAction :: Maybe User -> Map String String -> Maybe User
runAction (Just (User vs fs bvs)) action
    | Map.size action == 2 =
        case Map.lookup "path" action of
            Just p  | "/vars/" `isPrefixOf` p ->
                        let Just varName = stripPrefix "/vars/" p
                        in if Map.member varName vs then
                            Just $ User (Map.delete varName vs) fs bvs
                        else
                            Nothing
                    | "/funcs/" `isPrefixOf` p ->
                        let Just funcName = stripPrefix "/funcs/" p
                        in if Map.member funcName fs then
                            Just $ User vs (Map.delete funcName fs) bvs
                        else
                            Nothing
                    | "/bound/" `isPrefixOf` p ->
                        let Just varName = stripPrefix "/bound/" p
                        in if Map.member varName bvs then
                            Just $ User vs fs $ Map.delete varName bvs
                        else
                            Nothing
                    | otherwise -> Nothing
            Nothing -> Nothing
    | otherwise = Nothing
runAction Nothing _ = Nothing

getUserId :: ServerPart String
getUserId = do userId <- optional $ lookCookieValue "user-id"
               case userId of
                   Nothing -> show <$> liftIO uuid
                   Just i -> return i

getReturnText :: String -> Env -> IO (Either String Result)
getReturnText input env = CEL.catch (CEL.evaluate $!! result)
                                    (\e -> return $ Left $ "Invalid input: " ++ show (e :: CEL.ErrorCall))
                                    where result = Right $ calculate input env

jsonResponse :: [Aeson.Pair] -> Response
jsonResponse = addHeader "Content-Type" "application/json" . toResponse . Aeson.encode . Aeson.object

contentType :: String -> Request -> Bool
contentType ct rq = ct == rqCt rq
                    where rqCt r = Char8.unpack $ fromMaybe "" $ getHeader ("Content-Type" :: String) r
