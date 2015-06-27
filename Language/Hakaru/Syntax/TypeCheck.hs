{-# LANGUAGE ScopedTypeVariables
           , GADTs
           , DataKinds
           , PolyKinds
           , GeneralizedNewtypeDeriving
           #-}

{-# OPTIONS_GHC -Wall -fwarn-tabs #-}
----------------------------------------------------------------
--                                                    2015.06.26
-- |
-- Module      :  Language.Hakaru.Syntax.TypeCheck
-- Copyright   :  Copyright (c) 2015 the Hakaru team
-- License     :  BSD3
-- Maintainer  :  wren@community.haskell.org
-- Stability   :  experimental
-- Portability :  GHC-only
--
-- Bidirectional type checking for our AST. N.B., since we use a
-- GADT, most of the usual type inference\/checking is trivial; the
-- only thing we actually need to do is ensure well-formedness of
-- the 'ABT' structure and the well-typedness of binders\/variables.
--
-- TODO: we should be able to get rid of the ABT well-formedness
-- checking by having our 'View' type be indexed by the number of
-- bindings it introduces.
----------------------------------------------------------------
module Language.Hakaru.Syntax.TypeCheck where

import           Data.IntMap       (IntMap)
import qualified Data.IntMap       as IM
import           Control.Monad     (forM_)

-- import Language.Hakaru.Syntax.DataKind
import Language.Hakaru.Syntax.TypeEq (Sing(..), TypeEq(Refl), jmEq)
import Language.Hakaru.Syntax.AST
import Language.Hakaru.Syntax.ABT

----------------------------------------------------------------
----------------------------------------------------------------


-- | Those terms from which we can synthesize a unique type. We are
-- also allowed to check them, via the change-of-direction rule.
inferable :: View abt a -> Bool
inferable = not . mustCheck


-- | Those terms whose types must be checked analytically. We cannot
-- synthesize (unambiguous) types for these terms.
mustCheck :: View abt a -> Bool
-- Actually, since we have the Proxy, we should be able to synthesize here...
mustCheck (Syn (Lam_ _ _))           = True
-- TODO: all data constructors should return True (but why don't they synthesize? <http://jozefg.bitbucket.org/posts/2014-11-22-bidir.html>); thus, data constructors shouldn't be considered as primops... or at least, we need better pattern matching to grab them...
mustCheck (Syn (App_ _ _))            = False -- In general, but not when a data-constructor primop is fully saturated! (or partially applied?)
mustCheck (Syn (Let_ e1 e2))          = error "TODO: mustCheck(Let_)"
mustCheck (Syn (Fix_ e))              = error "TODO: mustCheck(Fix_)"
mustCheck (Syn (Ann_ _ _))            = False
mustCheck (Syn (PrimOp_ o))           =
    case o of
    Unit -> True
    _    -> error "TODO: mustCheck(PrimOp_)"
    -- TODO: presumably, all primops should be checkable & synthesizable
mustCheck (Syn (NaryOp_ o es))        = error "TODO: mustCheck(NaryOp_)"
mustCheck (Syn (Integrate_ e1 e2 e3)) = error "TODO: mustCheck(Integrate_)"
mustCheck (Syn (Summate_   e1 e2 e3)) = error "TODO: mustCheck(Summate_)"
mustCheck (Syn (Value_ v))            = error "TODO: mustCheck(Value_)"
mustCheck (Syn (CoerceTo_   c e))     = error "TODO: mustCheck(CoerceTo_)"
mustCheck (Syn (UnsafeFrom_ c e))     = error "TODO: mustCheck(UnsafeFrom_)"
mustCheck (Syn (List_   es))          = error "TODO: mustCheck(List_)"
mustCheck (Syn (Maybe_  me))          = error "TODO: mustCheck(Maybe_)"
mustCheck (Syn (Case_   _ _))         = True
mustCheck (Syn (Array_  _ _))         = True
mustCheck (Syn (Roll_   _))           = True
mustCheck (Syn (Unroll_ _))           = False
mustCheck (Syn (Bind_   e1 e2))       = error "TODO: mustCheck(Bind_)"
mustCheck (Syn (Superpose_ pes))      = error "TODO: mustCheck(Superpose_)"
mustCheck (Syn (Dp_     e1 e2))       = error "TODO: mustCheck(Dp_)"
mustCheck (Syn (Plate_  e))           = error "TODO: mustCheck(Plate_)"
mustCheck (Syn (Chain_  e))           = error "TODO: mustCheck(Chain_)"
mustCheck (Syn (Lub_    e1 e2))       = error "TODO: mustCheck(Lub_)"
mustCheck (Syn Bot_)                  = error "TODO: mustCheck(Bot_)"
mustCheck _                           = False -- Var is false; Open is (presumably) an error...

----------------------------------------------------------------

type TypeCheckError = String -- TODO: something better

newtype TypeCheckMonad a = TCM { unTCM :: Either TypeCheckError a }
    deriving (Functor, Applicative, Monad)
-- TODO: ensure that the monad instance has the appropriate strictness

failwith :: TypeCheckError -> TypeCheckMonad a
failwith = TCM . Left

data TypedVariable where
    TV :: {-# UNPACK #-} !Variable -> !(Sing a) -> TypedVariable

data TypedPattern where
    TP :: !(Pattern a) -> !(Sing a) -> TypedPattern

-- TODO: replace with an IntMap(TypedVariable), using the varId of the Variable
type Ctx = IntMap TypedVariable

pushCtx :: TypedVariable -> Ctx -> Ctx
pushCtx tv@(TV x _) = IM.insert (varId x) tv


-- | Given a typing environment and a term, synthesize the term's type.
inferType :: ABT abt => Ctx -> abt a -> TypeCheckMonad (Sing a)
inferType ctx e =
    case viewABT e of
    Var x typ ->
        case IM.lookup (varId x) ctx of
        Just (TV x' typ')
            | x' == x   ->
                case jmEq typ typ' of
                Just Refl -> return typ'
                Nothing   -> failwith "type mismatch"
            | otherwise -> error "inferType: bad context"
        Nothing  -> failwith "unbound variable"

    Syn (Ann_ typ e') -> do
        -- N.B., this requires that @typ@ is a 'Sing' not a 'Proxy',
        -- since we can't generate a 'Sing' from a 'Proxy'.
        checkType ctx e' typ
        return typ

    Syn (App_ e1 e2) -> do
        typ1 <- inferType ctx e1
        case typ1 of
            SFun typ2 typ3 -> checkType ctx e2 typ2 >> return typ3
            -- IMPOSSIBLE: _ -> failwith "Applying a non-function!"
    {-
    Syn (Unroll_ e') -> do
        typ <- inferType ctx e'
        case typ of
        SMu typ1 -> return (SApp typ1 typ)
        _        -> failwith "expected HMu type"
    -}

    t   | inferable t -> error "inferType: missing an inferable branch!"
        | otherwise   -> failwith "Cannot infer types for checking terms; please add a type annotation"


-- TODO: rather than returning (), we could return a fully type-annotated term...
-- | Given a typing environment, a term, and a type, check that the
-- term satisfies the type.
checkType :: ABT abt => Ctx -> abt a -> Sing a -> TypeCheckMonad ()
checkType ctx e typ =
    case viewABT e of
    Syn (Lam_ p e') ->
        case typ of
        SFun typ1 typ2 ->
            -- TODO: catch ExpectedOpenException and convert it to a TypeCheckError
            caseOpenABT e' $ \x t ->
            checkType (pushCtx (TV x typ1) ctx) t typ2
        _ -> failwith "expected HFun type"

    Syn (PrimOp_ Unit) ->
        case typ of
        SUnit -> return ()
        _     -> failwith "expected HUnit type"
    {-
    Syn (App_ (Syn (App_ (Syn (PrimOp_ Pair)) e1)) e2) ->
        case typ of
        SPair typ1 typ2 -> checkType ctx e1 typ1 >> checkType ctx e2 typ2
        _               -> failwith "expected HPair type"

    Syn (App_ (Syn (PrimOp_ Inl)) e) ->
        case typ of
        SEither typ1 _ -> checkType ctx e typ1
        _              -> failwith "expected HEither type"

    Syn (App_ (Syn (PrimOp_ Inr)) e) ->
        case typ of
        SEither _ typ2 -> checkType ctx e typ2
        _              -> failwith "expected HEither type"
    -}
    Syn (Case_ e' branches) -> do
        typ' <- inferType ctx e'
        forM_ branches $ \(Branch pat body) ->
            checkBranch ctx [TP pat typ'] body typ

    Syn (Array_ n e') ->
        case typ of
        SArray typ1 ->
            -- TODO: catch ExpectedOpenException and convert it to a TypeCheckError
            caseOpenABT e' $ \x t ->
            checkType (pushCtx (TV x SNat) ctx) t typ1
        _ -> failwith "expected HArray type"

    {-
    Syn (Roll_ e') ->
        case typ of
        SMu typ1 -> checkType ctx e' (SApp typ1 typ)
        _        -> failwith "expected HMu type"
    -}

    t   | mustCheck t -> error "checkType: missing an mustCheck branch!"
        | otherwise   -> do
            typ' <- inferType ctx e
            if typ == typ' -- TODO: would using 'jmEq' be better?
            then return ()
            else failwith "Type mismatch"


checkBranch
    :: ABT abt
    => Ctx
    -> [TypedPattern]
    -> abt b
    -> Sing b
    -> TypeCheckMonad ()
checkBranch ctx []                 e body_typ = checkType ctx e body_typ
checkBranch ctx (TP pat typ : pts) e body_typ =
    case pat of
    PVar ->
        -- TODO: catch ExpectedOpenException and convert it to a TypeCheckError
        caseOpenABT e $ \x e' ->
        checkBranch (pushCtx (TV x typ) ctx) pts e' body_typ
    PWild ->
        checkBranch ctx pts e body_typ
    PTrue ->
        case typ of
        SBool -> checkBranch ctx pts e body_typ
        _     -> failwith "expected term of HBool type"
    PFalse ->
        case typ of
        SBool -> checkBranch ctx pts e body_typ
        _     -> failwith "expected term of HBool type"
    PUnit ->
        case typ of
        SUnit -> checkBranch ctx pts e body_typ
        _     -> failwith "expected term of HUnit type"
    PPair pat1 pat2 ->
        case typ of
        SPair typ1 typ2 ->
            checkBranch ctx (TP pat1 typ1 : TP pat2 typ2 : pts) e body_typ
        _ -> failwith "expected term of HPair type"
    PInl pat1 ->
        case typ of
        SEither typ1 _ ->
            checkBranch ctx (TP pat1 typ1 : pts) e body_typ
        _ -> failwith "expected HEither type"
    PInr pat2 ->
        case typ of
        SEither _ typ2 ->
            checkBranch ctx (TP pat2 typ2 : pts) e body_typ
        _ -> failwith "expected HEither type"

----------------------------------------------------------------
----------------------------------------------------------- fin.