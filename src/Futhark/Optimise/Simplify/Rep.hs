{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Representation used by the simplification engine.
module Futhark.Optimise.Simplify.Rep
  ( Wise,
    VarWisdom (..),
    ExpWisdom,
    removeStmWisdom,
    removeLambdaWisdom,
    removeFunDefWisdom,
    removeExpWisdom,
    removePatternWisdom,
    removeBodyWisdom,
    removeScopeWisdom,
    addScopeWisdom,
    addWisdomToPattern,
    mkWiseBody,
    mkWiseLetStm,
    mkWiseExpDec,
    CanBeWise (..),
  )
where

import Control.Category
import Control.Monad.Identity
import Control.Monad.Reader
import qualified Data.Kind
import qualified Data.Map.Strict as M
import Futhark.Analysis.Rephrase
import Futhark.Binder
import Futhark.IR
import Futhark.IR.Aliases
  ( AliasDec (..),
    ConsumedInExp,
    VarAliases,
    unAliases,
  )
import qualified Futhark.IR.Aliases as Aliases
import Futhark.IR.Prop.Aliases
import Futhark.Transform.Rename
import Futhark.Transform.Substitute
import Futhark.Util.Pretty
import Prelude hiding (id, (.))

data Wise rep

-- | The wisdom of the let-bound variable.
newtype VarWisdom = VarWisdom {varWisdomAliases :: VarAliases}
  deriving (Eq, Ord, Show)

instance Rename VarWisdom where
  rename = substituteRename

instance Substitute VarWisdom where
  substituteNames substs (VarWisdom als) =
    VarWisdom (substituteNames substs als)

instance FreeIn VarWisdom where
  freeIn' (VarWisdom als) = freeIn' als

-- | Wisdom about an expression.
data ExpWisdom = ExpWisdom
  { _expWisdomConsumed :: ConsumedInExp,
    expWisdomFree :: AliasDec
  }
  deriving (Eq, Ord, Show)

instance FreeIn ExpWisdom where
  freeIn' = mempty

instance FreeDec ExpWisdom where
  precomputed = const . fvNames . unAliases . expWisdomFree

instance Substitute ExpWisdom where
  substituteNames substs (ExpWisdom cons free) =
    ExpWisdom
      (substituteNames substs cons)
      (substituteNames substs free)

instance Rename ExpWisdom where
  rename = substituteRename

-- | Wisdom about a body.
data BodyWisdom = BodyWisdom
  { bodyWisdomAliases :: [VarAliases],
    bodyWisdomConsumed :: ConsumedInExp,
    bodyWisdomFree :: AliasDec
  }
  deriving (Eq, Ord, Show)

instance Rename BodyWisdom where
  rename = substituteRename

instance Substitute BodyWisdom where
  substituteNames substs (BodyWisdom als cons free) =
    BodyWisdom
      (substituteNames substs als)
      (substituteNames substs cons)
      (substituteNames substs free)

instance FreeIn BodyWisdom where
  freeIn' (BodyWisdom als cons free) =
    freeIn' als <> freeIn' cons <> freeIn' free

instance FreeDec BodyWisdom where
  precomputed = const . fvNames . unAliases . bodyWisdomFree

instance (RepTypes rep, CanBeWise (Op rep)) => RepTypes (Wise rep) where
  type LetDec (Wise rep) = (VarWisdom, LetDec rep)
  type ExpDec (Wise rep) = (ExpWisdom, ExpDec rep)
  type BodyDec (Wise rep) = (BodyWisdom, BodyDec rep)
  type FParamInfo (Wise rep) = FParamInfo rep
  type LParamInfo (Wise rep) = LParamInfo rep
  type RetType (Wise rep) = RetType rep
  type BranchType (Wise rep) = BranchType rep
  type Op (Wise rep) = OpWithWisdom (Op rep)

withoutWisdom ::
  (HasScope (Wise rep) m, Monad m) =>
  ReaderT (Scope rep) m a ->
  m a
withoutWisdom m = do
  scope <- asksScope removeScopeWisdom
  runReaderT m scope

instance (ASTRep rep, CanBeWise (Op rep)) => ASTRep (Wise rep) where
  expTypesFromPattern =
    withoutWisdom . expTypesFromPattern . removePatternWisdom

instance Pretty VarWisdom where
  ppr _ = ppr ()

instance (PrettyRep rep, CanBeWise (Op rep)) => PrettyRep (Wise rep) where
  ppExpDec (_, dec) = ppExpDec dec . removeExpWisdom

instance AliasesOf (VarWisdom, dec) where
  aliasesOf = unAliases . varWisdomAliases . fst

instance (ASTRep rep, CanBeWise (Op rep)) => Aliased (Wise rep) where
  bodyAliases = map unAliases . bodyWisdomAliases . fst . bodyDec
  consumedInBody = unAliases . bodyWisdomConsumed . fst . bodyDec

removeWisdom :: CanBeWise (Op rep) => Rephraser Identity (Wise rep) rep
removeWisdom =
  Rephraser
    { rephraseExpDec = return . snd,
      rephraseLetBoundDec = return . snd,
      rephraseBodyDec = return . snd,
      rephraseFParamDec = return,
      rephraseLParamDec = return,
      rephraseRetType = return,
      rephraseBranchType = return,
      rephraseOp = return . removeOpWisdom
    }

removeScopeWisdom :: Scope (Wise rep) -> Scope rep
removeScopeWisdom = M.map unAlias
  where
    unAlias (LetName (_, dec)) = LetName dec
    unAlias (FParamName dec) = FParamName dec
    unAlias (LParamName dec) = LParamName dec
    unAlias (IndexName it) = IndexName it

addScopeWisdom :: Scope rep -> Scope (Wise rep)
addScopeWisdom = M.map alias
  where
    alias (LetName dec) = LetName (VarWisdom mempty, dec)
    alias (FParamName dec) = FParamName dec
    alias (LParamName dec) = LParamName dec
    alias (IndexName it) = IndexName it

removeFunDefWisdom :: CanBeWise (Op rep) => FunDef (Wise rep) -> FunDef rep
removeFunDefWisdom = runIdentity . rephraseFunDef removeWisdom

removeStmWisdom :: CanBeWise (Op rep) => Stm (Wise rep) -> Stm rep
removeStmWisdom = runIdentity . rephraseStm removeWisdom

removeLambdaWisdom :: CanBeWise (Op rep) => Lambda (Wise rep) -> Lambda rep
removeLambdaWisdom = runIdentity . rephraseLambda removeWisdom

removeBodyWisdom :: CanBeWise (Op rep) => Body (Wise rep) -> Body rep
removeBodyWisdom = runIdentity . rephraseBody removeWisdom

removeExpWisdom :: CanBeWise (Op rep) => Exp (Wise rep) -> Exp rep
removeExpWisdom = runIdentity . rephraseExp removeWisdom

removePatternWisdom :: PatternT (VarWisdom, a) -> PatternT a
removePatternWisdom = runIdentity . rephrasePattern (return . snd)

addWisdomToPattern ::
  (ASTRep rep, CanBeWise (Op rep)) =>
  Pattern rep ->
  Exp (Wise rep) ->
  Pattern (Wise rep)
addWisdomToPattern pat e =
  Pattern (map f ctx) (map f val)
  where
    (ctx, val) = Aliases.mkPatternAliases pat e
    f pe =
      let (als, dec) = patElemDec pe
       in pe `setPatElemDec` (VarWisdom als, dec)

mkWiseBody ::
  (ASTRep rep, CanBeWise (Op rep)) =>
  BodyDec rep ->
  Stms (Wise rep) ->
  Result ->
  Body (Wise rep)
mkWiseBody dec bnds res =
  Body
    ( BodyWisdom aliases consumed (AliasDec $ freeIn $ freeInStmsAndRes bnds res),
      dec
    )
    bnds
    res
  where
    (aliases, consumed) = Aliases.mkBodyAliases bnds res

mkWiseLetStm ::
  (ASTRep rep, CanBeWise (Op rep)) =>
  Pattern rep ->
  StmAux (ExpDec rep) ->
  Exp (Wise rep) ->
  Stm (Wise rep)
mkWiseLetStm pat (StmAux cs attrs dec) e =
  let pat' = addWisdomToPattern pat e
   in Let pat' (StmAux cs attrs $ mkWiseExpDec pat' dec e) e

