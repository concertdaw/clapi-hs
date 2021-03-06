{-# OPTIONS_GHC -Wall -Wno-orphans #-}
{-# LANGUAGE
    DataKinds
  , GADTs
#-}

module Clapi.Attributor where

import Control.Monad (forever)
import Data.Bifunctor (first)

import Clapi.Protocol (Protocol, waitThen, sendFwd, sendRev)
import Clapi.Types (Attributee, TrDigest(..), SomeTrDigest(..), DataChange(..))

attributor
  :: (Monad m, Functor f)
  => Attributee -> Protocol (f SomeTrDigest) (f SomeTrDigest) a a m ()
attributor u = forever $ waitThen (sendFwd . fmap attributeClient) sendRev
  where
    attributeClient sd@(SomeTrDigest d) = case d of
      Trcud {} -> SomeTrDigest $ d
        { trcudContOps = fmap (first modAttr) <$> trcudContOps d
        , trcudData = attributeDc <$> trcudData d
        }
      _ -> sd
    attributeDc dc = case dc of
      ConstChange ma vs -> ConstChange (modAttr ma) vs
      TimeChange m -> TimeChange $ first modAttr <$> m
    modAttr = Just . maybe u id
