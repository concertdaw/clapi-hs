module Data.Maybe.Clapi where

import Prelude hiding (fail)
import Control.Monad.Fail (MonadFail, fail)

toMonoid :: (Monoid a) => Maybe a -> a
toMonoid Nothing = mempty
toMonoid (Just a) = a

fromFoldable :: (Foldable t) => t a -> Maybe (t a)
fromFoldable t
  | null t = Nothing
  | otherwise = Just t

note :: (MonadFail m) => String -> Maybe a -> m a
note s Nothing = fail s
note s (Just a) = return a
