\begin{code}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE CPP #-}

\end{code}

The file is part of the Haskell Object Observation Debugger,
(HOOD) March 2010 release.

HOOD is a small post-mortem debugger for the lazy functional
language Haskell. It is based on the concept of observation of
intermediate data structures, rather than the more traditional
stepping and variable examination paradigm used by imperative
language debuggers.

Copyright (c) Andy Gill, 1992-2000
Copyright (c) The University of Kansas 2010
Copyright (c) Maarten Faddegon, 2013-2014

All rights reserved. HOOD is distributed as free software under
the license in the file "License", which available from the HOOD
web page, http://www.haskell.org/hood

This module produces CDS's, based on the observation made on Haskell
objects, including base types, constructors and functions.

WARNING: unrestricted use of unsafePerformIO below.

This was ported for the version found on www.haskell.org/hood.


%************************************************************************
%*                                                                      *
\subsection{Exports}
%*                                                                      *
%************************************************************************

\begin{code}
module Debug.Hoed.Pure.Observe
  (
   -- * The main Hood API
  
    observeTempl
  , observe
  , observe'
  , observeCC
  , Observer(..)   -- contains a 'forall' typed observe (if supported).
  -- , Observing      -- a -> a
  , Observable(..) -- Class

   -- * For advanced users, that want to render their own datatypes.
  , (<<)           -- (Observable a) => ObserverM (a -> b) -> a -> ObserverM b
  ,(*>>=),(>>==),(>>=*)
  , thunk          -- (Observable a) => a -> ObserverM a        
  , nothunk
  , send
  , observeBase
  , observeOpaque
  , observedTypes
  , Generic
  , Trace
  , Event(..)
  , Change(..)
  , Parent(..)
  , UID
  , ParentPosition
  , ThreadId(..)
  , Identifier(..)
  , isRootEvent
  , initUniq
  , startEventStream
  , endEventStream
  , ourCatchAllIO
  , peepUniq
  ) where
\end{code}


%************************************************************************
%*                                                                      *
\subsection{Imports and infixing}
%*                                                                      *
%************************************************************************

\begin{code}
import Prelude hiding (Right)
import qualified Prelude
import System.IO
import Data.Maybe
import Control.Monad
import Data.Array as Array
import Data.List
import Data.Char
import System.Environment

import Language.Haskell.TH
import GHC.Generics

import Data.IORef
import System.IO.Unsafe

import Control.Concurrent(takeMVar,putMVar,MVar,newMVar)
import qualified Control.Concurrent as Concurrent
\end{code}

For the TracedMonad instance of IO:
\begin{code}
import GHC.Base hiding (mapM)
\end{code}

\begin{code}
import qualified Control.Exception as Exception
import Control.Exception (Exception, throw, ErrorCall(..), SomeException(..))
{-
 ( catch
                , Exception(..)
                , throw
                ) as Exception
-}
import Data.Dynamic ( Dynamic )
\end{code}

\begin{code}
infixl 9 <<
\end{code}


%************************************************************************
%*                                                                      *
\subsection{GDM Generics}
%*                                                                      *
%************************************************************************

he generic implementation of the observer function.

\begin{code}
class Observable a where
        observer  :: a -> Parent -> a 
        default observer :: (Generic a, GObservable (Rep a)) => a -> Parent -> a
        observer x c = to (gdmobserver (from x) c)

class GObservable f where
        gdmobserver :: f a -> Parent -> f a
        gdmObserveChildren :: f a -> ObserverM (f a)
        gdmShallowShow :: f a -> String
\end{code}

Creating a shallow representation for types of the Data class.

\begin{code}

-- shallowShow :: Constructor c => t c (f :: * -> *) a -> [Char]
-- shallowShow = conName

\end{code}

Observing the children of Data types of kind *.

\begin{code}

-- Meta: data types
instance (GObservable a) => GObservable (M1 D d a) where
        -- gdmobserver m@(M1 x) cxt = let x' = gdmobserver x cxt in x' `seq` M1 x'
        gdmobserver m@(M1 x) cxt = M1 (gdmobserver x cxt)
        gdmObserveChildren = gthunk
        gdmShallowShow = undefined

-- Meta: Constructors
instance (GObservable a, Constructor c) => GObservable (M1 C c a) where
        -- gdmobserver m@(M1 x) cxt = let x' = send (gdmShallowShow m) (gdmObserveChildren x) cxt in x' `seq` M1 x'
        gdmobserver m@(M1 x) cxt = M1 (send (gdmShallowShow m) (gdmObserveChildren x) cxt)
        gdmObserveChildren = gthunk
        gdmShallowShow = conName

