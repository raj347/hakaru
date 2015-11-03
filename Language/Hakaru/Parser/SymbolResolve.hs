{-# LANGUAGE RankNTypes,
             GADTs,
             OverloadedStrings,
             ExistentialQuantification,
             StandaloneDeriving #-}
module Language.Hakaru.Parser.SymbolResolve where

import Data.List
import Data.Text hiding (map, maximum)
import Control.Monad.Trans.State.Strict (State, state)

import Language.Hakaru.Syntax.DataKind hiding (Symbol)
import qualified Language.Hakaru.Syntax.AST as T
import qualified Language.Hakaru.Parser.AST as U
import Language.Hakaru.Syntax.Sing
import Language.Hakaru.Syntax.IClasses
import Language.Hakaru.Syntax.HClasses
import qualified Language.Hakaru.Syntax.Nat as N

   -- Pair_
   -- True_ | False_
   -- FromProb_
   -- UnsafeProb_ 
   -- Uniform_
   -- Normal_
   -- VarSym U.Name
   -- Plus

data Symbol a where
     TLam :: (a -> Symbol a) -> Symbol a
     TNeu :: a -> Symbol a

data Symbol' a where
     TLam' :: ([a] -> a) -> Symbol' a
     TNeu' :: a -> Symbol' a

type TypeTable = [(Text, Symbol' Hakaru)]

hPair   a b = HData (TyCon (read "Pair")   :@ a :@ b) [ [ K a, K b] ]
hEither a b = HData (TyCon (read "Either") :@ a :@ b) [ [ K a], [ K b] ]
hMaybe  a   = HData (TyCon (read "Maybe")  :@ a) [ [], [ K a] ]


primTypes :: [(Text, Symbol' Hakaru)]
primTypes =  [ ("nat",  TNeu' HNat)
             , ("int",  TNeu' HInt)
             , ("prob", TNeu' HProb)
             , ("real", TNeu' HReal)
             , ("either", TLam' (\ [a,b] -> hEither a b))
             , ("pair", TLam' (\ [a,b] -> hPair a b))
             , ("maybe", TLam' (\ [a] -> hMaybe a))
             ]

makeType :: U.TypeAST' -> Hakaru
makeType (U.TypeVar t)      = case lookup t primTypes of
                                Just (TNeu' t') -> t'
                                Nothing -> error $ "Type " ++ show t ++ " is not a primitive"
makeType (U.TypeFun f x)    = (makeType f) :-> (makeType x)
makeType (U.TypeApp f args) = case lookup f primTypes of
                               Just (TLam' f') -> f' (map makeType args)
                               Nothing -> error $ "Type " ++ show f ++ " is not a primitive"

t2 :: (U.AST a -> U.AST a -> U.AST a) -> Symbol (U.AST a)
t2 f = TLam (\ a -> TLam (\b -> TNeu (f a b)))

type SymbolTable a = [(Text, Symbol (U.AST a))]

primTable :: [(Text, Symbol (U.AST a))]
primTable =  [("Pair",       primPair)
             -- ,("True",       True_)
             -- ,("False",      False_)
             -- ,("fromProb",   FromProb_)
             -- ,("unsafeProb", UnsafeProb_)
             ,("uniform",    primUniform)
             ,("normal",     primNormal)
             ]

primNormal  = t2 (\x y -> U.MeasureOp_ (U.SealedOp T.Normal) [x,y])
primUniform = t2 (\x y -> U.MeasureOp_ (U.SealedOp T.Normal) [x,y])
primPair = t2 (\a b -> U.Datum_ $
              U.Datum "pair" (U.Inl $ U.Konst a `U.Et` U.Konst b `U.Et` U.Done))

pVar name = TNeu (U.Var_ (U.Name (N.unsafeNat 0) name))

gensym :: Text -> State Int U.Name
gensym s = state $ \i -> (U.Name (N.unsafeNat i) s, i + 1)

mkSym  :: U.Name -> Symbol (U.AST a)
mkSym = TNeu . U.Var_

updateSymbols :: U.Name -> SymbolTable a -> SymbolTable a
updateSymbols n@(U.Name _ name) sym = (name, mkSym n) : sym

-- figure out symbols and types
symbolResolution :: SymbolTable a -> U.AST' Text ->
                    State Int (U.AST' (Symbol (U.AST a)))
symbolResolution symbols ast =
    case ast of
      U.Var name        -> case lookup name symbols of
                             Nothing -> do name' <- gensym name
                                           return $ U.Var (mkSym name')
                             Just a  -> return $ U.Var a

      U.Lam name x      -> do name' <- gensym name
                              x'    <- symbolResolution symbols x
                              return $ U.Lam (mkSym name') x'

      U.App f x         -> do f' <- symbolResolution symbols f
                              x' <- symbolResolution symbols x
                              return $ U.App f' x'

      U.Let name e1 e2  -> do name' <- gensym name
                              e1'   <- symbolResolution symbols e1
                              e2'   <- symbolResolution
                                       (updateSymbols name' symbols) e2
                              return $ U.Let (mkSym name') e1' e2'

      U.Ann e typ       -> do e' <- symbolResolution symbols e
                              return $ U.Ann e' typ

      U.Infinity        -> return $ U.Infinity
      U.NegInfinity     -> return $ U.NegInfinity

      U.UValue v        -> return $ U.UValue v
                          
      U.NaryOp op e1 e2 -> do e1' <- symbolResolution symbols e1
                              e2' <- symbolResolution symbols e2
                              return $ U.NaryOp op e1' e2'

      U.Bind name e1 e2 -> do name' <- gensym name
                              e1'   <- symbolResolution symbols e1
                              e2'   <- symbolResolution
                                       (updateSymbols name' symbols) e2
                              return $ U.Bind (mkSym name') e1' e2'
      
      U.Dirac e1        -> do e1' <- symbolResolution symbols e1
                              return $ U.Dirac e1'

-- make AST and give unique names for variables

-- | The logic here is to do normalization by evaluation for our
-- primitives. App inspects its first argument to see if it
-- should do something special. Otherwise App behaves as normal.
normAST :: U.AST' (Symbol (U.AST a)) -> U.AST' (Symbol (U.AST a))
normAST ast =
    case ast of
      U.App (U.Var t) x -> case t of
                            TLam f' ->
                                U.Var $ f' (makeAST x)
                            TNeu e -> (U.Var t)

      U.App f x         -> case normAST f of
                             v@(U.Var _) -> normAST (U.App v x)
                             f'          -> U.App f' x

      U.Bind name e1 e2 -> U.Bind name (normAST e1) (normAST e2)

      U.Dirac e1        -> U.Dirac e1

      v                 -> v

makeAST :: U.AST' (Symbol (U.AST a)) -> U.AST a
makeAST ast =
    case ast of
      U.Var t       -> case t of
                         TLam f' -> error "Wat?"
                         TNeu e  -> e

      U.Lam (TNeu (U.Var_ name)) e1 -> U.Lam_ name (makeAST e1)

      U.App e1 e2 -> U.App_ (makeAST e1) (makeAST e2)

      U.Let (TNeu (U.Var_ name)) e1 e2 -> U.Let_ name
                                          (makeAST e1)
                                          (makeAST e2)

      U.Ann e typ   -> U.Ann_ (makeAST e) (makeType typ)

      U.Infinity    -> U.PrimOp_ (U.SealedOp $ T.Infinity) []

      U.NegInfinity -> U.PrimOp_ (U.SealedOp $ T.NegativeInfinity) []

      U.UValue v    -> U.Value_ (U.val v) 

      U.NaryOp op e1 e2 -> U.NaryOp_ op [ makeAST e1
                                        , makeAST e2
                                        ]

      U.Bind (TNeu (U.Var_ name)) e1 e2 -> U.MBind_ name
                                           (makeAST e1)
                                           (makeAST e2)

      U.Dirac e1 -> U.Dirac_ (makeAST e1)

data PrimOp' =
     Not'        
   | Impl'       
   | Diff'       
   | Nand'  | Nor'        
   | Pi'        
   | Sin'   | Cos'   | Tan'        
   | Asin'  | Acos'  | Atan'       
   | Sinh'  | Cosh'  | Tanh'       
   | Asinh' | Acosh' | Atanh'      
   | RealPow'    
   | Exp'   | Log'        
   | Infinity'  | NegativeInfinity'
   | GammaFunc' | BetaFunc' 
   | Integrate' | Summate'  
   | Index'    
   | Size'     
   | Reduce'   
   | Equal'     | Less'     
   | NatPow'   
   | Negate'   
   | Abs'      
   | Signum'   
   | Recip'    
   | NatRoot'  
   | Erf'      

data MeasureOp' =
     Lebesgue'
   | Counting'
   | Categorical'
   | Uniform'    
   | Normal'     
   | Poisson'    
   | Gamma'      
   | Beta'       
   | DP'         
   | Plate'      
   | Chain'      

