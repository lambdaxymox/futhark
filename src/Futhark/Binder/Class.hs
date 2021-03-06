{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}

-- | This module defines a convenience typeclass for creating
-- normalised programs.
--
-- See "Futhark.Construct" for a high-level description.
module Futhark.Binder.Class
  ( Bindable (..),
    mkLet,
    mkLet',
    MonadBinder (..),
    insertStms,
    insertStm,
    letBind,
    letBindNames,
    collectStms_,
    bodyBind,
    attributing,
    auxing,
    module Futhark.MonadFreshNames,
  )
where

import qualified Data.Kind
import Futhark.IR
import Futhark.MonadFreshNames

-- | The class of representations that can be constructed solely from
-- an expression, within some monad.  Very important: the methods
-- should not have any significant side effects!  They may be called
-- more often than you think, and the results thrown away.  If used
-- exclusively within a 'MonadBinder' instance, it is acceptable for
-- them to create new bindings, however.
class
  ( ASTRep rep,
    FParamInfo rep ~ DeclType,
    LParamInfo rep ~ Type,
    RetType rep ~ DeclExtType,
    BranchType rep ~ ExtType,
    SetType (LetDec rep)
  ) =>
  Bindable rep
  where
  mkExpPat :: [Ident] -> [Ident] -> Exp rep -> Pattern rep
  mkExpDec :: Pattern rep -> Exp rep -> ExpDec rep
  mkBody :: Stms rep -> Result -> Body rep
  mkLetNames ::
    (MonadFreshNames m, HasScope rep m) =>
    [VName] ->
    Exp rep ->
    m (Stm rep)

-- | A monad that supports the creation of bindings from expressions
-- and bodies from bindings, with a specific rep.  This is the main
-- typeclass that a monad must implement in order for it to be useful
-- for generating or modifying Futhark code.  Most importantly
-- maintains a current state of 'Stms' (as well as a 'Scope') that
-- have been added with 'addStm'.
--
-- Very important: the methods should not have any significant side
-- effects!  They may be called more often than you think, and the
-- results thrown away.  It is acceptable for them to create new
-- bindings, however.
class
  ( ASTRep (Rep m),
    MonadFreshNames m,
    Applicative m,
    Monad m,
    LocalScope (Rep m) m
  ) =>
  MonadBinder m
  where
  type Rep m :: Data.Kind.Type
  mkExpDecM :: Pattern (Rep m) -> Exp (Rep m) -> m (ExpDec (Rep m))
  mkBodyM :: Stms (Rep m) -> Result -> m (Body (Rep m))
  mkLetNamesM :: [VName] -> Exp (Rep m) -> m (Stm (Rep m))

  -- | Add a statement to the 'Stms' under construction.
  addStm :: Stm (Rep m) -> m ()
  addStm = addStms . oneStm

  -- | Add multiple statements to the 'Stms' under construction.
  addStms :: Stms (Rep m) -> m ()

  -- | Obtain the statements constructed during a monadic action,
  -- instead of adding them to the state.
  collectStms :: m a -> m (a, Stms (Rep m))

  -- | Add the provided certificates to any statements added during
  -- execution of the action.
  certifying :: Certificates -> m a -> m a
  certifying = censorStms . fmap . certify

-- | Apply a function to the statements added by this action.
censorStms ::
  MonadBinder m =>
  (Stms (Rep m) -> Stms (Rep m)) ->
  m a ->
  m a
censorStms f m = do
  (x, stms) <- collectStms m
  addStms $ f stms
  return x

-- | Add the given attributes to any statements added by this action.
attributing :: MonadBinder m => Attrs -> m a -> m a
attributing attrs = censorStms $ fmap onStm
  where
    onStm (Let pat aux e) =
      Let pat aux {stmAuxAttrs = attrs <> stmAuxAttrs aux} e

-- | Add the certificates and attributes to any statements added by
-- this action.
auxing :: MonadBinder m => StmAux anyrep -> m a -> m a
auxing (StmAux cs attrs _) = censorStms $ fmap onStm
  where
    onStm (Let pat aux e) =
      Let pat aux' e
      where
        aux' =
          aux
            { stmAuxAttrs = attrs <> stmAuxAttrs aux,
              stmAuxCerts = cs <> stmAuxCerts aux
            }

-- | Add a statement with the given pattern and expression.
letBind ::
  MonadBinder m =>
  Pattern (Rep m) ->
  Exp (Rep m) ->
  m ()
letBind pat e =
  addStm =<< Let pat <$> (defAux <$> mkExpDecM pat e) <*> pure e

-- | Construct a 'Stm' from identifiers for the context- and value
-- part of the pattern, as well as the expression.
mkLet :: Bindable rep => [Ident] -> [Ident] -> Exp rep -> Stm rep
mkLet ctx val e =
  let pat = mkExpPat ctx val e
      dec = mkExpDec pat e
   in Let pat (defAux dec) e

-- | Like mkLet, but also take attributes and certificates from the
-- given 'StmAux'.
mkLet' :: Bindable rep => [Ident] -> [Ident] -> StmAux a -> Exp rep -> Stm rep
mkLet' ctx val (StmAux cs attrs _) e =
  let pat = mkExpPat ctx val e
      dec = mkExpDec pat e
   in Let pat (StmAux cs attrs dec) e

-- | Add a statement with the given pattern element names and
-- expression.
letBindNames :: MonadBinder m => [VName] -> Exp (Rep m) -> m ()
letBindNames names e = addStm =<< mkLetNamesM names e

-- | As 'collectStms', but throw away the ordinary result.
collectStms_ :: MonadBinder m => m a -> m (Stms (Rep m))
collectStms_ = fmap snd . collectStms

-- | Add the statements of the body, then return the body result.
bodyBind :: MonadBinder m => Body (Rep m) -> m [SubExp]
bodyBind (Body _ stms es) = do
  addStms stms
  return es

-- | Add several bindings at the outermost level of a t'Body'.
insertStms :: Bindable rep => Stms rep -> Body rep -> Body rep
insertStms stms1 (Body _ stms2 res) = mkBody (stms1 <> stms2) res

-- | Add a single binding at the outermost level of a t'Body'.
insertStm :: Bindable rep => Stm rep -> Body rep -> Body rep
insertStm = insertStms . oneStm