-- Meta: Selectors
instance (GObservable a, Selector s) => GObservable (M1 S s a) where
        gdmobserver m@(M1 x) cxt
          | selName m == "" = M1 (gdmobserver x cxt)
          | otherwise       = M1 (send (selName m ++ " =") (gdmObserveChildren x) cxt)
          -- | selName m == "" = let x' = gdmobserver x cxt in x' `seq` M1 x'
          -- | otherwise       = let x' = send (selName m ++ " =") (gdmObserveChildren x) cxt in x' `seq` M1 x'
        gdmObserveChildren = gthunk
        gdmShallowShow = undefined

-- Unit: used for constructors without arguments
instance GObservable U1 where
        gdmobserver x _ = x
        gdmObserveChildren = return
        gdmShallowShow = undefined

-- Products: encode multiple arguments to constructors
instance (GObservable a, GObservable b) => GObservable (a :*: b) where
        gdmobserver (a :*: b) cxt = error "gdmobserver product"

        gdmObserveChildren (a :*: b) = do a'  <- gdmObserveChildren a
                                          b'  <- gdmObserveChildren b
                                          return (a' :*: b')
                                       
        gdmShallowShow = undefined

-- Sums: encode choice between constructors
instance (GObservable a, GObservable b) => GObservable (a :+: b) where
        -- gdmobserver (L1 x) cxt = let x' = gdmobserver x cxt in x' `seq` L1 x'
        -- gdmobserver (R1 x) cxt = let x' = gdmobserver x cxt in x' `seq` R1 x'

        gdmobserver (L1 x) cxt = L1 (gdmobserver x cxt)
        gdmobserver (R1 x) cxt = R1 (gdmobserver x cxt)

        gdmObserveChildren (R1 x) = do {x' <- gdmObserveChildren x; return (R1 x')}
        gdmObserveChildren (L1 x) = do {x' <- gdmObserveChildren x; return (L1 x')}

        gdmShallowShow = undefined

-- Constants: additional parameters and recursion of kind *
instance (Observable a) => GObservable (K1 i a) where
        gdmobserver (K1 x) cxt = K1 $ observer x cxt
        -- gdmobserver (K1 x) cxt = let x' = observer x cxt in x' `seq` K1 x'

        gdmObserveChildren = gthunk

        gdmShallowShow = undefined
\end{code}

Observing functions is done via the ad-hoc mechanism, because
we provide an instance definition the default is ignored for
this type.

\begin{code}
instance (Observable a,Observable b) => Observable (a -> b) where
  observer fn cxt arg = gdmFunObserver cxt fn arg
\end{code}

Observing the children of Data types of kind *->*.

