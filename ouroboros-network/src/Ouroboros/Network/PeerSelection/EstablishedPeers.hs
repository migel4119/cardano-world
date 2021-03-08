{-# LANGUAGE DeriveFunctor  #-}
{-# LANGUAGE NamedFieldPuns #-}

{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

module Ouroboros.Network.PeerSelection.EstablishedPeers
  ( EstablishedPeers
  , empty
  , toMap
  , readyPeers
  , establishedStatus

  , size
  , sizeReady

  , member

  , insert
  , delete
  , deletePeers

  , updateStatus
  , updateStatuses

  , setCurrentTime
  , minActivateTime
  , setActivateTime

  , invariant
  ) where

import           Prelude

import           Data.Foldable (foldl')
import qualified Data.Map.Strict as Map
import           Data.Map.Strict (Map)
import           Data.OrdPSQ (OrdPSQ)
import qualified Data.OrdPSQ as PSQ
import qualified Data.Set as Set
import           Data.Set (Set)

import           Control.Monad.Class.MonadTime
import           Control.Exception (assert)

import           Ouroboros.Network.PeerSelection.Types


data EstablishedPeers peeraddr peerconn = EstablishedPeers {
    -- | Peers which are either ready to become active or are active.
    --
    allPeers          :: !(Map peeraddr peerconn),

    -- | 'PeerStatus' of all established peers.
    establishedStatus :: !(Map peeraddr PeerStatus),

    -- | Peers which are not ready to become active.
    nextActivateTimes :: !(OrdPSQ peeraddr Time ())
  }
  deriving (Show, Functor)


empty :: EstablishedPeers peeraddr perconn
empty = EstablishedPeers Map.empty Map.empty PSQ.empty


invariant :: Ord peeraddr
          => EstablishedPeers peeraddr peerconn
          -> Bool
invariant EstablishedPeers { allPeers,
                             establishedStatus,
                             nextActivateTimes } =
     -- nextActivateTimes is a subset of allPeers
     Set.fromList (PSQ.keys nextActivateTimes)
     `Set.isSubsetOf`
     Map.keysSet allPeers

     -- allPeers has the same keys as
     -- establishedStatus
  &&    Map.keysSet allPeers
     == Map.keysSet establishedStatus

     -- there are only warm peers in 'nextActiveTimes'
  && all (== PeerWarm)
         (Map.filterWithKey
           (\peeraddr _ -> PSQ.member peeraddr nextActivateTimes)
           establishedStatus)

     -- there are no cold peers
  && all (/= PeerCold) establishedStatus
-- | /O(1)/
toMap :: EstablishedPeers peeraddr peerconn -> Map peeraddr peerconn
toMap = allPeers


-- | Map of established peers that are either active or ready to be promoted
-- to active.
--
-- /O(n log m), for n not-ready peers, and m established peers/
--
readyPeers :: Ord peeraddr
           => EstablishedPeers peeraddr peerconn
           -> Map peeraddr peerconn
readyPeers EstablishedPeers { allPeers, nextActivateTimes } =
    PSQ.fold'
      (\peeraddr _ _ -> Map.delete peeraddr)
      allPeers
      nextActivateTimes


-- | The number of established peers. The size of 'allPeers'
--
-- /O(1)/
--
size :: EstablishedPeers peeraddr peerconn -> Int
size EstablishedPeers { allPeers } = Map.size allPeers


-- | The number of ready peers. The size of 'readyPeers'
--
-- /O(1)/
--
sizeReady :: EstablishedPeers peeraddr peerconn -> Int
sizeReady EstablishedPeers { allPeers, nextActivateTimes } =
    Map.size allPeers - PSQ.size nextActivateTimes


member :: Ord peeraddr => peeraddr -> EstablishedPeers peeraddr peerconn -> Bool
member peeraddr = Map.member peeraddr . allPeers


-- | Insert a peer into 'EstablishedPeers'.
--
insert :: Ord peeraddr
       => peeraddr
       -> peerconn
       -> EstablishedPeers peeraddr peerconn
       -> EstablishedPeers peeraddr peerconn
insert peeraddr peerconn ep@EstablishedPeers { allPeers, establishedStatus } =
  ep { allPeers          = Map.insert peeraddr peerconn allPeers,
       establishedStatus = Map.insert peeraddr PeerWarm establishedStatus }

updateStatus :: Ord peeraddr
             => peeraddr
             -> PeerStatus
             -- ^ keys must be a subset of keys of 'establishedStatus' map
             -> EstablishedPeers peeraddr peerconn
             -> EstablishedPeers peeraddr peerconn
updateStatus peeraddr peerStatus ep@EstablishedPeers { establishedStatus } =
    assert (Map.member peeraddr establishedStatus) $
    ep { establishedStatus = Map.insert peeraddr peerStatus establishedStatus }

-- | Update 'establishedStatus' map.
--
updateStatuses :: Ord peeraddr
               => Map peeraddr PeerStatus
               -- ^ keys must be a subset of keys of 'establishedStatus' map
               -> EstablishedPeers peeraddr peerconn
               -> EstablishedPeers peeraddr peerconn
updateStatuses newStatuses ep@EstablishedPeers { establishedStatus } =
    assert (Map.isSubmapOfBy (\_ _ -> True) newStatuses establishedStatus) $
    ep { establishedStatus = newStatuses <> establishedStatus }


delete :: Ord peeraddr
       => peeraddr
       -> EstablishedPeers peeraddr peerconn
       -> EstablishedPeers peeraddr peerconn
delete peeraddr es@EstablishedPeers { allPeers,
                                      establishedStatus,
                                      nextActivateTimes } =
    es { allPeers          = Map.delete peeraddr allPeers,
         establishedStatus = Map.delete peeraddr establishedStatus,
         nextActivateTimes = PSQ.delete peeraddr nextActivateTimes }



-- | Bulk delete of peers from 'EstablishedPeers.
--
deletePeers :: Ord peeraddr
            => Set peeraddr
            -> EstablishedPeers peeraddr peerconn
            -> EstablishedPeers peeraddr peerconn
deletePeers peeraddrs es@EstablishedPeers { allPeers,
                                            establishedStatus,
                                            nextActivateTimes } =
    es { allPeers          = foldl' (flip Map.delete) allPeers  peeraddrs,
         establishedStatus = foldl' (flip Map.delete) establishedStatus peeraddrs,
         nextActivateTimes = foldl' (flip PSQ.delete) nextActivateTimes peeraddrs }


--
-- Time managment
--

setCurrentTime :: Ord peeraddr
               => Time
               -> EstablishedPeers peeraddr peerconn
               -> EstablishedPeers peeraddr peerconn
setCurrentTime now ep@EstablishedPeers { nextActivateTimes } =
    let ep' = ep { nextActivateTimes = nextActivateTimes' }
    in assert (invariant ep') ep'
  where
    (_, nextActivateTimes') = PSQ.atMostView now nextActivateTimes


minActivateTime :: Ord peeraddr
                => EstablishedPeers peeraddr peerconn
                -> Maybe Time
minActivateTime EstablishedPeers { nextActivateTimes }
  | Just (_k, t, _, _psq) <- PSQ.minView nextActivateTimes
  = Just t

  | otherwise
  = Nothing


setActivateTime :: Ord peeraddr
                => Set peeraddr
                -> Time
                -> EstablishedPeers peeraddr peerconn
                -> EstablishedPeers peeraddr peerconn
setActivateTime peeraddrs _time ep | Set.null peeraddrs = ep
setActivateTime peeraddrs time  ep@EstablishedPeers { nextActivateTimes } =
    let ep' = ep { nextActivateTimes = foldl' (\psq peeraddr -> PSQ.insert peeraddr time () psq)
                                              nextActivateTimes
                                              peeraddrs
                 }
    in   assert (all (not . (`Map.member` readyPeers ep')) peeraddrs)
       . assert (invariant ep')
       $ ep'
