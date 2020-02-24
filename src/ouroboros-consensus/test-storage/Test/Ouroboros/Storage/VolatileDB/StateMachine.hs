{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving  #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Test.Ouroboros.Storage.VolatileDB.StateMachine
    ( tests
    , showLabelledExamples
    ) where

import           Prelude hiding (elem)

import           Codec.Serialise (decode)
import           Control.Monad (forM_, void)
import           Data.Bifunctor (first)
import           Data.ByteString.Lazy (ByteString)
import           Data.Functor.Classes
import           Data.Kind (Type)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map as Map
import           Data.Maybe (listToMaybe, mapMaybe)
import           Data.Proxy (Proxy (..))
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.TreeDiff (ToExpr (..))
import           Data.Word
import qualified Generics.SOP as SOP
import           GHC.Generics
import           GHC.Stack
import           System.Random (getStdRandom, randomR)
import           Text.Show.Pretty (ppShow)

import           Ouroboros.Network.Block (BlockNo (..), ChainHash (..),
                     MaxSlotNo (..), SlotNo (..), blockHash)
import           Ouroboros.Network.Point (WithOrigin)
import qualified Ouroboros.Network.Point as WithOrigin

import           Ouroboros.Consensus.Block (IsEBB (..))
import qualified Ouroboros.Consensus.Util.Classify as C
import           Ouroboros.Consensus.Util.IOLike

import           Ouroboros.Consensus.Storage.ChainDB.Impl.VolDB
                     (blockFileParser')
import           Ouroboros.Consensus.Storage.Common
import           Ouroboros.Consensus.Storage.FS.API (HasFS, hPutAll, withFile)
import           Ouroboros.Consensus.Storage.FS.API.Types
import qualified Ouroboros.Consensus.Storage.Util.ErrorHandling as EH
import           Ouroboros.Consensus.Storage.VolatileDB
import           Ouroboros.Consensus.Storage.VolatileDB.Util

import           Test.QuickCheck
import           Test.QuickCheck.Monadic
import           Test.QuickCheck.Random (mkQCGen)
import           Test.StateMachine
import           Test.StateMachine.Sequential
import           Test.StateMachine.Types
import qualified Test.StateMachine.Types.Rank2 as Rank2
import           Test.Tasty (TestTree, testGroup)
import           Test.Tasty.QuickCheck (testProperty)

import           Test.Util.FS.Sim.Error hiding (null)
import qualified Test.Util.FS.Sim.MockFS as Mock
import           Test.Util.SOP
import           Test.Util.Tracer (recordingTracerIORef)

import           Test.Ouroboros.Storage.TestBlock
import           Test.Ouroboros.Storage.Util
import           Test.Ouroboros.Storage.VolatileDB.Model


type BlockId = TestHeaderHash

type Predecessor = WithOrigin BlockId

newtype At t (r :: Type -> Type) = At {unAt :: t}
  deriving (Generic)

-- | Alias for 'At'
type (:@) t r = At t r

-- | Product of all 'BlockComponent's. As this is a GADT, generating random
-- values of it (and combinations!) is not so simple. Therefore, we just
-- always request all block components.
allComponents :: BlockComponent (VolatileDB BlockId m) AllComponents
allComponents = (,,,,,,,,)
    <$> GetBlock
    <*> GetRawBlock
    <*> GetHeader
    <*> GetRawHeader
    <*> GetHash
    <*> GetSlot
    <*> GetIsEBB
    <*> GetBlockSize
    <*> GetHeaderSize

-- | A list of all the 'BlockComponent' indices (@b@) we are interested in.
type AllComponents =
  ( ()
  , ByteString
  , ()
  , ByteString
  , BlockId
  , SlotNo
  , IsEBB
  , Word32
  , Word16
  )

data Cmd
    = IsOpen
    | Close
    | ReOpen
    | GetBlockComponent BlockId
    | PutBlock TestBlock
    | GarbageCollect SlotNo
    | GetSuccessors [Predecessor]
    | GetPredecessor [BlockId]
    | GetIsMember [BlockId]
    | GetMaxSlotNo
    | Corruption Corruptions
    | DuplicateBlock FileId BlockId ByteString
    deriving (Show, Generic)

data CmdErr = CmdErr {
      cmd :: Cmd
    , err :: Maybe Errors
    } deriving Show

-- | We compare two functions based on their results on a list of inputs
-- (functional extensionality).
data Success
    = Unit            ()
    | MbAllComponents (Maybe AllComponents)
    | Bool            Bool
    | IsMember        [Bool]
    | Successors      [Set BlockId]
    | Predecessor     [Predecessor]
    | MaxSlot         MaxSlotNo
    deriving (Show, Eq)

newtype Resp = Resp {
      getResp :: Either VolatileDBError Success
    }
  deriving (Eq, Show)

deriving instance Generic1          (At Cmd)
deriving instance Generic1          (At CmdErr)
deriving instance Rank2.Foldable    (At Cmd)
deriving instance Rank2.Foldable    (At CmdErr)
deriving instance Rank2.Functor     (At Cmd)
deriving instance Rank2.Functor     (At CmdErr)
deriving instance Rank2.Traversable (At CmdErr)
deriving instance Show1 r => Show   (CmdErr :@ r)
deriving instance Show1 r => Show   (Cmd :@ r)

deriving instance SOP.Generic         Cmd
deriving instance SOP.HasDatatypeInfo Cmd

deriving instance Generic1        (At Resp)
deriving instance Rank2.Foldable  (At Resp)
deriving instance Show1 r => Show (Resp :@ r)

deriving instance ToExpr SlotNo
deriving instance ToExpr FsPath
deriving instance ToExpr MaxSlotNo
deriving instance ToExpr IsEBB
deriving instance ToExpr BlocksPerFile
deriving instance ToExpr (BlockInfo BlockId)
deriving instance ToExpr (BlocksInFile BlockId)
deriving instance ToExpr (DBModel BlockId)
deriving instance ToExpr (Model r)
deriving instance ToExpr (WithOrigin BlockId)
deriving instance ToExpr TestHeaderHash
deriving instance ToExpr TestBodyHash
deriving instance ToExpr TestHeader
deriving instance ToExpr TestBody
deriving instance ToExpr TestBlock
deriving instance ToExpr (BinaryInfo ByteString)
deriving instance ToExpr (ChainHash TestHeader)
deriving instance ToExpr BlockNo

instance CommandNames (At Cmd) where
  cmdName (At cmd) = constrName cmd
  cmdNames (_ :: Proxy (At Cmd r)) = constrNames (Proxy @Cmd)

instance CommandNames (At CmdErr) where
  cmdName (At (CmdErr { cmd }) ) = constrName cmd
  cmdNames (_ :: Proxy (At CmdErr r)) = constrNames (Proxy @Cmd)

newtype Model (r :: Type -> Type) = Model {
      dbModel :: DBModel BlockId
      -- ^ A model of the database.
    }
  deriving (Generic, Show)

-- | An event records the model before and after a command along with the
-- command itself, and a mocked version of the response.
data Event r = Event {
      eventBefore   :: Model     r
    , eventCmd      :: At CmdErr r
    , eventAfter    :: Model     r
    , eventMockResp :: Resp
    }
  deriving (Show)

lockstep :: forall r.
            Model     r
         -> At CmdErr r
         -> Event     r
lockstep model cmdErr = Event {
      eventBefore   = model
    , eventCmd      = cmdErr
    , eventAfter    = model'
    , eventMockResp = mockResp
    }
  where
    (mockResp, dbModel') = step model cmdErr
    model' = Model dbModel'

-- | Key property of the model is that we can go from real to mock responses.
toMock :: Model r -> At t r -> t
toMock _ (At t) = t

step :: Model r -> At CmdErr r -> (Resp, DBModel BlockId)
step model@Model{..} cmderr = runPureErr dbModel (toMock model cmderr)

runPure :: Cmd
        -> DBModel BlockId
        -> (Resp, DBModel BlockId)
runPure = \case
    GetBlockComponent bid -> ok MbAllComponents            $ queryE   (getBlockComponentModel allComponents bid)
    GetSuccessors bids    -> ok (Successors  . (<$> bids)) $ queryE    getSuccessorsModel
    GetPredecessor bids   -> ok (Predecessor . (<$> bids)) $ queryE    getPredecessorModel
    GetIsMember bids      -> ok (IsMember    . (<$> bids)) $ queryE    getIsMemberModel
    GarbageCollect slot   -> ok Unit                       $ updateE_ (garbageCollectModel slot)
    IsOpen                -> ok Bool                       $ query     isOpenModel
    Close                 -> ok Unit                       $ update_   closeModel
    ReOpen                -> ok Unit                       $ update_   reOpenModel
    GetMaxSlotNo          -> ok MaxSlot                    $ queryE    getMaxSlotNoModel
    PutBlock b            -> ok Unit                       $ updateE_ (putBlockModel blockInfo blob)
      where
        blockInfo = testBlockToBlockInfo b
        blob      = testBlockToBuilder b
    Corruption cors       -> ok Unit                       $ update_  (withClosedDB (runCorruptionsModel cors))
    DuplicateBlock {}     -> ok Unit                       $ update_  (withClosedDB noop)
  where
    query f m = (Right (f m), m)

    queryE f m = (f m, m)

    update_ f m = (Right (), f m)
    updateE_ f m = case f m of
      Left  e  -> (Left e, m)
      Right m' -> (Right (), m')

    ok :: (a -> Success)
       -> (DBModel BlockId -> (Either VolatileDBError a, DBModel BlockId))
       -> DBModel BlockId
       -> (Resp, DBModel BlockId)
    ok toSuccess f m = first (Resp . fmap toSuccess) $ f m

    withClosedDB action = reOpenModel . action . closeModel

    noop = id

-- | When simulating an error in the real implementation, we reopen the
-- VolatileDB and run the command again, as each command is idempotent. In the
-- model, we can just run the command once.
runPureErr :: DBModel BlockId
           -> CmdErr
           -> (Resp, DBModel BlockId)
runPureErr dbm (CmdErr cmd _mbErrors) = runPure cmd dbm

sm :: VolatileDBEnv h
   -> DBModel BlockId
   -> StateMachine Model (At CmdErr) IO (At Resp)
sm env dbm = StateMachine {
      initModel     = initModelImpl dbm
    , transition    = transitionImpl
    , precondition  = preconditionImpl
    , postcondition = postconditionImpl
    , generator     = generatorImpl
    , shrinker      = shrinkerImpl
    , semantics     = semanticsImpl env
    , mock          = mockImpl
    , invariant     = Nothing
    , distribution  = Nothing
    }

initModelImpl :: DBModel BlockId -> Model r
initModelImpl = Model

transitionImpl :: Model r -> At CmdErr r -> At Resp r -> Model r
transitionImpl model cmd _ = eventAfter $ lockstep model cmd

preconditionImpl :: Model Symbolic -> At CmdErr Symbolic -> Logic
preconditionImpl Model{..} (At (CmdErr cmd mbErrors)) =
    compatibleWithError .&& case cmd of
      GetPredecessor bids -> forall bids (`elem` bidsInModel)
      Corruption cors ->
        forall (corruptionFiles cors) (`elem` getDBFiles dbModel)

      -- When duplicating a block by appending it to some other file, make
      -- sure that both the file and the block exists, and that we're adding
      -- it /after/ the original block, so that truncating that the duplicated
      -- block brings us back in the original state.
      DuplicateBlock fileId b _ -> case fileIdContainingBlock b of
        Nothing      -> Bot
        Just fileId' -> fileId .>= fileId'
      _ -> Top
  where
    -- | All the 'BlockId' in the db.
    bidsInModel :: [BlockId]
    bidsInModel = blockIds dbModel

    -- | Corruption commands are not allowed to have errors.
    compatibleWithError :: Logic
    compatibleWithError
      | not (allowErrorFor cmd), Just _ <- mbErrors
      = Bot
      | otherwise
      = Top

    fileIdContainingBlock :: BlockId -> Maybe FileId
    fileIdContainingBlock b = listToMaybe
      [ fileId
      | (fileId, BlocksInFile blocks) <- Map.toList $ fileIndex dbModel
      , (BlockInfo { bbid }, _) <- blocks
      , bbid == b
      ]

postconditionImpl :: Model Concrete
                  -> At CmdErr Concrete
                  -> At Resp Concrete
                  -> Logic
postconditionImpl model cmdErr resp =
    toMock (eventAfter ev) resp .== eventMockResp ev
  where
    ev = lockstep model cmdErr

generatorCmdImpl :: Model Symbolic -> Gen Cmd
generatorCmdImpl Model {..} = frequency
    [ (3, PutBlock <$> genTestBlock)
    , (1, return IsOpen)
    , (1, return Close)
      -- When the DB is closed, we try to reopen it ASAP.
    , (if open dbModel then 1 else 5, return ReOpen)
    , (2, GetBlockComponent <$> genBlockId)
    , (2, GarbageCollect <$> genGCSlot)
    , (2, GetIsMember <$> listOf genBlockId)
    , (2, GetPredecessor <$> listOf genBlockId)
    , (2, GetSuccessors <$> listOf genWithOriginBlockId)
    , (2, return GetMaxSlotNo)

    , (if null dbFiles then 0 else 1,
       Corruption <$> generateCorruptions (NE.fromList dbFiles))
    , (if isEmpty then 0 else 1, genDuplicateBlock)
    ]
  where
    blockIdx = blockIndex dbModel

    dbFiles = getDBFiles dbModel

    isEmpty = Map.null blockIdx

    getSlot :: BlockId -> Maybe SlotNo
    getSlot bid = bslot . fst <$> Map.lookup bid blockIdx

    genSlotStartingFrom :: SlotNo -> Gen SlotNo
    genSlotStartingFrom slot = chooseSlot slot (slot + 20)

    mbMinMaxSlotInModel :: Maybe (SlotNo, SlotNo)
    mbMinMaxSlotInModel = do
      minSlot <- bslot . fst . fst <$> Map.minView blockIdx
      maxSlot <- bslot . fst . fst <$> Map.maxView blockIdx
      return (minSlot, maxSlot)

    -- Blocks don't have to be valid, i.e., they don't have to satisfy the
    -- invariants checked in MockChain and ChainFragment, etc. EBBs don't have
    -- to have a particular slot number, etc.
    genTestBlock :: Gen TestBlock
    genTestBlock = frequency
      [ (4, genBlockId >>= genSuccessor)
      , (1, genRandomBlock)
      ]

    genSuccessor :: BlockId -> Gen TestBlock
    genSuccessor prevHash = do
      b    <- genRandomBlock
      slot <- genSlotStartingFrom $ maybe 0 succ (getSlot prevHash)
      let body  = testBody b
          th    = testHeader b
          no    = thBlockNo th
          isEBB = thIsEBB th
      return $ mkBlock body (BlockHash prevHash) slot no isEBB

    genRandomBlock :: Gen TestBlock
    genRandomBlock = do
      body     <- TestBody <$> arbitrary <*> arbitrary
      prevHash <- frequency
        [ (1, return GenesisHash)
        , (6, BlockHash . TestHeaderHash <$> arbitrary)
        ]
      slot     <- genSlotStartingFrom 0
      -- We don't care about block numbers in the VolatileDB
      no       <- BlockNo <$> arbitrary
      isEBB    <- elements [IsEBB, IsNotEBB]
      return $ mkBlock body prevHash slot no isEBB

    genBlockId :: Gen BlockId
    genBlockId = frequency
      [ (if isEmpty then 0 else 5, elements $ Map.keys blockIdx)
      , (1, TestHeaderHash <$> arbitrary)
      , (4, blockHash <$> genTestBlock)
      ]

    genWithOriginBlockId :: Gen (WithOrigin BlockId)
    genWithOriginBlockId = frequency
      [ (1, return WithOrigin.Origin)
      , (8, WithOrigin.At <$> genBlockId)
      ]

    -- In general, we only want to GC part of the blocks, not all of them
    genGCSlot :: Gen SlotNo
    genGCSlot = case mbMinMaxSlotInModel of
      Nothing                 -> chooseSlot 0 10
      Just (minSlot, maxSlot) ->
        -- Sometimes GC a slot lower than @minSlot@ and GC a slot higher than
        -- @maxSlot@ (i.e., nothing and everything).
        chooseSlot (subtractNoUnderflow minSlot 3) (maxSlot + 3)

    subtractNoUnderflow :: (Num a, Ord a) => a -> a -> a
    subtractNoUnderflow x y
      | x >= y    = x - y
      | otherwise = 0

    chooseSlot :: SlotNo -> SlotNo -> Gen SlotNo
    chooseSlot (SlotNo start) (SlotNo end) = SlotNo <$> choose (start, end)

    genDuplicateBlock = do
      (originalFileId, bid, bytes) <- elements
        [ (fileId, bid, bytes)
        | (fileId, BlocksInFile blocks) <- Map.toList $ fileIndex dbModel
        , (BlockInfo { bbid = bid }, bytes) <- blocks
        ]
      fileId <- elements (getDBFileIds dbModel) `suchThat` (>= originalFileId)
      return $ DuplicateBlock fileId bid bytes

generatorImpl :: Model Symbolic -> Maybe (Gen (At CmdErr Symbolic))
generatorImpl m@Model {..} = Just $ do
    cmd <- generatorCmdImpl m
    err <- frequency
      [ (9, return Nothing)
      , (if allowErrorFor cmd && open dbModel then 1 else 0,
         -- Don't simulate errors while closed, because they won't have any
         -- effect, but also because we would reopen, which would not be
         -- idempotent.
         Just <$> genErrors True True)
      ]
    return $ At $ CmdErr cmd err

allowErrorFor :: Cmd -> Bool
allowErrorFor Corruption {}     = False
allowErrorFor DuplicateBlock {} = False
allowErrorFor _                 = True

shrinkerImpl :: Model Symbolic -> At CmdErr Symbolic -> [At CmdErr Symbolic]
shrinkerImpl m (At (CmdErr cmd mbErr)) = fmap At $
    [ CmdErr cmd mbErr' | mbErr' <- shrink mbErr ] ++
    [ CmdErr cmd' mbErr | cmd'   <- shrinkCmd m cmd ]

shrinkCmd :: Model Symbolic -> Cmd -> [Cmd]
shrinkCmd Model{..} cmd = case cmd of
    GetIsMember    bids  -> GetIsMember    <$> shrinkList (const []) bids
    GetPredecessor bids  -> GetPredecessor <$> shrinkList (const []) bids
    GetSuccessors  preds -> GetSuccessors  <$> shrinkList (const []) preds
    Corruption cors      -> Corruption <$> shrinkCorruptions cors
    _                    -> []

-- | Environment to run commands against the real VolatileDB implementation.
data VolatileDBEnv h = VolatileDBEnv
  { varErrors :: StrictTVar IO Errors
  , hasFS     :: HasFS IO h
  , db        :: VolatileDB BlockId IO
  }

semanticsImpl :: VolatileDBEnv h -> At CmdErr Concrete -> IO (At Resp Concrete)
semanticsImpl env@VolatileDBEnv { db, varErrors }  (At (CmdErr cmd mbErrors)) =
    At . Resp <$> case mbErrors of
      Nothing     -> try (runDB env cmd)
      Just errors -> do
        _ <- withErrors varErrors errors $
          tryDB (runDB env cmd)
        -- As all operations on the VolatileDB are idempotent, close
        -- (idempotent), reopen it, and run the command again.
        closeDB  db
        reOpenDB db
        try (runDB env cmd)
  where
    tryDB = tryVolDB EH.monadCatch EH.monadCatch

runDB :: HasCallStack
      => VolatileDBEnv h
      -> Cmd
      -> IO Success
runDB VolatileDBEnv { db, hasFS } cmd = case cmd of
    GetBlockComponent bid -> MbAllComponents          <$> getBlockComponent db allComponents bid
    PutBlock b            -> Unit                     <$> putBlock db (testBlockToBlockInfo b) (testBlockToBuilder b)
    GetSuccessors  bids   -> Successors .  (<$> bids) <$> atomically (getSuccessors db)
    GetPredecessor bids   -> Predecessor . (<$> bids) <$> atomically (getPredecessor db)
    GetIsMember    bids   -> IsMember .    (<$> bids) <$> atomically (getIsMember db)
    GarbageCollect slot   -> Unit                     <$> garbageCollect db slot
    GetMaxSlotNo          -> MaxSlot                  <$> atomically (getMaxSlotNo db)
    IsOpen                -> Bool                     <$> isOpenDB db
    Close                 -> Unit                     <$> closeDB db
    ReOpen                -> Unit                     <$> reOpenDB db
    Corruption corrs ->
      withClosedDB $
        forM_ corrs $ \(corr, file) -> corruptFile hasFS corr file
    DuplicateBlock fileId _ bytes -> do
      withClosedDB $
        withFile hasFS (filePath fileId) (AppendMode AllowExisting) $ \hndl ->
          void $ hPutAll hasFS hndl bytes
  where
    withClosedDB :: IO () -> IO Success
    withClosedDB action = do
      closeDB db
      action
      reOpenDB db
      return $ Unit ()

mockImpl :: Model Symbolic -> At CmdErr Symbolic -> GenSym (At Resp Symbolic)
mockImpl model cmdErr = At <$> return mockResp
  where
    (mockResp, _dbModel') = step model cmdErr


prop_sequential :: Property
prop_sequential = forAllCommands smUnused Nothing $ \cmds -> monadicIO $ do
    (hist, prop) <- test cmds
    let events = execCmds (initModel smUnused) cmds
    prettyCommands smUnused hist
        $ tabulate "Tags"
          (map show $ tag events)
        $ tabulate "Commands"
          (cmdName . eventCmd <$> events)
        $ tabulate "Error Tags"
          (tagSimulatedErrors events)
        $ tabulate "IsMember: total number of True's"
          [groupIsMember $ isMemberTrue events]
        $ tabulate "IsMember: at least one True"
          [show $ isMemberTrue' events]
        $ tabulate "Successors"
          (tagGetSuccessors events)
        $ tabulate "Predecessor"
          (tagGetPredecessor events)
        $ prop
  where
    dbm = initDBModel maxBlocksPerFile
    smUnused = sm unusedEnv dbm

    groupIsMember n
      | n < 5     = show n
      | n < 20    = "5-19"
      | n < 100   = "20-99"
      | otherwise = ">=100"

test :: Commands (At CmdErr) (At Resp)
     -> PropertyM IO (History (At CmdErr) (At Resp), Property)
test cmds = do
    varErrors          <- run $ uncheckedNewTVarM mempty
    varFs              <- run $ uncheckedNewTVarM Mock.empty
    (tracer, getTrace) <- run $ recordingTracerIORef

    let hasFS  = mkSimErrorHasFS EH.monadCatch varFs varErrors
        parser = blockFileParser' hasFS testBlockIsEBB
          testBlockToBinaryInfo (const <$> decode) testBlockIsValid
          ValidateAll

    db <- run $
      openDB hasFS EH.monadCatch errSTM parser tracer maxBlocksPerFile

    let env = VolatileDBEnv { varErrors, db, hasFS }
        sm' = sm env dbm
    (hist, _model, res) <- runCommands sm' cmds

    trace <- run $ getTrace
    fs    <- run $ atomically $ readTVar varFs

    monitor $ counterexample ("Trace: " <> unlines (map show trace))
    monitor $ counterexample ("FS: " <> Mock.pretty fs)

    run $ closeDB db
    return (hist, res === Ok)
  where
    dbm = initDBModel maxBlocksPerFile
    errSTM = EH.throwCantCatch EH.monadCatch

maxBlocksPerFile :: BlocksPerFile
maxBlocksPerFile = mkBlocksPerFile 3

unusedEnv :: VolatileDBEnv h
unusedEnv = error "VolatileDBEnv used during command generation"

tests :: TestTree
tests = testGroup "VolatileDB q-s-m" [
      testProperty "sequential" prop_sequential
    ]

{-------------------------------------------------------------------------------
  Labelling
-------------------------------------------------------------------------------}

-- | Predicate on events
type EventPred = C.Predicate (Event Symbolic) Tag

-- | Convenience combinator for creating classifiers for successful commands
successful :: (    Event Symbolic
                -> Success
                -> Either Tag EventPred
              )
           -> EventPred
successful f = C.predicate $ \ev -> case (eventMockResp ev, eventCmd ev) of
    (Resp (Right ok), At (CmdErr _ Nothing)) -> f ev ok
    _                                        -> Right $ successful f

-- | Tag commands
--
-- Tagging works on symbolic events, so that we can tag without doing real IO.
tag :: [Event Symbolic] -> [Tag]
tag [] = [TagEmpty]
tag ls = C.classify
    [ tagGetBlockComponentNothing
    , tagGetJust $ Left TagGetJust
    , tagGetReOpenGet
    , tagReOpenJust
    , tagGarbageCollect True Set.empty Nothing
    , tagCorruptWriteFile
    , tagIsClosedError
    , tagGarbageCollectThenReOpen
    ] ls
  where

    tagGetBlockComponentNothing :: EventPred
    tagGetBlockComponentNothing = successful $ \ev r -> case r of
      MbAllComponents Nothing | GetBlockComponent {} <- getCmd ev ->
        Left TagGetNothing
      _ -> Right tagGetBlockComponentNothing

    tagReOpenJust :: EventPred
    tagReOpenJust = tagReOpen False $ Right $ tagGetJust $ Left TagReOpenGet

    tagGetReOpenGet :: EventPred
    tagGetReOpenGet = tagGetJust $ Right $ tagReOpen False $
                        Right $ tagGetJust $ Left TagGetReOpenGet

    -- This rarely succeeds. I think this is because the last part
    -- (get -> Nothing) rarely succeeds. This happens because when a blockId is
    -- deleted is very unlikely to be requested.
    tagGarbageCollect :: Bool
                      -> Set BlockId
                      -> Maybe SlotNo
                      -> EventPred
    tagGarbageCollect keep bids mbGCed = successful $ \ev suc ->
      if not keep then Right $ tagGarbageCollect keep bids mbGCed
      else case (mbGCed, suc, getCmd ev) of
        (Nothing, _, PutBlock TestBlock{testHeader = TestHeader{..}})
          -> Right $ tagGarbageCollect
                       True
                       (Set.insert thHash bids)
                       Nothing
        (Nothing, _, GarbageCollect sl)
          -> Right $ tagGarbageCollect True bids (Just sl)
        (Just _gced, MbAllComponents Nothing, GetBlockComponent bid)
          | (Set.member bid bids)
          -> Left TagGarbageCollect
        (_, _, Corruption _)
          -> Right $ tagGarbageCollect False bids mbGCed
        _ -> Right $ tagGarbageCollect True bids mbGCed

    tagGetJust :: Either Tag EventPred -> EventPred
    tagGetJust next = successful $ \_ev suc -> case suc of
      MbAllComponents (Just _) -> next
      _                        -> Right $ tagGetJust next

    tagReOpen :: Bool -> Either Tag EventPred -> EventPred
    tagReOpen hasClosed next = successful $ \ev _ ->
      case (hasClosed, getCmd ev) of
        (True, ReOpen)        -> next
        (False, Close)        -> Right $ tagReOpen True next
        (False, Corruption _) -> Right $ tagReOpen True next
        _                     -> Right $ tagReOpen hasClosed next

    tagCorruptWriteFile :: EventPred
    tagCorruptWriteFile = successful $ \ev _ -> case getCmd ev of
        Corruption cors
          | let currentFile = getCurrentFile $ dbModel $ eventBefore ev
          , any (currentFileGotCorrupted currentFile) cors
          -> Left TagCorruptWriteFile
        _ -> Right tagCorruptWriteFile
      where
        currentFileGotCorrupted currentFile (cor, file)
          | DeleteFile <- cor
          = file == currentFile
          | otherwise
          = False

    tagIsClosedError :: EventPred
    tagIsClosedError = C.predicate $ \ev -> case eventMockResp ev of
      Resp (Left (UserError ClosedDBError)) -> Left TagClosedError
      _                                     -> Right tagIsClosedError

    tagGarbageCollectThenReOpen :: EventPred
    tagGarbageCollectThenReOpen = successful $ \ev _ -> case getCmd ev of
      GarbageCollect _ -> Right $ tagReOpen False $
                            Left TagGarbageCollectThenReOpen
      _                -> Right $ tagGarbageCollectThenReOpen

getCmd :: Event r -> Cmd
getCmd ev = cmd $ unAt (eventCmd ev)

isMemberTrue :: [Event Symbolic] -> Int
isMemberTrue events = sum $ count <$> events
  where
    count :: Event Symbolic -> Int
    count e = case eventMockResp e of
      Resp (Left _)              -> 0
      Resp (Right (IsMember ls)) -> length $ filter id ls
      Resp (Right _)             -> 0

isMemberTrue' :: [Event Symbolic] -> Int
isMemberTrue' events = sum $ count <$> events
  where
    count :: Event Symbolic -> Int
    count e = case eventMockResp e of
        Resp (Left _)              -> 0
        Resp (Right (IsMember ls)) -> if null ls then 0 else 1
        Resp (Right _)             -> 0

data Tag =
    -- | Request a block successfully
    --
    -- > GetBlockComponent (returns Just)
      TagGetJust

    -- | Try to get a non-existant block
    --
    -- > GetBlockComponent (returns Nothing)
    | TagGetNothing

    -- | Make a request, close, re-open and do another request.
    --
    -- > GetBlockComponent (returns Just)
    -- > CloseDB or Corrupt
    -- > ReOpen
    -- > GetBlockComponent (returns Just)
    | TagGetReOpenGet

    -- | Close, re-open and do a request.
    --
    -- > CloseDB or Corrupt
    -- > ReOpen
    -- > GetBlockComponent (returns Just)
    | TagReOpenGet

    -- | Test Garbage Collect.
    --
    -- > PutBlock
    -- > GarbageColect
    -- > GetBlockComponent (returns Nothing)
    | TagGarbageCollect

    -- | Try to delete the current active file.
    --
    -- > Corrupt Delete
    | TagCorruptWriteFile

    -- | A test with zero commands.
    | TagEmpty

    -- | Returns ClosedDBError (whatever Command)
    | TagClosedError

    -- | Gc then Close then Open
    --
    -- > GarbageCollect
    -- > CloseDB
    -- > ReOpen
    | TagGarbageCollectThenReOpen

    deriving Show

tagSimulatedErrors :: [Event Symbolic] -> [String]
tagSimulatedErrors events = fmap tagError events
  where
    tagError :: Event Symbolic -> String
    tagError ev = case eventCmd ev of
      At (CmdErr _ Nothing) -> "NoError"
      At (CmdErr cmd _)     -> cmdName (At cmd) <> " Error"

tagGetSuccessors :: [Event Symbolic] -> [String]
tagGetSuccessors = mapMaybe f
  where
    f :: Event Symbolic -> Maybe String
    f ev = case (getCmd ev, eventMockResp ev) of
        (GetSuccessors _pid, Resp (Right (Successors st))) ->
            if all Set.null st then Just "Empty Successors"
            else Just "Non empty Successors"
        _otherwise -> Nothing

tagGetPredecessor :: [Event Symbolic] -> [String]
tagGetPredecessor = mapMaybe f
  where
    f :: Event Symbolic -> Maybe String
    f ev = case (getCmd ev, eventMockResp ev) of
        (GetPredecessor _pid, Resp (Right (Predecessor _))) ->
            Just "Predecessor"
        _otherwise -> Nothing

execCmd :: Model Symbolic
        -> Command (At CmdErr) (At Resp)
        -> Event Symbolic
execCmd model (Command cmdErr _resp _vars) = lockstep model cmdErr

execCmds :: Model Symbolic -> Commands (At CmdErr) (At Resp) -> [Event Symbolic]
execCmds model (Commands cs) = go model cs
  where
    go :: Model Symbolic -> [Command (At CmdErr) (At Resp)] -> [Event Symbolic]
    go _ []        = []
    go m (c : css) = let ev = execCmd m c in ev : go (eventAfter ev) css

showLabelledExamples :: IO ()
showLabelledExamples = showLabelledExamples' Nothing 1000

showLabelledExamples' :: Maybe Int
                      -- ^ Seed
                      -> Int
                      -- ^ Number of tests to run to find examples
                      -> IO ()
showLabelledExamples' mReplay numTests = do
    replaySeed <- case mReplay of
        Nothing   -> getStdRandom (randomR (1,999999))
        Just seed -> return seed

    labelledExamplesWith (stdArgs { replay     = Just (mkQCGen replaySeed, 0)
                                  , maxSuccess = numTests
                                  }) $
        forAllShrinkShow (generateCommands smUnused Nothing)
                         (shrinkCommands   smUnused)
                         ppShow $ \cmds ->
            collects (tag . execCmds (initModel smUnused) $ cmds) $
                property True
  where
    dbm      = initDBModel maxBlocksPerFile
    smUnused = sm unusedEnv dbm
