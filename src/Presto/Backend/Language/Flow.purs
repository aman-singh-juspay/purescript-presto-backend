{-
 Copyright (c) 2012-2017 "JUSPAY Technologies"
 JUSPAY Technologies Pvt. Ltd. [https://www.juspay.in]
 This file is part of JUSPAY Platform.
 JUSPAY Platform is free software: you can redistribute it and/or modify
 it for only educational purposes under the terms of the GNU Affero General
 Public License (GNU AGPL) as published by the Free Software Foundation,
 either version 3 of the License, or (at your option) any later version.
 For Enterprise/Commerical licenses, contact <info@juspay.in>.
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  The end user will
 be liable for all damages without limitation, which is caused by the
 ABUSE of the LICENSED SOFTWARE and shall INDEMNIFY JUSPAY for such
 damages, claims, cost, including reasonable attorney fee claimed on Juspay.
 The end user has NO right to claim any indemnification based on its use
 of Licensed Software. See the GNU Affero General Public License for more details.
 You should have received a copy of the GNU Affero General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/agpl.html>.
-}

module Presto.Backend.Flow where

import Prelude

import Cache.Types (EntryID, Item)
import Control.Monad.Aff (Aff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Exception (Error)
import Control.Monad.Free (Free, liftF)
import Data.Either (Either)
import Data.Exists (Exists, mkExists)
import Data.Foreign (Foreign, toForeign)
import Data.Foreign.Class (class Decode, class Encode, encode)
import Data.Lazy (defer)
import Data.Maybe (Maybe(Just, Nothing))
import Data.Newtype (class Newtype)
import Data.Options (Options)
import Data.Options (options) as Opt
import Data.Time.Duration (Milliseconds, Seconds)
import Presto.Backend.APIInteract (apiInteract)
import Presto.Backend.DB.Mock.Actions (mkCreate, mkCreateWithOpts, mkDelete, mkFindAll, mkFindOne, mkQuery, mkUpdate) as SqlDBMock
import Presto.Backend.DB.Mock.Types (DBActionDict, mkDbActionDict) as SqlDBMock
import Presto.Backend.DBImpl (create, createWithOpts, delete, findAll, findOne, query, update, update') as DB
import Presto.Backend.KVDB.Mock.Types as KVDBMock
import Presto.Backend.Language.KVDB (KVDB, delCache, delCacheInMulti, dequeue, dequeueInMulti, enqueue, enqueueInMulti, execMulti, expire, expireInMulti, getCache, getCacheInMulti, getHashKey, getHashKeyInMulti, getQueueIdx, getQueueIdxInMulti, incr, incrInMulti, keyExistsCache, newMulti, publishToChannel, publishToChannelInMulti, setCache, setCacheInMulti, setHash, setHashInMulti, setMessageHandler, subscribe, subscribeToMulti, addInMulti) as KVDB
import Presto.Backend.Language.Types.DB (DBError, KVDBConn, MockedKVDBConn, MockedSqlConn, SqlConn, fromDBMaybeResult, toDBMaybeResult)
import Presto.Backend.Language.Types.EitherEx (EitherEx, fromCustomEitherEx, fromCustomEitherExF, toCustomEitherEx, toCustomEitherExF)
import Presto.Backend.Language.Types.KVDB (Multi)
import Presto.Backend.Language.Types.KVDB (getKVDBName) as KVDB
import Presto.Backend.Language.Types.UnitEx (UnitEx, fromUnitEx, toUnitEx)
import Presto.Backend.Playback.Entries (CallAPIEntry, DoAffEntry, ForkFlowEntry, GetDBConnEntry, GetKVDBConnEntry, LogEntry, RunDBEntry, RunKVDBEitherEntry, RunKVDBSimpleEntry, RunSysCmdEntry, mkCallAPIEntry, mkDoAffEntry, mkForkFlowEntry, mkGetDBConnEntry, mkGetKVDBConnEntry, mkLogEntry, mkRunDBEntry, mkRunKVDBEitherEntry, mkRunKVDBSimpleEntry, mkRunSysCmdEntry) as Playback
import Presto.Backend.Playback.Types (RRItemDict, mkEntryDict) as Playback
import Presto.Backend.Runtime.Common (jsonStringify)
import Presto.Backend.Types (BackendAff)
import Presto.Backend.Types.API (class RestEndpoint, Headers, ErrorResponse, APIResult, makeRequest)
import Presto.Backend.Types.Date (Date, _currentDateStringWithSecOffset, _currentDateStringWithoutSpace, _currentDateWithOffset, _dateStringWithDaysOffset, _dateWithCustomOffset, _getCurrentDate, _getCurrentDateMillis, _getDateWithOffset, _isAheadOfCurrentDate, _isGivenDateAhead)
import Presto.Core.Types.Language.Interaction (Interaction)
import Sequelize.Class (class Model)
import Sequelize.Types (Conn, SEQUELIZE)

data BackendFlowCommands next st rt s
    = Ask (rt -> next)
    | Get (st -> next)
    | Put st (st -> next)
    | Modify (st -> st) (st -> next)

    | CallAPI (Interaction (EitherEx ErrorResponse s))
        (Playback.RRItemDict Playback.CallAPIEntry (EitherEx ErrorResponse s))
        (APIResult s -> next)

    | DoAff (forall eff. BackendAff eff s) (s -> next)

    | DoAffRR (forall eff. BackendAff eff s)
        (Playback.RRItemDict Playback.DoAffEntry s)
        (s -> next)

    | Log String s
        (Playback.RRItemDict Playback.LogEntry UnitEx)
        (UnitEx -> next)

    | Fork (BackendFlow st rt s)
        (Playback.RRItemDict Playback.ForkFlowEntry UnitEx)
        (UnitEx -> next)

    | RunSysCmd String
        (Playback.RRItemDict Playback.RunSysCmdEntry String)
        (String -> next)

    | ThrowException String

    | GetDBConn String
        (Playback.RRItemDict Playback.GetDBConnEntry SqlConn)
        (SqlConn -> next)

    | RunDB String
        (forall eff. Conn -> Aff (sequelize :: SEQUELIZE | eff) (EitherEx DBError s))
        (MockedSqlConn -> SqlDBMock.DBActionDict)
        (Playback.RRItemDict Playback.RunDBEntry (EitherEx DBError s))
        (EitherEx DBError s -> next)

    | GetKVDBConn String
      (Playback.RRItemDict Playback.GetKVDBConnEntry KVDBConn)
        (KVDBConn -> next)

    | RunKVDBEither String
        (KVDB.KVDB (EitherEx DBError s))
        (MockedKVDBConn -> KVDBMock.KVDBActionDict)
        (Playback.RRItemDict Playback.RunKVDBEitherEntry (EitherEx DBError s))
        (EitherEx DBError s -> next)

    | RunKVDBSimple String
        (KVDB.KVDB s)
        (MockedKVDBConn -> KVDBMock.KVDBActionDict)
        (Playback.RRItemDict Playback.RunKVDBSimpleEntry s)
        (s -> next)
    
    | GetDate
        (forall eff. Eff eff s)
        (s -> next)

type BackendFlowCommandsWrapper st rt s next = BackendFlowCommands next st rt s

newtype BackendFlowWrapper st rt next = BackendFlowWrapper (Exists (BackendFlowCommands next st rt))

type BackendFlow st rt next = Free (BackendFlowWrapper st rt) next

wrap :: forall next st rt s. BackendFlowCommands next st rt s -> BackendFlow st rt next
wrap = liftF <<< BackendFlowWrapper <<< mkExists

ask :: forall st rt. BackendFlow st rt rt
ask = wrap $ Ask id

get :: forall st rt. BackendFlow st rt st
get = wrap $ Get id

put :: forall st rt. st -> BackendFlow st rt st
put st = wrap $ Put st id

modify :: forall st rt. (st -> st) -> BackendFlow st rt st
modify fst = wrap $ Modify fst id

callAPI
  :: forall st rt a b
   . Encode a
  => Encode b
  => Decode b
  => RestEndpoint a b
  => Headers -> a -> BackendFlow st rt (APIResult b)
callAPI headers a = wrap $ CallAPI
  (apiInteract a headers)
  (Playback.mkEntryDict (Playback.mkCallAPIEntry (defer $ \_ -> encode $ makeRequest a headers)))
  id

doAff :: forall st rt a. (forall eff. BackendAff eff a) -> BackendFlow st rt a
doAff aff = wrap $ DoAff aff id

doAffRR
  :: forall st rt a
   . Encode a
  => Decode a
  => (forall eff. BackendAff eff a)
  -> BackendFlow st rt a
doAffRR aff = wrap $ DoAffRR aff (Playback.mkEntryDict Playback.mkDoAffEntry) id

-- TODO: this is not a correct solution, jsonStringify is a strange function
-- that feels hacky.
log :: forall st rt a. String -> a -> BackendFlow st rt Unit
log tag message = void $ wrap $ Log tag message
    (Playback.mkEntryDict $ Playback.mkLogEntry tag $ jsonStringify message)
    id

forkFlow' :: forall st rt a. String -> BackendFlow st rt a -> BackendFlow st rt Unit
forkFlow' description flow =
  void $ wrap $ Fork flow
    (Playback.mkEntryDict $ Playback.mkForkFlowEntry description)
    id

forkFlow :: forall st rt a. BackendFlow st rt a -> BackendFlow st rt Unit
forkFlow = forkFlow' ""

runSysCmd :: forall st rt. String -> BackendFlow st rt String
runSysCmd cmd =
  wrap $ RunSysCmd cmd
    (Playback.mkEntryDict $ Playback.mkRunSysCmdEntry cmd)
    id

throwException :: forall st rt a. String -> BackendFlow st rt a
throwException errorMessage = wrap $ ThrowException errorMessage

getDBConn :: forall st rt. String -> BackendFlow st rt SqlConn
getDBConn dbName = wrap $ GetDBConn dbName
  (Playback.mkEntryDict $ Playback.mkGetDBConnEntry dbName)
  id

findOne
  :: forall model st rt
   . Model model
  => String -> Options model -> BackendFlow st rt (Either Error (Maybe model))
findOne dbName options = do
  eResEx <- wrap $ RunDB dbName
    (\conn     -> toDBMaybeResult <$> DB.findOne conn options)
    (\connMock -> SqlDBMock.mkDbActionDict $ SqlDBMock.mkFindOne dbName)
    (Playback.mkEntryDict $ Playback.mkRunDBEntry dbName "findOne" [Opt.options options] (encode ""))
    id
  pure $ fromDBMaybeResult eResEx

findAll
  :: forall model st rt
   . Model model
  => String -> Options model -> BackendFlow st rt (Either Error (Array model))
findAll dbName options = do
  eResEx <- wrap $ RunDB dbName
    (\conn -> toCustomEitherEx <$> DB.findAll conn options)
    (\connMock -> SqlDBMock.mkDbActionDict $ SqlDBMock.mkFindAll dbName)
    (Playback.mkEntryDict $ Playback.mkRunDBEntry dbName "findAll" [Opt.options options] (encode ""))
    id
  pure $ fromCustomEitherEx eResEx

query
  :: forall r a st rt
   . Encode a
  => Decode a
  => Newtype a {|r}
  => String -> String -> BackendFlow st rt (Either Error (Array a))
query dbName rawq = do
  eResEx <- wrap $ RunDB dbName
    (\conn -> toCustomEitherEx <$> DB.query conn rawq)
    (\connMock -> SqlDBMock.mkDbActionDict $ SqlDBMock.mkQuery dbName)
    (Playback.mkEntryDict $ Playback.mkRunDBEntry dbName "query" [toForeign rawq] (encode ""))
    id
  pure $ fromCustomEitherEx eResEx

create :: forall model st rt. Model model => String -> model -> BackendFlow st rt (Either Error (Maybe model))
create dbName model = do
  eResEx <- wrap $ RunDB dbName
    (\conn -> toDBMaybeResult <$> DB.create conn model)
    (\connMock -> SqlDBMock.mkDbActionDict $ SqlDBMock.mkCreate dbName)
    (Playback.mkEntryDict $ Playback.mkRunDBEntry dbName "create" [] (encode model))
    id
  pure $ fromDBMaybeResult eResEx

createWithOpts :: forall model st rt. Model model => String -> model -> Options model -> BackendFlow st rt (Either Error (Maybe model))
createWithOpts dbName model options = do
  eResEx <- wrap $ RunDB dbName
    (\conn -> toDBMaybeResult <$> DB.createWithOpts conn model options)
    (\connMock -> SqlDBMock.mkDbActionDict $ SqlDBMock.mkCreateWithOpts dbName)
    (Playback.mkEntryDict $ Playback.mkRunDBEntry dbName "createWithOpts" [Opt.options options] (encode model))
    id
  pure $ fromDBMaybeResult eResEx

update :: forall model st rt. Model model => String -> Options model -> Options model -> BackendFlow st rt (Either Error (Array model))
update dbName updateValues whereClause = do
  eResEx <- wrap $ RunDB dbName
    (\conn -> toCustomEitherEx <$> DB.update conn updateValues whereClause)
    (\connMock -> SqlDBMock.mkDbActionDict $ SqlDBMock.mkUpdate dbName)
    (Playback.mkEntryDict $ Playback.mkRunDBEntry dbName "update" [(Opt.options updateValues),(Opt.options whereClause)] (encode ""))
    id
  pure $ fromCustomEitherEx eResEx

update' :: forall model st rt. Model model => String -> Options model -> Options model -> BackendFlow st rt (Either Error Int)
update' dbName updateValues whereClause = do
  eResEx <- wrap $ RunDB dbName
    (\conn -> toCustomEitherEx <$> DB.update' conn updateValues whereClause)
    (\connMock -> SqlDBMock.mkDbActionDict $ SqlDBMock.mkUpdate dbName)
    (Playback.mkEntryDict $ Playback.mkRunDBEntry dbName "update'" [(Opt.options updateValues),(Opt.options whereClause)] (encode ""))
    id
  pure $ fromCustomEitherEx eResEx

delete :: forall model st rt. Model model => String -> Options model -> BackendFlow st rt (Either Error Int)
delete dbName options = do
  eResEx <- wrap $ RunDB dbName
    (\conn -> toCustomEitherEx <$> DB.delete conn options)
    (\connMock -> SqlDBMock.mkDbActionDict $ SqlDBMock.mkDelete dbName)
    (Playback.mkEntryDict $ Playback.mkRunDBEntry dbName "delete" [Opt.options options] (encode ""))
    id
  pure $ fromCustomEitherEx eResEx

getKVDBConn :: forall st rt. String -> BackendFlow st rt KVDBConn
getKVDBConn dbName = wrap $ GetKVDBConn dbName
  (Playback.mkEntryDict $ Playback.mkGetKVDBConnEntry dbName)
  id

-- Not sure about this method.
-- Should we wrap Unit?
setCache :: forall st rt. String -> String ->  String -> BackendFlow st rt (Either Error Unit)
setCache dbName key value = do
  eRes <- wrap $ RunKVDBEither dbName
      (toCustomEitherExF toUnitEx <$> KVDB.setCache key value Nothing)
      KVDBMock.mkKVDBActionDict
      (Playback.mkEntryDict $ Playback.mkRunKVDBEitherEntry dbName "setCache" "")
      id
  pure $ fromCustomEitherExF fromUnitEx eRes

-- Not sure about this method.
-- Should we wrap Unit?
setCacheWithExpiry :: forall st rt. String -> String -> String -> Milliseconds -> BackendFlow st rt (Either Error Unit)
setCacheWithExpiry dbName key value ttl = do
  eRes <- wrap $ RunKVDBEither dbName
      (toCustomEitherExF toUnitEx <$> KVDB.setCache key value (Just ttl))
      KVDBMock.mkKVDBActionDict
      (Playback.mkEntryDict $ Playback.mkRunKVDBEitherEntry dbName "setCacheWithExpiry" "")
      id
  pure $ fromCustomEitherExF fromUnitEx eRes

getCache :: forall st rt. String -> String -> BackendFlow st rt (Either Error (Maybe String))
getCache dbName key = do
  eRes <- wrap $ RunKVDBEither dbName
      (toDBMaybeResult <$> KVDB.getCache key)
      KVDBMock.mkKVDBActionDict
      (Playback.mkEntryDict $ Playback.mkRunKVDBEitherEntry dbName "getCache" "")
      id
  pure $ fromDBMaybeResult eRes

keyExistsCache :: forall st rt. String -> String -> BackendFlow st rt (Either Error Boolean)
keyExistsCache dbName key = do
  eRes <- wrap $ RunKVDBEither dbName
      (toCustomEitherEx <$> KVDB.keyExistsCache key)
      KVDBMock.mkKVDBActionDict
      (Playback.mkEntryDict $ Playback.mkRunKVDBEitherEntry dbName "keyExistsCache" "")
      id
  pure $ fromCustomEitherEx eRes

delCache :: forall st rt. String -> String -> BackendFlow st rt (Either Error Int)
delCache dbName key = do
  eRes <- wrap $ RunKVDBEither dbName
      (toCustomEitherEx <$> KVDB.delCache key)
      KVDBMock.mkKVDBActionDict
      (Playback.mkEntryDict $ Playback.mkRunKVDBEitherEntry dbName "delCache" "")
      id
  pure $ fromCustomEitherEx eRes

expire :: forall st rt. String -> String -> Seconds -> BackendFlow st rt (Either Error Boolean)
expire dbName key ttl = do
  eRes <- wrap $ RunKVDBEither dbName
      (toCustomEitherEx <$> KVDB.expire key ttl)
      KVDBMock.mkKVDBActionDict
      (Playback.mkEntryDict $ Playback.mkRunKVDBEitherEntry dbName "expire" "")
      id
  pure $ fromCustomEitherEx eRes

incr :: forall st rt. String -> String -> BackendFlow st rt (Either Error Int)
incr dbName key = do
  eRes <- wrap $ RunKVDBEither dbName
      (toCustomEitherEx <$> KVDB.incr key)
      KVDBMock.mkKVDBActionDict
      (Playback.mkEntryDict $ Playback.mkRunKVDBEitherEntry dbName "incr" "")
      id
  pure $ fromCustomEitherEx eRes

setHash :: forall st rt. String -> String -> String -> String -> BackendFlow st rt (Either Error Boolean)
setHash dbName key field value = do
  eRes <- wrap $ RunKVDBEither dbName
      (toCustomEitherEx <$> KVDB.setHash key field value)
      KVDBMock.mkKVDBActionDict
      (Playback.mkEntryDict $ Playback.mkRunKVDBEitherEntry dbName "setHash" "")
      id
  pure $ fromCustomEitherEx eRes

getHashKey :: forall st rt. String -> String -> String -> BackendFlow st rt (Either Error (Maybe String))
getHashKey dbName key field = do
  eRes <- wrap $ RunKVDBEither dbName
      (toDBMaybeResult <$> KVDB.getHashKey key field)
      KVDBMock.mkKVDBActionDict
      (Playback.mkEntryDict $ Playback.mkRunKVDBEitherEntry dbName "getHashKey" "")
      id
  pure $ fromDBMaybeResult eRes

publishToChannel :: forall st rt. String -> String -> String -> BackendFlow st rt (Either Error Int)
publishToChannel dbName channel message = do
  eRes <- wrap $ RunKVDBEither dbName
      (toCustomEitherEx <$> KVDB.publishToChannel channel message)
      KVDBMock.mkKVDBActionDict
      (Playback.mkEntryDict $ Playback.mkRunKVDBEitherEntry dbName "publishToChannel" "")
      id
  pure $ fromCustomEitherEx eRes

-- Not sure about this method.
-- Should we wrap Unit?
subscribe :: forall st rt. String -> String -> BackendFlow st rt (Either Error Unit)
subscribe dbName channel = do
  eRes <- wrap $ RunKVDBEither dbName
      (toCustomEitherExF toUnitEx <$> KVDB.subscribe channel)
      KVDBMock.mkKVDBActionDict
      (Playback.mkEntryDict $ Playback.mkRunKVDBEitherEntry dbName "subscribe" "")
      id
  pure $ fromCustomEitherExF fromUnitEx eRes

-- Not sure about this method.
-- Should we wrap Unit?
enqueue :: forall st rt. String -> String -> String -> BackendFlow st rt (Either Error Unit)
enqueue dbName listName value = do
  eRes <- wrap $ RunKVDBEither dbName
      (toCustomEitherExF toUnitEx <$> KVDB.enqueue listName value)
      KVDBMock.mkKVDBActionDict
      (Playback.mkEntryDict $ Playback.mkRunKVDBEitherEntry dbName "enqueue" "")
      id
  pure $ fromCustomEitherExF fromUnitEx eRes

dequeue :: forall st rt. String -> String -> BackendFlow st rt (Either Error (Maybe String))
dequeue dbName listName = do
  eRes <- wrap $ RunKVDBEither dbName
      (toDBMaybeResult <$> KVDB.dequeue listName)
      KVDBMock.mkKVDBActionDict
      (Playback.mkEntryDict $ Playback.mkRunKVDBEitherEntry dbName "dequeue" "")
      id
  pure $ fromDBMaybeResult eRes

getQueueIdx :: forall st rt. String -> String -> Int -> BackendFlow st rt (Either Error (Maybe String))
getQueueIdx dbName listName index = do
  eRes <- wrap $ RunKVDBEither dbName
      (toDBMaybeResult <$> KVDB.getQueueIdx listName index)
      KVDBMock.mkKVDBActionDict
      (Playback.mkEntryDict $ Playback.mkRunKVDBEitherEntry dbName "getQueueIdx" "")
      id
  pure $ fromDBMaybeResult eRes

-- Multi methods

newMulti :: forall st rt. String -> BackendFlow st rt Multi
newMulti dbName =
  wrap $ RunKVDBSimple dbName
    KVDB.newMulti
    KVDBMock.mkKVDBActionDict
    (Playback.mkEntryDict $ Playback.mkRunKVDBSimpleEntry dbName "newMulti" "")
    id

setCacheInMulti :: forall st rt. String -> String -> Multi -> BackendFlow st rt Multi
setCacheInMulti key value multi = let
  dbName = KVDB.getKVDBName multi
  in wrap $ RunKVDBSimple dbName
    (KVDB.setCacheInMulti key value Nothing multi)
    KVDBMock.mkKVDBActionDict
    (Playback.mkEntryDict $ Playback.mkRunKVDBSimpleEntry dbName "setCacheInMulti" "")
    id

-- Why this function returns Multi???
getCacheInMulti :: forall st rt. String -> Multi -> BackendFlow st rt Multi
getCacheInMulti key multi = let
  dbName = KVDB.getKVDBName multi
  in wrap $ RunKVDBSimple dbName
    (KVDB.getCacheInMulti key multi)
    KVDBMock.mkKVDBActionDict
    (Playback.mkEntryDict $ Playback.mkRunKVDBSimpleEntry dbName "getCacheInMulti" "")
    id

delCacheInMulti :: forall st rt. String -> Multi -> BackendFlow st rt Multi
delCacheInMulti key multi = let
  dbName = KVDB.getKVDBName multi
  in wrap $ RunKVDBSimple dbName
    (KVDB.delCacheInMulti key multi)
    KVDBMock.mkKVDBActionDict
    (Playback.mkEntryDict $ Playback.mkRunKVDBSimpleEntry dbName "delCacheInMulti" "")
    id

setCacheWithExpireInMulti :: forall st rt. String -> String -> Milliseconds -> Multi -> BackendFlow st rt Multi
setCacheWithExpireInMulti key value ttl multi = let
  dbName = KVDB.getKVDBName multi
  in wrap $ RunKVDBSimple dbName
    (KVDB.setCacheInMulti key value (Just ttl) multi)
    KVDBMock.mkKVDBActionDict
    (Playback.mkEntryDict $ Playback.mkRunKVDBSimpleEntry dbName "setCacheWithExpireInMulti" "")
    id

expireInMulti :: forall st rt. String -> Seconds -> Multi -> BackendFlow st rt Multi
expireInMulti key ttl multi = let
  dbName = KVDB.getKVDBName multi
  in wrap $ RunKVDBSimple dbName
    (KVDB.expireInMulti key ttl multi)
    KVDBMock.mkKVDBActionDict
    (Playback.mkEntryDict $ Playback.mkRunKVDBSimpleEntry dbName "expireInMulti" "")
    id

incrInMulti :: forall st rt. String -> Multi -> BackendFlow st rt Multi
incrInMulti key multi = let
  dbName = KVDB.getKVDBName multi
  in wrap $ RunKVDBSimple dbName
    (KVDB.incrInMulti key multi)
    KVDBMock.mkKVDBActionDict
    (Playback.mkEntryDict $ Playback.mkRunKVDBSimpleEntry dbName "incrInMulti" "")
    id

setHashInMulti :: forall st rt. String -> String -> String -> Multi -> BackendFlow st rt Multi
setHashInMulti key field value multi = let
  dbName = KVDB.getKVDBName multi
  in wrap $ RunKVDBSimple dbName
    (KVDB.setHashInMulti key field value multi)
    KVDBMock.mkKVDBActionDict
    (Playback.mkEntryDict $ Playback.mkRunKVDBSimpleEntry dbName "setHashInMulti" "")
    id

-- Why this function returns Multi???
getHashKeyInMulti :: forall st rt. String -> String -> Multi -> BackendFlow st rt Multi
getHashKeyInMulti key field multi = let
  dbName = KVDB.getKVDBName multi
  in wrap $ RunKVDBSimple dbName
    (KVDB.getHashKeyInMulti key field multi)
    KVDBMock.mkKVDBActionDict
    (Playback.mkEntryDict $ Playback.mkRunKVDBSimpleEntry dbName "getHashKeyInMulti" "")
    id

publishToChannelInMulti :: forall st rt. String -> String -> Multi -> BackendFlow st rt Multi
publishToChannelInMulti channel message multi = let
  dbName = KVDB.getKVDBName multi
  in wrap $ RunKVDBSimple dbName
    (KVDB.publishToChannelInMulti channel message multi)
    KVDBMock.mkKVDBActionDict
    (Playback.mkEntryDict $ Playback.mkRunKVDBSimpleEntry dbName "publishToChannelInMulti" "")
    id

enqueueInMulti :: forall st rt. String -> String -> Multi -> BackendFlow st rt Multi
enqueueInMulti listName value multi = let
  dbName = KVDB.getKVDBName multi
  in wrap $ RunKVDBSimple dbName
    (KVDB.enqueueInMulti listName value multi)
    KVDBMock.mkKVDBActionDict
    (Playback.mkEntryDict $ Playback.mkRunKVDBSimpleEntry dbName "enqueueInMulti" "")
    id

-- Why this function returns Multi???
dequeueInMulti :: forall st rt. String -> Multi -> BackendFlow st rt Multi
dequeueInMulti listName multi = let
  dbName = KVDB.getKVDBName multi
  in wrap $ RunKVDBSimple dbName
    (KVDB.dequeueInMulti listName multi)
    KVDBMock.mkKVDBActionDict
    (Playback.mkEntryDict $ Playback.mkRunKVDBSimpleEntry dbName "dequeueInMulti" "")
    id

-- Why this function returns Multi???
getQueueIdxInMulti :: forall st rt. String -> Int -> Multi -> BackendFlow st rt Multi
getQueueIdxInMulti listName index multi = let
  dbName = KVDB.getKVDBName multi
  in wrap $ RunKVDBSimple dbName
    (KVDB.getQueueIdxInMulti listName index multi)
    KVDBMock.mkKVDBActionDict
    (Playback.mkEntryDict $ Playback.mkRunKVDBSimpleEntry dbName "getQueueIdxInMulti" "")
    id

subscribeToMulti :: forall st rt. String -> Multi -> BackendFlow st rt Multi
subscribeToMulti channel multi = let
  dbName = KVDB.getKVDBName multi
  in wrap $ RunKVDBSimple dbName
    (KVDB.subscribeToMulti channel multi)
    KVDBMock.mkKVDBActionDict
    (Playback.mkEntryDict $ Playback.mkRunKVDBSimpleEntry dbName "subscribeToMulti" "")
    id

execMulti :: forall st rt. Multi -> BackendFlow st rt (Either Error (Array Foreign))
execMulti multi = do
  let dbName = KVDB.getKVDBName multi
  eRes <- wrap $ RunKVDBEither dbName
      (toCustomEitherEx <$> KVDB.execMulti multi)
      KVDBMock.mkKVDBActionDict
      (Playback.mkEntryDict $ Playback.mkRunKVDBEitherEntry dbName "execMulti" "")
      id
  pure $ fromCustomEitherEx eRes

addInMulti :: forall st rt.String -> EntryID -> (Array Item) -> Multi -> BackendFlow st rt (Either Error Multi)
addInMulti key entryId args multi = do
  let dbName = KVDB.getKVDBName multi
  eRes <- wrap $ RunKVDBEither dbName
      (toCustomEitherEx <$> KVDB.addInMulti key entryId args multi)
      KVDBMock.mkKVDBActionDict
      (Playback.mkEntryDict $ Playback.mkRunKVDBEitherEntry dbName "addInMulti" "")
      id
  pure $ fromCustomEitherEx eRes

setMessageHandler
  :: forall st rt
   . String
  -> (forall eff. (String -> String -> Eff eff Unit))
  -> BackendFlow st rt Unit
setMessageHandler dbName f = do
  void $ wrap $ RunKVDBSimple dbName
      (toUnitEx <$> KVDB.setMessageHandler f)
      KVDBMock.mkKVDBActionDict
      (Playback.mkEntryDict $ Playback.mkRunKVDBSimpleEntry dbName "setMessageHandler" "")
      id

getCurrentDate :: forall st rt. BackendFlow st rt Date
getCurrentDate = wrap $ GetDate _getCurrentDate $ id

getDateStringWithOffset :: forall st rt. Date -> Int -> BackendFlow st rt Date
getDateStringWithOffset givenDate offset = wrap $ GetDate (_dateStringWithDaysOffset givenDate offset) $ id

isAheadOfCurrentDate :: forall st rt. Date -> BackendFlow st rt Boolean
isAheadOfCurrentDate date = wrap $ GetDate (_isAheadOfCurrentDate date) $ id

isGivenDateAhead :: forall st rt. Date -> Date -> BackendFlow st rt Boolean
isGivenDateAhead givenDate dateToCheckWith = wrap $ GetDate (_isGivenDateAhead givenDate dateToCheckWith) $ id

getCurrentDateStringWithOffset :: forall st rt. Int -> BackendFlow st rt String
getCurrentDateStringWithOffset sec =  wrap $ GetDate (_currentDateStringWithSecOffset sec) $ id

getDateWithOffset :: forall st rt. String -> Int -> BackendFlow st rt String
getDateWithOffset date offset =  wrap $ GetDate (_getDateWithOffset date offset) $ id

getDateWithCustomOffset :: forall st rt. Date -> Int -> String -> BackendFlow st rt Date
getDateWithCustomOffset givenDate offset offsetType =  wrap $ GetDate (_dateWithCustomOffset givenDate offset offsetType) $ id

getCurrentDateInMillis :: forall st rt. BackendFlow st rt Number
getCurrentDateInMillis =  wrap $ GetDate (_getCurrentDateMillis) $ id

currentDateWithOffset :: forall st rt. Int -> BackendFlow st rt Date
currentDateWithOffset currentDate = wrap $ GetDate (_currentDateWithOffset currentDate) $ id

currentDateStringWithoutSpace :: forall st rt. BackendFlow st rt String
currentDateStringWithoutSpace = wrap $ GetDate (_currentDateStringWithoutSpace) $ id