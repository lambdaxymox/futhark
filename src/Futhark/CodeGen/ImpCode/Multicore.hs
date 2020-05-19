-- | Multicore imperative code.
module Futhark.CodeGen.ImpCode.Multicore
       ( Program
       , Function
       , FunctionT (Function)
       , Code
       , Multicore(..)
       , MulticoreFunc(..)
       , Scheduling(..)
       , ValueType(..)
       , module Futhark.CodeGen.ImpCode
       )
       where

import Futhark.CodeGen.ImpCode hiding (Function, Code)
import qualified Futhark.CodeGen.ImpCode as Imp
import Futhark.Util.Pretty

-- | An imperative program.
type Program = Imp.Functions Multicore

-- | An imperative function.
type Function = Imp.Function Multicore

-- | A piece of imperative code, with multicore operations inside.
type Code = Imp.Code Multicore

-- | A function
data MulticoreFunc = MulticoreFunc [Param] Code Code VName

-- | A parallel operation.
data Multicore = ParLoop Scheduling VName VName Imp.Exp MulticoreFunc
               | MulticoreCall (Maybe VName) String  -- This needs to be fixed

type Granularity = Int32

data ValueType = Prim | MemBlock | Other

-- | Whether the Scheduler can/should schedule the tasks as Dynamic
-- or it is restainted to Static
-- This could carry more information
data Scheduling = Dynamic Granularity
                | Static

instance Pretty MulticoreFunc where
  ppr (MulticoreFunc params prebody body _ ) =
    ppr params <+>
    ppr prebody <+>
    langle <+>
    nestedBlock "{" "}" (ppr body)

instance Pretty Multicore where
  ppr (ParLoop _ _ntask i e func) =
    text "parfor" <+> ppr i <+> langle <+> ppr e <+>
    nestedBlock "{" "}" (ppr func)
  ppr (MulticoreCall dests f) =
    ppr dests <+> ppr f


instance FreeIn MulticoreFunc where
  freeIn' (MulticoreFunc _ prebody body _) =
    freeIn' prebody <> fvBind (Imp.declaredIn prebody) (freeIn' body)

instance FreeIn Multicore where
  freeIn' (ParLoop _ ntask i e func) =
    fvBind (oneName i) $ freeIn' ntask <> freeIn' e <> freeIn' func
  freeIn' (MulticoreCall dests _ ) = freeIn' dests
