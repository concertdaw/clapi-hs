{-# LANGUAGE Rank2Types #-}

module Clapi.Types.Definitions where

import Prelude hiding (fail)
import Control.Monad.Fail (MonadFail(..))
import Data.Tagged (Tagged)
import Data.Text (Text)

import Data.Maybe.Clapi (note)

import Clapi.Types.AssocList (AssocList, unAssocList)
import Clapi.Types.Base (InterpolationLimit(..))
import Clapi.Types.Path (Seg)
import Clapi.Types.Tree (SomeTreeType(..))

data Editable = Editable | ReadOnly deriving (Show, Eq, Enum, Bounded)

data MetaType = Tuple | Struct | Array deriving (Show, Eq, Enum, Bounded)

type DefName = Tagged Definition Seg
type PostDefName = Tagged PostDefinition Seg

class OfMetaType metaType where
  metaType :: metaType -> MetaType
  childTypeFor :: Seg -> metaType -> Maybe DefName
  childEditableFor :: MonadFail m => metaType -> Seg -> m Editable

data PostDefinition = PostDefinition
  { postDefDoc :: Text
  -- FIXME: We really need to stop treating single values as lists of types,
  -- which makes the "top level" special:
  , postDefArgs :: AssocList Seg [SomeTreeType]
  } deriving (Show)

data TupleDefinition = TupleDefinition
  { tupDefDoc :: Text
  -- FIXME: this should eventually boil down to a single TreeType (NB remove
  -- names too and just write more docstring) now that we have pairs:
  , tupDefTypes :: AssocList Seg SomeTreeType
  , tupDefInterpLimit :: InterpolationLimit
  } deriving (Show)

instance OfMetaType TupleDefinition where
  metaType _ = Tuple
  childTypeFor _ _ = Nothing
  childEditableFor _ _ = fail "Tuples have no children"

data StructDefinition = StructDefinition
  { strDefDoc :: Text
  , strDefTypes :: AssocList Seg (DefName, Editable)
  } deriving (Show, Eq)

instance OfMetaType StructDefinition where
  metaType _ = Struct
  childTypeFor seg (StructDefinition _ tyInfo) =
    fst <$> lookup seg (unAssocList tyInfo)
  childEditableFor (StructDefinition _ tyInfo) seg = note "No such child" $
    snd <$> lookup seg (unAssocList tyInfo)

data ArrayDefinition = ArrayDefinition
  { arrDefDoc :: Text
  , arrPostType :: Maybe PostDefName
  , arrDefChildType :: DefName
  , arrDefChildEditable :: Editable
  } deriving (Show, Eq)

instance OfMetaType ArrayDefinition where
  metaType _ = Array
  childTypeFor _ = Just . arrDefChildType
  childEditableFor ad _ = return $ arrDefChildEditable ad


data Definition
  = TupleDef TupleDefinition
  | StructDef StructDefinition
  | ArrayDef ArrayDefinition
  deriving (Show)

tupleDef :: Text -> AssocList Seg SomeTreeType -> InterpolationLimit -> Definition
tupleDef doc types interpl = TupleDef $ TupleDefinition doc types interpl

structDef
  :: Text -> AssocList Seg (DefName, Editable) -> Definition
structDef doc types = StructDef $ StructDefinition doc types

arrayDef :: Text -> Maybe PostDefName -> DefName -> Editable -> Definition
arrayDef doc ptn tn ed = ArrayDef $ ArrayDefinition doc ptn tn ed

defDispatch :: (forall a. OfMetaType a => a -> r) -> Definition -> r
defDispatch f (TupleDef d) = f d
defDispatch f (StructDef d) = f d
defDispatch f (ArrayDef d) = f d