\begin{code}
gdmFunObserver :: (Observable a,Observable b) => Parent -> (a->b) -> (a->b)
gdmFunObserver cxt fn arg
        = sendObserveFnPacket
            (do arg' <- thunk observer arg
                thunk observer (fn arg')
            ) cxt
\end{code}

%************************************************************************
%*                                                                      *
\subsection{Generics}
%*                                                                      *
%************************************************************************

Generate a new observe from generated observers and the gobserve mechanism.
Where gobserve is the 'classic' observe but parametrized.

\begin{code}
observeTempl :: String -> Q Exp
observeTempl s = do n  <- methodName s
                    let f  = return $ VarE n
                        s' = stringE s
                    [| (\x-> fst (gobserve $f DoNotTraceThreadId UnknownId $s' x)) |]
\end{code}

Generate class definition and class instances for list of types.

\begin{code}
observedTypes :: String -> [Q Type] -> Q [Dec]
observedTypes s qt = do cd <- (genClassDef s)
                        ci <- foldM f [] qt
                        bi <- foldM g [] baseTypes
                        fi <- (gfunObserver s)
                        -- li <- (gListObserver s) MF TODO: should we do away with these?
                        return (cd ++ ci ++ bi ++ fi)
        where f d t = do ds <- (gobservableInstance s t)
                         return (ds ++ d)
              g d t = do ds <- (gobservableBaseInstance s t)
                         return (ds ++ d)
              baseTypes = [[t|Int|], [t|Char|], [t|Float|], [t|Bool|]]



\end{code}

Generate a class definition from a string

\begin{code}

genClassDef :: String -> Q [Dec]
genClassDef s = do cn <- className s
                   mn <- methodName s
                   nn <-  newName "a"
                   let a   = PlainTV nn
                       tvb = [a]
                       vt  = varT nn
                   mt <- [t| $vt -> Parent -> $vt |]
                   let m   = SigD mn mt
                       cd  = ClassD [] cn tvb [] [m]
                   return [cd]

className :: String -> Q Name
className s = return $ mkName ("Observable" ++ headToUpper s)

methodName :: String -> Q Name
methodName s = return $ mkName ("observer" ++ headToUpper s)

headToUpper (c:cs) = toUpper c : cs

\end{code}

\begin{code}
gobserverBase :: Q Name -> Q Type -> Q [Dec]
gobserverBase qn t = do n <- qn
                        c <- gobserverBaseClause qn
                        return [FunD n [c]]

gobserverBaseClause :: Q Name -> Q Clause
gobserverBaseClause qn = clause [] (normalB (varE $ mkName "observeBase")) []

gobserverList :: Q Name -> Q [Dec]
gobserverList qn = do n  <- qn
                      cs <-listClauses qn
                      return [FunD n cs]


\end{code}

The generic implementation of the observer function, special cases
for base types and functions.

\begin{code}
gobserver :: Q Name -> Q Type -> Q [Dec]
gobserver qn t = do n <- qn
                    cs <- gobserverClauses qn t
                    return [FunD n cs]

gobserverClauses :: Q Name -> Q Type -> Q [Clause]
gobserverClauses n qt = do t  <- qt
                           bs <- getBindings qt
                           case t of
                                _     -> do cs <- (getConstructors . getName) qt
                                            mapM (gobserverClause t n bs) cs

gobserverClause :: Type -> Q Name -> TyVarMap -> Con -> Q Clause
gobserverClause t n bs (y@(NormalC name fields))
  = do { vars <- guniqueVariables (length fields)
       ; let evars = map varE vars
             pvars = map varP vars
             c'    = varP (mkName "c")
             c     = varE (mkName "c")
       ; clause [conP name pvars, c']
           ( normalB [| send $(shallowShow y) $(observeChildren n t bs y evars) $c |]
           ) []
       }
gobserverClause t n bs (InfixC left name right) 
  = gobserverClause t n bs (NormalC name (left:[right]))
gobserverClause t n bs y = error ("gobserverClause can't handle " ++ show y)

listClauses :: Q Name -> Q [Clause]
listClauses n = do l1 <- listClause1 n 
                   l2 <- listClause2 n 
                   return [l1, l2]

-- observer (a:as) = send ":"  (return (:) << a << as)
listClause1 :: Q Name -> Q Clause
listClause1 qn
  = do { n <- qn
       ; let a'    = varP (mkName "a")
             a     = varE (mkName "a")
             as'   = varP (mkName "as")
             as    = varE (mkName "as") 
             c'    = varP (mkName "c")
             c     = varE (mkName "c")
             t     = [| thunk $(varE n)|] -- MF TODO: or nothunk
             name  = mkName ":"
       ; clause [infixP a' name as', c']
           ( normalB [| send ":" ( compositionM $t
                                   ( compositionM $t
                                     ( return (:)
                                     ) $a
                                   ) $as
                                 ) $c
                     |]
           ) []
       }

-- observer []     = send "[]" (return [])
listClause2 :: Q Name -> Q Clause
listClause2 qn
  = do { n <- qn
       ; let c'    = varP (mkName "c")
             c     = varE (mkName "c")
       ; clause [wildP, c']
           ( normalB [| send "[]" (return []) $c |]
           ) []
       }

\end{code}

We also need to do some work to also generate the instance declaration
around the observer method.

\begin{code}
gobservableInstance :: String -> Q Type -> Q [Dec]
gobservableInstance s qt 
  = do t  <- qt
       cn <- className s
       let ct = conT cn
       n  <- case t of
            (ForallT tvs _ t') -> [t| $ct $(return t') |]
            _                  -> [t| $ct $qt          |]
       m  <- gobserver (methodName s) qt
       c  <- case t of 
                (ForallT _ c' _)   -> return c'
                _                  -> return []
       return [InstanceD (updateContext cn c) n m]

#if __GLASGOW_HASKELL__ >= 710
updateContext :: Name -> [Pred] -> [Pred]
updateContext cn ps = map f ps
        where f (AppT (ConT n) ts) -- TH<2.10: f (ClassP n ts)
                  | nameBase n == "Observable" = (AppT (ConT cn) ts) -- ClassP cn ts
                  | otherwise                  = (AppT (ConT n)  ts) -- ClassP n  ts
              f p = p
#else
updateContext :: Name -> [Pred] -> [Pred]
updateContext cn ps = map f ps
        where f (ClassP n ts)
                | nameBase n == "Observable" = ClassP cn ts
                | otherwise                  = ClassP n  ts
              f p = p
#endif

gobservableBaseInstance :: String -> Q Type -> Q [Dec]
gobservableBaseInstance s qt
  = do t  <- qt
       cn <- className s
       let ct = conT cn
       n  <- case t of
            (ForallT tvs _ t') -> [t| $ct $(return t') |]
            _                  -> [t| $ct $qt          |]
       m  <- gobserverBase (methodName s) qt
       c  <- case t of 
                (ForallT _ c' _)   -> return c'
                _                  -> return []
       return [InstanceD c n m]

gobservableListInstance :: String -> Q [Dec]
gobservableListInstance s
  = do let qt = [t|forall a . [] a |]
       t  <- qt
       cn <- className s
       let ct = conT cn
       n  <- case t of
            (ForallT tvs _ t') -> [t| $ct $(return t') |]
            _                  -> [t| $ct $qt          |]
       m  <- gobserverList (methodName s)
       c  <- case t of 
                (ForallT _ c' _)   -> return c'
                _                  -> return []
       return [InstanceD c n m]

-- MF TODO: what do we do with this?
-- gListObserver :: String -> Q [Dec]
-- gListObserver s
--   = do cn <- className s
--        let ct = conT cn
--            a  = VarT (mkName "a")
--            a' = return a
--        c <- return [ClassP cn a']
--        n <- [t| $ct [$a'] |]
--        m <- gobserverList (methodName s)
--        return [InstanceD c n m]


gobserverFunClause :: Name -> Q Clause
gobserverFunClause n
  = do { [f',a'] <- guniqueVariables 2
       ; let vs        = [f', mkName "c", a']
             [f, c, a] = map varE vs
             pvars     = map varP vs
       ; clause pvars 
         (normalB [| sendObserveFnPacket
                       ( do a' <- thunk $(varE n) $a
                            thunk $(varE n) ($f a')
                       ) $c
                  |]
         ) []
       }

gobserverFun :: Q Name -> Q [Dec]
gobserverFun qn
  = do n  <- qn
       c  <- gobserverFunClause n
       cs <- return [c]
       return [FunD n cs]

gfunObserver :: String -> Q [Dec]
gfunObserver s
  = do cn <- className s
       let ct = conT cn
           a  = VarT (mkName "a")
           b  = VarT (mkName "b")
           f  = return $ AppT (AppT ArrowT a) b
#if __GLASGOW_HASKELL__ >= 710
       p <- return $ AppT (ConT cn) a
       q <- return $ AppT (ConT cn) b
#else
       let a' = return a
           b' = return b
       p <- return $ ClassP cn a'
       q <- return $ ClassP cn b'
#endif
       c <- return [p,q]
       n <- [t| $ct $f |]
       m <- gobserverFun (methodName s)
       return [InstanceD c n m]

\end{code}

Creating a shallow representation for types of the Data class.

\begin{code}
shallowShow :: Con -> ExpQ
shallowShow (NormalC name _)
  = stringE (case (nameBase name) of "(,)" -> ","; s -> s)
\end{code}

Observing the children of Data types of kind *.

Note how we are forced to add the extra 'vars' argument that should
have the same unique name as the corresponding pattern.

To implement observeChildren we also define a mapM and compositionM function.
To our knowledge there is no existing work that do this in a generic fashion
with Template Haskell.

\begin{code}

isObservable :: TyVarMap -> Type -> Type -> Q Bool
-- MF TODO: if s == t then return True else isObservable' bs t
isObservable bs s t = isObservable' bs t

-- MF TODO this is a hack
isObservable' bs (AppT ListT _)    = return True

isObservable' bs (VarT n)      = case lookupBinding bs n of
                                      (Just (T t)) -> isObservableT t
                                      (Just (P p)) -> isObservableP p
                                      Nothing      -> return False
-- isObservable' bs (AppT t _)    = isObservable' bs t
isObservable' (n,_) t@(ConT m) = if n == m then return True else isObservableT t
isObservable' bs t             = isObservableT t

isObservableT :: Type -> Q Bool
isObservableT t@(ConT _) = isInstance (mkName "Observable") [t]
isObservableT _          = return False 

isObservableP :: Pred -> Q Bool
#if __GLASGOW_HASKELL__ >= 710
isObservableP (AppT (ConT n) _) = return $ (nameBase n) == "Observable"
#else
isObservableP (ClassP n _) = return $ (nameBase n) == "Observable"
#endif
isObservableP _            = return False


thunkObservable :: Q Name -> TyVarMap -> Type -> Type -> Q Exp
thunkObservable qn bs s t
  = do i <- isObservable bs s t
       n <- qn
       if i then [| thunk $(varE n) |] else [| nothunk |]

observeChildren :: Q Name -> Type -> TyVarMap -> Con -> [Q Exp] -> Q Exp
observeChildren n t bs = gmapM (thunkObservable n bs t)

gmapM :: (Type -> Q Exp) -> Con -> [ExpQ] -> ExpQ
gmapM f (NormalC name fields) vars
  = m name (reverse fields) (reverse vars) 
  where m :: Name -> [(Strict,Type)] -> [ExpQ] -> ExpQ
        m n _      []           = [| return $(conE n)                      |]
        m n ((_,t):ts) (v:vars) = [| compositionM $(f t) $(m n ts vars) $v |]


compositionM :: Monad m => (a -> m b) -> m (b -> c) -> a -> m c
compositionM f g x = do { g' <- g 
                        ; x' <- f x 
                        ; return (g' x') 
                        }
\end{code}

And we need some helper functions:

\begin{code}

-- A mapping from typevars to the type they are bound to.

type TyVarMap = (Name, [(TyVarBndr,TypeOrPred)])

data TypeOrPred = T Type | P Pred


-- MF TODO lookupBinding

lookupBinding :: TyVarMap -> Name -> Maybe TypeOrPred
lookupBinding (_,[]) _ = Nothing
lookupBinding (r,((b,t):ts)) n
  = let m = case b of (PlainTV  m  ) -> m
                      (KindedTV m _) ->m
    in if (m == n) then Just t else lookupBinding (r,ts) n

-- Given a parametrized type, get a list with typevars and their bindings
-- e.g. [(a,Int), (b,Float)] in (MyData a b) Int Float

getBindings :: Q Type -> Q TyVarMap
getBindings t = do bs  <- getBs t
                   tvs <- (getTvbs . getName) t
                   pbs <- getPBindings t
                   n   <- getName t
                   let fromApps = (zip tvs (map T bs))
                       fromCxt  = (zip tvs (map P pbs)) 
                   return (n, (fromCxt ++ fromApps))

getPBindings :: Q Type -> Q [Pred]
getPBindings qt = do t <- qt 
                     case t of (ForallT _ cs _) -> getPBindings' cs
                               _                -> return []

getPBindings' :: [Pred] -> Q [Pred]
getPBindings' []     = return []
getPBindings' (p:ps) = do pbs <- getPBindings' ps
#if __GLASGOW_HASKELL__ >= 710
                          return $ case p of (AppT (ConT n) t) -> p : pbs
                                             _                 -> pbs
#else
                          return $ case p of (ClassP n t) -> p : pbs
                                             _            -> pbs
#endif

-- Given a parametrized type, get a list with its type variables
-- e.g. [a,b] in (MyData a b) Int Float

getTvbs :: Q Name -> Q [TyVarBndr]
getTvbs name = do n <- name
                  i <- reify n
                  case i of
                    TyConI (DataD _ _ tvbs _ _) 
                      -> return tvbs
                    i
                      -> error ("getTvbs: can't reify " ++ show i)

-- Given a parametrized type, get a list with the bindings of type variables
-- e.g. [Int,Float] in (MyData a b) Int Float

getBs :: Q Type -> Q [Type]
getBs t = do t' <- t
             let t'' = case t' of (ForallT _ _ s) -> s
                                  _               -> t'
             return (getBs' t'')

getBs' :: Type -> [Type]
getBs' (AppT c t) = t : getBs' c
getBs' _          = []

-- Given a parametrized type, get the name of the type constructor (e.g. Tree in Tree Int)

getName :: Q Type -> Q Name
getName t = do t' <- t
               getName' t'

getName' :: Type -> Q Name
getName' t = case t of 
                (ForallT _ _ t'') -> getName' t''
                (AppT t'' _)      -> getName' t''
                (ConT name)       -> return name
                ListT             -> return $ mkName "[]"
                TupleT _          -> return $ mkName "(,)"
                t''               -> error ("getName can't handle " ++ show t'')

-- Given a type, get a list of type variables.

getTvs :: Q Type -> Q [TyVarBndr]
getTvs t = do {(ForallT tvs _ _) <- t; return tvs }

-- Given a type, get a list of constructors.

getConstructors :: Q Name -> Q [Con]
getConstructors name = do {n <- name; TyConI (DataD _ _ _ cs _)  <- reify n; return cs}

guniqueVariables :: Int -> Q [Name]
guniqueVariables n = replicateM n (newName "x")

observableCxt :: [TyVarBndr] -> Q Cxt
observableCxt tvs = return [classpObservable $ map (\v -> (tvname v)) tvs]

#if __GLASGOW_HASKELL__ >= 710
classpObservable :: [Type] -> Type
classpObservable = foldl AppT (ConT (mkName "Observable"))
#else
classpObservable :: [Type] -> Pred
classpObservable = ClassP (mkName "Observable")
#endif

qcontObservable :: Q Type
qcontObservable = return contObservable

contObservable :: Type
contObservable = ConT (mkName "Observable")

qtvname :: TyVarBndr -> Q Type
qtvname = return . tvname

tvname :: TyVarBndr -> Type
tvname (PlainTV  name  ) = VarT name
tvname (KindedTV name _) = VarT name

\end{code}

%************************************************************************
%*                                                                      *
\subsection{Instances}
%*                                                                      *
%************************************************************************

 The Haskell Base types

\begin{code}
instance Observable Int         where { observer = observeBase }
instance Observable Bool        where { observer = observeBase }
instance Observable Integer     where { observer = observeBase }
instance Observable Float       where { observer = observeBase }
instance Observable Double      where { observer = observeBase }
instance Observable Char        where { observer = observeBase }

instance Observable ()          where { observer = observeOpaque "()" }

-- utilities for base types.
-- The strictness (by using seq) is the same 
-- as the pattern matching done on other constructors.
-- we evalute to WHNF, and not further.

observeBase :: (Show a) => a -> Parent -> a
observeBase lit cxt = seq lit $ send (show lit) (return lit) cxt

observeOpaque :: String -> a -> Parent -> a
observeOpaque str val cxt = seq val $ send str (return val) cxt
\end{code}

The Constructors.

\begin{code}
instance (Observable a,Observable b) => Observable (a,b) where
  observer (a,b) = send "," (return (,) << a << b)

instance (Observable a,Observable b,Observable c) => Observable (a,b,c) where
  observer (a,b,c) = send "," (return (,,) << a << b << c)

instance (Observable a,Observable b,Observable c,Observable d) 
          => Observable (a,b,c,d) where
  observer (a,b,c,d) = send "," (return (,,,) << a << b << c << d)

instance (Observable a,Observable b,Observable c,Observable d,Observable e) 
         => Observable (a,b,c,d,e) where
  observer (a,b,c,d,e) = send "," (return (,,,,) << a << b << c << d << e)

instance (Observable a) => Observable [a] where
  observer (a:as) = send ":"  (return (:) << a << as)
  observer []     = send "[]" (return [])

instance (Observable a) => Observable (Maybe a) where
  observer (Just a) = send "Just"    (return Just << a)
  observer Nothing  = send "Nothing" (return Nothing)

instance (Observable a,Observable b) => Observable (Either a b) where
  observer (Left a)  = send "Left"  (return Left  << a)
  observer (Prelude.Right a) = send "Right" (return Prelude.Right << a)
\end{code}

Arrays.

\begin{code}
instance (Ix a,Observable a,Observable b) => Observable (Array.Array a b) where
  observer arr = send "array" (return Array.array << Array.bounds arr 
                                                  << Array.assocs arr
                              )
\end{code}

IO monad.

\begin{code}
instance (Observable a) => Observable (IO a) where
  observer fn cxt = 
        do res <- fn
           send "<IO>" (return return << res) cxt
\end{code}



The Exception *datatype* (not exceptions themselves!).

\begin{code}
instance Observable SomeException where
  observer e = send ("<Exception> " ++ show e) (return e)

-- instance Observable ErrorCall where
--   observer (ErrorCall a)        = send "ErrorCall"   (return ErrorCall << a)


instance Observable Dynamic where { observer = observeOpaque "<Dynamic>" }
\end{code}


%************************************************************************
%*                                                                      *
\subsection{Classes and Data Definitions}
%*                                                                      *
%************************************************************************

MF: why/when do we need these types?
\begin{code}
type Observing a = a -> a

newtype Observer = O (forall a . (Observable a) => String -> a -> a)
\end{code}


%************************************************************************
%*                                                                      *
\subsection{The ObserveM Monad}
%*                                                                      *
%************************************************************************

The Observer monad, a simple state monad, 
for placing numbers on sub-observations.

\begin{code}
newtype ObserverM a = ObserverM { runMO :: Int -> Int -> (a,Int) }

instance Functor ObserverM where
    fmap  = liftM

#if __GLASGOW_HASKELL__ >= 710
instance Applicative ObserverM where
    pure  = return
    (<*>) = ap
#endif

instance Monad ObserverM where
        return a = ObserverM (\ c i -> (a,i))
        fn >>= k = ObserverM (\ c i ->
                case runMO fn c i of
                  (r,i2) -> runMO (k r) c i2
                )

thunk :: (a -> Parent -> a) -> a -> ObserverM a
thunk f a = ObserverM $ \ parent port ->
                ( observer_ f a (Parent
                                { parentUID = parent
                                , parentPosition   = port
                                }) 
                , port+1 )

gthunk :: (GObservable f) => f a -> ObserverM (f a)
gthunk a = ObserverM $ \ parent port ->
                ( gdmobserver_ a (Parent
                                { parentUID = parent
                                , parentPosition   = port
                                }) 
                , port+1 )

nothunk :: a -> ObserverM a
nothunk a = ObserverM $ \ parent port ->
                ( observer__ a (Parent
                                { parentUID = parent
                                , parentPosition   = port
                                }) 
                , port+1 )


(<<) :: (Observable a) => ObserverM (a -> b) -> a -> ObserverM b
-- fn << a = do { fn' <- fn ; a' <- thunk a ; return (fn' a') }
fn << a = gdMapM (thunk observer) fn a

gdMapM :: (Monad m)
        => (a -> m a)  -- f
        -> m (a -> b)  -- data constructor
        -> a           -- argument
        -> m b         -- data
gdMapM f c a = do { c' <- c ; a' <- f a ; return (c' a') }

\end{code}


%************************************************************************
%*                                                                      *
\subsection{observe and friends}
%*                                                                      *
%************************************************************************

Our principle function and class

\begin{code}
-- | 'observe' observes data structures in flight.
--  
-- An example of use is 
--  @
--    map (+1) . observe \"intermeduate\" . map (+2)
--  @
--
-- In this example, we observe the value that flows from the producer
-- @map (+2)@ to the consumer @map (+1)@.
-- 
-- 'observe' can also observe functions as well a structural values.
-- 
{-# NOINLINE gobserve #-}
gobserve :: (a->Parent->a) -> TraceThreadId -> Identifier -> String -> a -> (a,Int)
gobserve f tti d name a = generateContext f tti d name a

{- | 
Functions which you suspect of misbehaving are annotated with observe and
should have a cost centre set. The name of the function, the label of the cost
centre and the label given to observe need to be the same.

Consider the following function:

@triple x = x + x@

This function is annotated as follows:

> triple y = (observe "triple" (\x -> {# SCC "triple" #}  x + x)) y

To produce computation statements like:

@triple 3 = 6@

To observe a value its type needs to be of class Observable.
We provided instances for many types already.
If you have defined your own type, and want to observe a function
that takes a value of this type as argument or returns a value of this type,
an Observable instance can be derived as follows:

@  
  data MyType = MyNumber Int | MyName String deriving Generic

  instance Observable MyType
@
-}
{-# NOINLINE observe #-}
observe ::  (Observable a) => String -> a -> a
observe lbl = fst . (gobserve observer DoNotTraceThreadId UnknownId lbl)

{-# NOINLINE observeCC #-}
observeCC ::  (Observable a) => String -> a -> a
observeCC lbl = fst . (gobserve observer TraceThreadId UnknownId lbl)

data Identifier = UnknownId | DependsJustOn Int | InSequenceAfter Int
     deriving (Show, Eq, Ord)

{-# NOINLINE observe' #-}
observe' :: (Observable a) => String -> Identifier -> a -> (a,Int)
observe' lbl d x = let (y,i) = (gobserve observer DoNotTraceThreadId d lbl) x
                      in  (y, i)

{- This gets called before observer, allowing us to mark
 - we are entering a, before we do case analysis on
 - our object.
 -}

{-# NOINLINE observer_ #-}
observer_ :: (a -> Parent -> a) -> a -> Parent -> a 
observer_ f a context = sendEnterPacket f a context

gdmobserver_ :: (GObservable f) => f a -> Parent -> f a
gdmobserver_ a context = gsendEnterPacket a context

{-# NOINLINE observer__ #-}
observer__ :: a -> Parent -> a
observer__ a context = sendNoEnterPacket a context

\end{code}

The functions that output the data. All are dirty.

\begin{code}
unsafeWithUniq :: (Int -> IO a) -> a
unsafeWithUniq fn 
  = unsafePerformIO $ do { node <- getUniq
                         ; fn node
                         }
\end{code}

\begin{code}
data TraceThreadId = TraceThreadId | DoNotTraceThreadId

generateContext :: (a->Parent->a) -> TraceThreadId -> Identifier -> String -> a -> (a,Int)
generateContext f tti d label orig = unsafeWithUniq $ \ node ->
     do { t <- myThreadId
        ; sendEvent node (Parent 0 0) (Observe label t node d)
        ; return (observer_ f orig (Parent
                        { parentUID      = node
                        , parentPosition = 0
                        })
                 , node)
        }
  where myThreadId = case tti of
          DoNotTraceThreadId -> return ThreadIdUnknown
          TraceThreadId      -> do t <- Concurrent.myThreadId
                                   return (ThreadId t)

send :: String -> ObserverM a -> Parent -> a
send consLabel fn context = unsafeWithUniq $ \ node ->
     do { let (r,portCount) = runMO fn node 0
        ; sendEvent node context (Cons portCount consLabel)
        ; return r
        }


sendEnterPacket :: (a -> Parent -> a) -> a -> Parent -> a
sendEnterPacket f r context = unsafeWithUniq $ \ node ->
     do { sendEvent node context Enter
        ; ourCatchAllIO (evaluate (f r context))
                        (handleExc context)
        }

gsendEnterPacket :: (GObservable f) => f a -> Parent -> f a
gsendEnterPacket r context = unsafeWithUniq $ \ node ->
     do { sendEvent node context Enter
        ; ourCatchAllIO (evaluate (gdmobserver r context))
                        (handleExc context)
        }

sendNoEnterPacket :: a -> Parent -> a
sendNoEnterPacket r context = unsafeWithUniq $ \ node ->
     do { sendEvent node context NoEnter
        ; ourCatchAllIO (evaluate r)
                        (handleExc context)
        }

evaluate :: a -> IO a
evaluate a = a `seq` return a

sendObserveFnPacket :: ObserverM a -> Parent -> a
sendObserveFnPacket fn context
  = unsafeWithUniq $ \ node ->
     do { let (r,_) = runMO fn node 0
        ; sendEvent node context Fun
        ; return r
        }
\end{code}


%************************************************************************
%*                                                                      *
\subsection{Event stream}
%*                                                                      *
%************************************************************************

Trival output functions

\begin{code}
type Trace = [Event]

data Event = Event
                { eventUID     :: !UID      -- my UID
                , eventParent  :: !Parent
                , change       :: !Change
                }
        deriving (Eq)

data Change
        = Observe       !String         !ThreadId        !Int      !Identifier
        | Cons    !Int  !String
        | Enter
        | NoEnter
        | Fun
        deriving (Eq, Show)

type ParentPosition = Int

data Parent = Parent
        { parentUID      :: !UID            -- my parents UID
        , parentPosition :: !ParentPosition -- my branch number (e.g. the field of a data constructor)
        } deriving (Eq)

instance Show Event where
  show e = (show . eventUID $ e) ++ ": " ++ (show . change $ e) ++ " (" ++ (show . eventParent $ e) ++ ")"

instance Show Parent where
  show p = "P " ++ (show . parentUID $ p) ++ " " ++ (show . parentPosition $ p)

root = Parent 0 0

data ThreadId = ThreadIdUnknown | ThreadId Concurrent.ThreadId
        deriving (Show,Eq,Ord)


isRootEvent :: Event -> Bool
isRootEvent e = case change e of Observe{} -> True; _ -> False

startEventStream :: IO ()
startEventStream = writeIORef events []

endEventStream :: IO Trace
endEventStream =
        do { es <- readIORef events
           ; writeIORef events badEvents 
           ; return es
           }

sendEvent :: Int -> Parent -> Change -> IO ()
sendEvent nodeId parent change =
        do { nodeId `seq` parent `seq` return ()
           ; change `seq` return ()
           ; takeMVar sendSem
           ; es <- readIORef events
           ; let event = Event nodeId parent change
           ; writeIORef events (event `seq` (event : es))
           ; putMVar sendSem ()
           }

-- local
events :: IORef Trace
events = unsafePerformIO $ newIORef badEvents

badEvents :: Trace
badEvents = error "Bad Event Stream"

-- use as a trivial semiphore
{-# NOINLINE sendSem #-}
sendSem :: MVar ()
sendSem = unsafePerformIO $ newMVar ()
-- end local
\end{code}


%************************************************************************
%*                                                                      *
\subsection{unique name supply code}
%*                                                                      *
%************************************************************************

Use the single threaded version

\begin{code}
type UID = Int

initUniq :: IO ()
initUniq = writeIORef uniq 1

getUniq :: IO UID
getUniq
    = do { takeMVar uniqSem
         ; n <- readIORef uniq
         ; writeIORef uniq $! (n + 1)
         ; putMVar uniqSem ()
         ; return n
         }

peepUniq :: IO UID
peepUniq = readIORef uniq

-- locals
{-# NOINLINE uniq #-}
uniq :: IORef UID
uniq = unsafePerformIO $ newIORef 1

{-# NOINLINE uniqSem #-}
uniqSem :: MVar ()
uniqSem = unsafePerformIO $ newMVar ()
\end{code}



%************************************************************************
%*                                                                      *
\subsection{Global, initualizers, etc}
%*                                                                      *
%************************************************************************

-- \begin{code}
-- openObserveGlobal :: IO ()
-- openObserveGlobal =
--      do { initUniq
--      ; startEventStream
--      }
-- 
-- closeObserveGlobal :: IO Trace
-- closeObserveGlobal =
--      do { evs <- endEventStream
--         ; putStrLn ""
--      ; return evs
--      }
-- \end{code}

%************************************************************************
%*                                                                      *
\subsection{Simulations}
%*                                                                      *
%************************************************************************

Here we provide stubs for the functionally that is not supported
by some compilers, and provide some combinators of various flavors.

\begin{code}
ourCatchAllIO :: IO a -> (SomeException -> IO a) -> IO a
ourCatchAllIO = Exception.catch

handleExc :: Parent -> SomeException -> IO a
handleExc context exc = return (send "throw" (return throw << exc) context)
\end{code}

%************************************************************************

\begin{code}
(*>>=) :: Monad m => m a -> (Identifier -> (a -> m b, Int)) -> (m b, Identifier)
x *>>= f = let (g,i) = f UnknownId in (x >>= g,InSequenceAfter i)

(>>==) :: Monad m => (m a, Identifier) -> (Identifier -> (a -> m b, Int)) -> (m b, Identifier)
(x,d) >>== f = let (g,i) = f d in (x >>= g,InSequenceAfter i)

(>>=*) :: Monad m => (m a, Identifier) -> (Identifier -> (a -> m b, Int)) -> m b
(x,d) >>=* f = let (g,i) = f d in x >>= g
\end{code}