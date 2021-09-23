{-# LANGUAGE TypeApplications #-}

module Test.Cardano.Ledger.Shelley.Examples
  ( CHAINExample (..),
    testCHAINExample,
  )
where

import Cardano.Ledger.Shelley ()
import Cardano.Ledger.Shelley.BlockChain (Block)
import Cardano.Ledger.Shelley.PParams (PParams' (..))
import Cardano.Ledger.Shelley.Rules.Chain (CHAIN, ChainState, totalAda)
import Cardano.Ledger.Shelley.Scripts ()
import Control.State.Transition.Extended hiding (Assertion)
import Control.State.Transition.Trace (checkTrace, (.-), (.->))
import Test.Cardano.Ledger.Shelley.ConcreteCryptoTypes (C)
import Test.Cardano.Ledger.Shelley.Orphans ()
import Test.Cardano.Ledger.Shelley.Utils (applySTSTest, maxLLSupply, runShelleyBase)
import Test.Tasty.HUnit (Assertion, (@?=))

data CHAINExample h = CHAINExample
  { -- | State to start testing with
    startState :: ChainState h,
    -- | Block to run chain state transition system on
    newBlock :: Block h,
    -- | type of fatal error, if failure expected and final chain state if success expected
    intendedResult :: Either [PredicateFailure (CHAIN h)] (ChainState h)
  }

-- | Runs example, applies chain state transition system rule (STS),
--   and checks that trace ends with expected state or expected error.
testCHAINExample :: CHAINExample C -> Assertion
testCHAINExample (CHAINExample initSt block (Right expectedSt)) = do
  (checkTrace @(CHAIN C) runShelleyBase () $ pure initSt .- block .-> expectedSt)
    >> (totalAda expectedSt @?= maxLLSupply)
testCHAINExample (CHAINExample initSt block predicateFailure@(Left _)) = do
  let st = runShelleyBase $ applySTSTest @(CHAIN C) (TRC ((), initSt, block))
  st @?= predicateFailure
