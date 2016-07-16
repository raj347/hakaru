{-# LANGUAGE DataKinds,
             FlexibleContexts,
             GADTs,
             KindSignatures,
             RankNTypes #-}

----------------------------------------------------------------
--                                                    2016.06.23
-- |
-- Module      :  Language.Hakaru.CodeGen.Flatten
-- Copyright   :  Copyright (c) 2016 the Hakaru team
-- License     :  BSD3
-- Maintainer  :  zsulliva@indiana.edu
-- Stability   :  experimental
-- Portability :  GHC-only
--
--   Flatten takes Hakaru ABTs and C vars and returns a CStatement
-- assigning the var to the flattened ABT.
--
----------------------------------------------------------------


module Language.Hakaru.CodeGen.Flatten
  (flattenABT)
  where

import Language.Hakaru.CodeGen.CodeGenMonad
import Language.Hakaru.CodeGen.HOAS.Declaration
import Language.Hakaru.CodeGen.HOAS.Expression

import Language.Hakaru.Syntax.AST
import Language.Hakaru.Syntax.ABT
import Language.Hakaru.Syntax.Datum
import Language.Hakaru.Types.DataKind
import Language.Hakaru.Types.HClasses
import Language.Hakaru.Types.Sing

import Language.C.Syntax.AST

import           Data.Number.Natural
import           Data.Ratio
import qualified Data.Sequence      as S
import qualified Data.Foldable      as F
import qualified Data.Traversable   as T

import Prelude hiding (log,exp,sqrt)

flattenABT :: ABT Term abt
           => abt '[] a
           -> CodeGen CExpr
flattenABT abt = caseVarSyn abt flattenVar flattenTerm


flattenVar :: Variable (a :: Hakaru) -> CodeGen CExpr
flattenVar v = do ident <- lookupIdent v
                  return (varE ident)

flattenTerm :: ABT Term abt => Term abt a -> CodeGen CExpr
flattenTerm (NaryOp_ t s)    = flattenNAryOp t s
flattenTerm (Literal_ x)     = flattenLit x
flattenTerm (Empty_ _)       = error "TODO: flattenTerm Empty"
flattenTerm (Datum_ d)       = flattenDatum d
flattenTerm (Case_ _ _)      = error "TODO: flattenTerm Case"
flattenTerm (Array_ a es)    = flattenArray a es
flattenTerm (x :$ ys)        = flattenSCon x ys
flattenTerm (Reject_ _)      = error "TODO: flattenTerm Reject"
flattenTerm (Superpose_ _)   = error "TODO: flattenTerm Superpose"


----------------------------------------------------------------
flattenNAryOp :: ABT Term abt
              => NaryOp a
              -> S.Seq (abt '[] a)
              -> CodeGen CExpr
flattenNAryOp op args =
  do es <- T.mapM flattenABT args
     case op of
       (Sum HSemiring_Prob)  ->
         -- logsumexp algorithm for summing probs
         do maxId <- genIdent' "max"
            declare $ typeDeclaration SProb maxId
            -- first compute max
            assign maxId (maxE es)
            let maxVar = varE maxId

            -- compute diffs between max
            diffs <- T.forM es (\e -> do diffId <- genIdent' "dif"
                                         declare $ typeDeclaration SProb diffId
                                         assign diffId (e ^- maxVar)
                                         return (varE diffId))

            -- compute $ max + log(exp(diffs) + ...)
            sumId <- genIdent' "sum"
            declare $ typeDeclaration SProb sumId
            assign sumId $  maxVar
                         ^+ (log (F.foldr (binaryOp op)
                                          (S.index diffs 0)
                                          (S.drop 1 diffs)))
            return (varE sumId)

       -- otherwise
       _ -> return $ F.foldr (binaryOp op)
                             (S.index es 0)
                             (S.drop 1 es)

maxE :: S.Seq CExpr -> CExpr
maxE es = F.foldr check (S.index es 0) (S.drop 1 es)
  where check a b = condE (a ^> b) a b

----------------------------------------------------------------


flattenLit :: Literal a -> CodeGen CExpr
flattenLit lit =
  case lit of
    (LNat x)  -> return (intConstE $ fromIntegral x)
    (LInt x)  -> return (intConstE x)
    (LReal x) -> return (floatConstE $ fromRational x)
    (LProb x) -> let rat = fromNonNegativeRational x
                     x'  = (fromIntegral $ numerator rat)
                         / (fromIntegral $ denominator rat)
                 in do pId <- genIdent' "p"
                       declare $ typeDeclaration SProb pId
                       assign pId $ log (floatConstE x')
                       return (varE pId)

----------------------------------------------------------------


flattenArray :: (ABT Term abt)
             => (abt '[] 'HNat)
             -> (abt '[ 'HNat ] a)
             -> CodeGen CExpr
flattenArray a body =
  do ident <- genIdent
     arity' <- flattenABT a
     caseBind body $ \(Variable _ _ typ) _ ->
       do declare (arrayDeclaration typ arity' ident)
          return $ varE ident
----------------------------------------------------------------



flattenDatum :: (ABT Term abt)
             => Datum (abt '[]) (HData' a)
             -> CodeGen CExpr
flattenDatum (Datum _ _ code) =
  do ident <- genIdent
     declare $ structDeclaration code ident
     return (varE ident)
----------------------------------------------------------------


flattenSCon :: (ABT Term abt)
            => SCon args a
            -> SArgs abt args
            -> CodeGen CExpr
flattenSCon Let_            =
  \(expr :* body :* End) ->
    do expr' <- flattenABT expr
       caseBind body $ \v@(Variable _ _ typ) body'->
         do ident <- createIdent v
            declare $ typeDeclaration typ ident
            assign ident expr'
            flattenABT body'
flattenSCon (PrimOp_ op)    = \es -> flattenPrimOp op es
flattenSCon (MeasureOp_  m) = \es -> flattenMeasureOp m es
flattenSCon Dirac           = \(e :* End) -> flattenABT e
flattenSCon MBind           =
  \(e1 :* e2 :* End) ->
    do e1' <- flattenABT e1
       caseBind e2 $ \v@(Variable _ _ typ) e2'->
         do ident <- createIdent v
            declare $ typeDeclaration typ ident
            assign ident e1'
            flattenABT e2'
flattenSCon x               = \_ -> error $ "TODO: flattenSCon: " ++ show x
----------------------------------------------------------------


flattenPrimOp :: ( ABT Term abt
                 , typs ~ UnLCs args
                 , args ~ LCs typs)
              => PrimOp typs a
              -> SArgs abt args
              -> CodeGen CExpr
flattenPrimOp Pi = \End -> do ident <- genIdent
                              declare $ typeDeclaration SProb ident
                              assign ident $ log (stringVarE "M_PI")
                              return (varE ident)
flattenPrimOp t  = \_ -> error $ "TODO: flattenPrimOp: " ++ show t

----------------------------------------------------------------


flattenMeasureOp :: ( ABT Term abt
                    , typs ~ UnLCs args
                    , args ~ LCs typs)
                 => MeasureOp typs a
                 -> SArgs abt args
                 -> CodeGen CExpr
flattenMeasureOp Normal  = \(a :* b :* End) ->
  let randomE = (castE doubleTyp rand)
              ^/ (castE doubleTyp (stringVarE "RAND_MAX")) in
  do a' <- flattenABT a
     b' <- flattenABT b

     uId <- genIdent
     declare $ typeDeclaration SReal uId
     let varU = varE uId

     vId <- genIdent
     declare $ typeDeclaration SReal vId
     let varV = varE vId

     rId <- genIdent
     let varR = varE rId
     declare $ typeDeclaration SReal rId


     doWhileCG ((varR ^== (intConstE 0)) ^|| (varR ^> (intConstE 1)))
       $ do assign uId $ randomE ^* (floatConstE 2) ^- (floatConstE 1)
            assign vId $ randomE ^* (floatConstE 2) ^- (floatConstE 1)
            assign rId $ (varU ^* varU) ^+ (varV ^* varV)

     cId <- genIdent
     declare $ typeDeclaration SReal cId
     assign cId $ sqrt ((unaryE "-" (intConstE 2)) ^* (log varR ^/ varR))
     let varC = varE cId

     return (a' ^+ (varU ^* (varC ^* b')))

flattenMeasureOp Uniform = \(a :* b :* End) ->
  do a' <- flattenABT a
     b' <- flattenABT b
     ident <- genIdent
     declare $ typeDeclaration SReal ident
     let r    = castE doubleTyp rand
         rMax = castE doubleTyp (stringVarE "RAND_MAX")
     assign ident (a' ^+ ((r ^/ rMax) ^* (b' ^- a')))
     return (varE ident)
flattenMeasureOp x = error $ "TODO: flattenMeasureOp: " ++ show x
