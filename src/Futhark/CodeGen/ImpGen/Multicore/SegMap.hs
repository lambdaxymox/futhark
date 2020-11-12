module Futhark.CodeGen.ImpGen.Multicore.SegMap
  ( compileSegMap,
  )
where

import Control.Monad
import qualified Futhark.CodeGen.ImpCode.Multicore as Imp
import Futhark.CodeGen.ImpGen
import Futhark.CodeGen.ImpGen.Multicore.Base
import Futhark.IR.MCMem
import Futhark.Transform.Rename

writeResult ::
  [VName] ->
  PatElemT dec ->
  KernelResult ->
  MulticoreGen ()
writeResult is pe (Returns _ se) =
  copyDWIMFix (patElemName pe) (map Imp.vi64 is) se []
writeResult _ pe (WriteReturns rws _ idx_vals) = do
  let (iss, vs) = unzip idx_vals
      rws' = map toInt64Exp rws
  forM_ (zip iss vs) $ \(slice, v) -> do
    let slice' = map (fmap toInt64Exp) slice
        condInBounds (DimFix i) rw =
          0 .<=. i .&&. i .<. rw
        condInBounds (DimSlice i n s) rw =
          0 .<=. i .&&. i + n * s .<. rw
        in_bounds = foldl1 (.&&.) $ zipWith condInBounds slice' rws'
        when_in_bounds = copyDWIM (patElemName pe) slice' v []
    sWhen in_bounds when_in_bounds
writeResult _ _ res =
  error $ "writeResult: cannot handle " ++ pretty res

compileSegMapBody ::
  TV Int64 ->
  Pattern MCMem ->
  SegSpace ->
  KernelBody MCMem ->
  MulticoreGen Imp.Code
compileSegMapBody flat_idx pat space (KernelBody _ kstms kres) = do
  let (is, ns) = unzip $ unSegSpace space
      ns' = map toInt64Exp ns
  kstms' <- mapM renameStm kstms
  collect $ do
    emit $ Imp.DebugPrint "SegMap fbody" Nothing
    zipWithM_ dPrimV_ is $ map sExt64 $ unflattenIndex ns' $ tvExp flat_idx
    compileStms (freeIn kres) kstms' $
      zipWithM_ (writeResult is) (patternElements pat) kres

compileSegMap ::
  Pattern MCMem ->
  SegSpace ->
  KernelBody MCMem ->
  MulticoreGen Imp.Code
compileSegMap pat space kbody =
  collect $ do
    flat_par_idx <- dPrim "iter" int64
    body <- compileSegMapBody flat_par_idx pat space kbody
    free_params <- freeParams body [segFlat space, tvVar flat_par_idx]
    let (body_allocs, body') = extractAllocations body
    emit $ Imp.Op $ Imp.ParLoop "segmap" (tvVar flat_par_idx) body_allocs body' mempty free_params $ segFlat space