mkWiseExpDec ::
  (ASTRep rep, CanBeWise (Op rep)) =>
  Pattern (Wise rep) ->
  ExpDec rep ->
  Exp (Wise rep) ->
  ExpDec (Wise rep)
mkWiseExpDec pat expdec e =
  ( ExpWisdom
      (AliasDec $ consumedInExp e)
      (AliasDec $ freeIn pat <> freeIn expdec <> freeIn e),
    expdec
  )

instance
  ( Bindable rep,
    CanBeWise (Op rep)
  ) =>
  Bindable (Wise rep)
  where
  mkExpPat ctx val e =
    addWisdomToPattern (mkExpPat ctx val $ removeExpWisdom e) e

  mkExpDec pat e =
    mkWiseExpDec pat (mkExpDec (removePatternWisdom pat) $ removeExpWisdom e) e

  mkLetNames names e = do
    env <- asksScope removeScopeWisdom
    flip runReaderT env $ do
      Let pat dec _ <- mkLetNames names $ removeExpWisdom e
      return $ mkWiseLetStm pat dec e

  mkBody bnds res =
    let Body bodyrep _ _ = mkBody (fmap removeStmWisdom bnds) res
     in mkWiseBody bodyrep bnds res

class
  ( AliasedOp (OpWithWisdom op),
    IsOp (OpWithWisdom op)
  ) =>
  CanBeWise op
  where
  type OpWithWisdom op :: Data.Kind.Type
  removeOpWisdom :: OpWithWisdom op -> op

instance CanBeWise () where
  type OpWithWisdom () = ()
  removeOpWisdom () = ()
