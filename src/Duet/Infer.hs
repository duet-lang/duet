{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | A clear-to-read, well-documented, implementation of a Haskell 98
-- type checker adapted from Typing Haskell In Haskell, by Mark
-- P. Jones.

module Duet.Infer
  (
  -- * Type checker
  -- $type-checker
    typeCheckModule
  , InferException(..)
  -- * Setting up
  , addClass
  , addInstance
  , SpecialTypes(..)
  , ClassEnvironment(..)
  , ReadException(..)
  -- * Printers
  -- , printTypeSignature
  -- * Types syntax tree
  , Type(..)
  , Kind(..)
  , Scheme(..)
  , TypeSignature(..)
  , TypeVariable(..)
  , Qualified(..)
  , Class(..)
  , Predicate(..)
  , TypeConstructor(..)
  -- * Values syntax tree
  , ImplicitlyTypedBinding(..)
  , ExplicitlyTypedBinding(..)
  , Expression(..)
  , Literal(..)
  , Pattern(..)
  , BindGroup(..)
  , Alternative(..)
  ) where

import           Control.Monad.Catch
import           Control.Monad.State
import           Data.List
import qualified Data.Map.Strict as M
import           Data.Maybe
import           Duet.Types

--------------------------------------------------------------------------------
-- Type inference
--

-- $type-checker
--
-- The type checker takes a module and produces a list of type
-- signatures. It checks that all types unify, and infers the types of
-- unannotated expressions. It resolves type-class instances.

-- | Type check the given module and produce a list of type
-- signatures.
--
-- >>> fmap (map printTypeSignature) (typeCheckModule mempty [] [BindGroup [] [[ImplicitlyTypedBinding (Identifier "id") [Alternative [VariablePattern (Identifier "x")] (VariableExpression (Identifier "x"))]]]])
-- ["id :: forall a0. a0 -> a0"]
--
-- Throws 'InferException' in case of a type error.
typeCheckModule
  :: MonadThrow m
  => ClassEnvironment Name -- ^ Set of defined type-classes.
  -> [(TypeSignature Name Name)] -- ^ Pre-defined type signatures e.g. for built-ins or FFI.
  -> SpecialTypes Name -- ^ Special types that Haskell uses for pattern matching and literals.
  -> [BindGroup Name l] -- ^ Bindings in the module.
  -> m [BindGroup Name (TypeSignature Name l)] -- ^ Inferred types for all identifiers.
typeCheckModule ce as specialTypes bgs =
  evalStateT
    (runInferT $ do
       (ps, _, bgs') <- inferSequenceTypes inferBindGroupTypes ce as bgs
       s <- InferT (gets inferStateSubstitutions)
       let rs = reduce ce (map (substitutePredicate s) ps)
       s' <- defaultSubst ce [] rs
       return (map (fmap (substituteTypeSignature (s' @@ s))) bgs'))
    (InferState nullSubst 0 specialTypes) {-[]-}

--------------------------------------------------------------------------------
-- Substitution

infixr 4 @@
(@@) :: [Substitution Name] -> [Substitution Name] -> [Substitution Name]
s1 @@ s2 = [Substitution u (substituteType s1 t) | (Substitution u t) <- s2] ++ s1

nullSubst :: [Substitution Name]
nullSubst = []

substituteQualified :: [Substitution Name] -> Qualified Name (Type Name) -> Qualified Name (Type Name)
substituteQualified substitutions (Qualified predicates t) =
  Qualified
    (map (substitutePredicate substitutions) predicates)
    (substituteType substitutions t)

substituteTypeSignature :: [Substitution Name] -> (TypeSignature Name l) -> (TypeSignature Name l)
substituteTypeSignature substitutions (TypeSignature l scheme) =
    TypeSignature l (substituteInScheme substitutions scheme)
  where substituteInScheme substitutions (Forall kinds qualified) =
          Forall kinds (substituteQualified substitutions qualified)

substitutePredicate :: [Substitution Name] -> Predicate Name -> Predicate Name
substitutePredicate substitutions (IsIn identifier types) =
    IsIn identifier (map (substituteType substitutions) types)

substituteType :: [Substitution Name] -> Type Name -> Type Name
substituteType substitutions (VariableType typeVariable) =
    case find ((== typeVariable) . substitutionTypeVariable) substitutions of
      Just substitution -> substitutionType substitution
      Nothing -> VariableType typeVariable
substituteType substitutions (ApplicationType type1 type2) =
    ApplicationType
      (substituteType substitutions type1)
      (substituteType substitutions type2)
substituteType _ typ = typ

--------------------------------------------------------------------------------
-- Type inference

unify :: MonadThrow m => Type Name -> Type Name -> InferT m ()
unify t1 t2 = do
  s <- InferT (gets inferStateSubstitutions)
  u <- unifyTypes (substituteType s t1) (substituteType s t2)
  InferT
    (modify
       (\s -> s {inferStateSubstitutions = u @@ inferStateSubstitutions s}))

newVariableType :: Monad m => Kind -> InferT m (Type Name)
newVariableType k =
  InferT
    (do inferState <- get
        put inferState {inferStateCounter = inferStateCounter inferState + 1}
        return
          (VariableType (TypeVariable (enumId (inferStateCounter inferState)) k)))

inferExplicitlyTypedBindingType
  :: MonadThrow m
  => ClassEnvironment Name
  -> [TypeSignature Name Name]
  -> (ExplicitlyTypedBinding Name l)
  -> InferT m ([Predicate Name], ExplicitlyTypedBinding Name (TypeSignature Name l))
inferExplicitlyTypedBindingType ce as (ExplicitlyTypedBinding identifier sc alts) = do
  (Qualified qs t) <- freshInst sc
  (ps, alts') <- inferAltTypes ce as alts t
  s <- InferT (gets inferStateSubstitutions)
  let qs' = map (substitutePredicate s) qs
      t' = substituteType s t
      fs = getTypeVariablesOf getTypeSignatureTypeVariables (map (substituteTypeSignature s) as)
      gs = getTypeTypeVariables t' \\ fs
      sc' = quantify gs (Qualified qs' t')
      ps' = filter (not . entail ce qs') (map (substitutePredicate s) ps)
  (ds, rs) <- split ce fs gs ps'
  if sc /= sc'
    then throwM SignatureTooGeneral
    else if not (null rs)
           then throwM ContextTooWeak
           else return (ds, ExplicitlyTypedBinding identifier sc alts')

inferImplicitlyTypedBindingsTypes
  :: MonadThrow m
  => ClassEnvironment Name
  -> [(TypeSignature Name Name)]
  -> [ImplicitlyTypedBinding Name l]
  -> InferT m ([Predicate Name], [(TypeSignature Name Name)], [ImplicitlyTypedBinding Name (TypeSignature Name l)])
inferImplicitlyTypedBindingsTypes ce as bs = do
  ts <- mapM (\_ -> newVariableType StarKind) bs
  let is = map implicitlyTypedBindingId bs
      scs = map toScheme ts
      as' = zipWith (\x y -> TypeSignature x y) is scs ++ as
  pss0 <-
    sequence
      (zipWith
         (\b t -> inferAltTypes ce as' (implicitlyTypedBindingAlternatives b) t)
         bs
         ts)
  let pss = map fst pss0
      binds' = map snd pss0
  s <- InferT (gets inferStateSubstitutions)
  let ps' = map (substitutePredicate s) (concat pss)
      ts' = map (substituteType s) ts
      fs =
        getTypeVariablesOf
          getTypeSignatureTypeVariables
          (map (substituteTypeSignature s) as)
      vss = map getTypeTypeVariables ts'
      gs = foldr1 union vss \\ fs
  (ds, rs) <- split ce fs (foldr1 intersect vss) ps'
  if restrictImplicitlyTypedBindings bs
    then let gs' = gs \\ getTypeVariablesOf getPredicateTypeVariables rs
             scs' = map (quantify gs' . (Qualified [])) ts'
         in return
              ( ds ++ rs
              , zipWith (\x y -> TypeSignature x y) is scs'
              , zipWith
                  (\(ImplicitlyTypedBinding l tid _, binds') scheme ->
                     ImplicitlyTypedBinding (TypeSignature l scheme) tid binds')
                  (zip bs binds')
                  scs')
    else let scs' = map (quantify gs . (Qualified rs)) ts'
         in return
              ( ds
              , zipWith (\x y -> TypeSignature x y) is scs'
              , zipWith
                  (\(ImplicitlyTypedBinding l tid _, binds') scheme ->
                     ImplicitlyTypedBinding (TypeSignature l scheme) tid binds')
                  (zip bs binds')
                  scs')

inferBindGroupTypes
  :: MonadThrow m
  => ClassEnvironment Name
  -> [(TypeSignature Name Name)]
  -> (BindGroup Name l)
  -> InferT m ([Predicate Name], [(TypeSignature Name Name)], BindGroup Name (TypeSignature Name l))
inferBindGroupTypes ce as (BindGroup es iss) = do
  let as' = [TypeSignature v sc | ExplicitlyTypedBinding v sc _alts <- es]
  (ps, as'', iss') <-
    inferSequenceTypes0 inferImplicitlyTypedBindingsTypes ce (as' ++ as) iss
  qss <- mapM (inferExplicitlyTypedBindingType ce (as'' ++ as' ++ as)) es
  return (ps ++ concat (map fst qss), as'' ++ as', BindGroup (map snd qss) iss')

inferSequenceTypes0
  :: Monad m
  => (ClassEnvironment Name -> [(TypeSignature Name Name)] -> [bg l] -> InferT m ([Predicate Name], [(TypeSignature Name Name)], [bg (TypeSignature Name l)]))
  -> ClassEnvironment Name
  -> [(TypeSignature Name Name)]
  -> [[bg l]]
  -> InferT m ([Predicate Name], [(TypeSignature Name Name)], [[bg (TypeSignature Name l)]])
inferSequenceTypes0 _ _ _ [] = return ([], [], [])
inferSequenceTypes0 ti ce as (bs:bss) = do
  (ps, as', bs') <- ti ce as bs
  (qs, as'', bss') <- inferSequenceTypes0 ti ce (as' ++ as) bss
  return (ps ++ qs, as'' ++ as', bs' : bss')

inferSequenceTypes
  :: Monad m
  => (ClassEnvironment Name -> [(TypeSignature Name Name)] -> bg l -> InferT m ([Predicate Name], [(TypeSignature Name Name)], bg (TypeSignature Name l)))
  -> ClassEnvironment Name
  -> [(TypeSignature Name Name)]
  -> [bg l]
  -> InferT m ([Predicate Name], [(TypeSignature Name Name)], [bg (TypeSignature Name l)])
inferSequenceTypes _ _ _ [] = return ([], [], [])
inferSequenceTypes ti ce as (bs:bss) = do
  (ps, as', bs') <- ti ce as bs
  (qs, as'', bss') <- inferSequenceTypes ti ce (as' ++ as) bss
  return (ps ++ qs, as'' ++ as', bs' : bss')

--------------------------------------------------------------------------------
-- Instantiation

instantiateType :: [Type Name] -> Type Name -> Type Name
instantiateType ts (ApplicationType l r) =
  ApplicationType (instantiateType ts l) (instantiateType ts r)
instantiateType ts (GenericType n) = ts !! n
instantiateType _ t = t

instantiateQualified :: [Type Name] -> Qualified Name (Type Name) -> Qualified Name (Type Name)
instantiateQualified ts (Qualified ps t) =
  Qualified (map (instantiatePredicate ts) ps) (instantiateType ts t)

instantiatePredicate :: [Type Name] -> Predicate Name -> Predicate Name
instantiatePredicate ts (IsIn c t) = IsIn c (map (instantiateType ts) t)

--------------------------------------------------------------------------------
-- Type variables

getTypeSignatureTypeVariables :: (TypeSignature Name Name) -> [TypeVariable Name]
getTypeSignatureTypeVariables = getTypeVariables where
  getTypeVariables (TypeSignature _  scheme) = getSchemeTypeVariables scheme
    where getSchemeTypeVariables (Forall _ qualified) = getQualifiedTypeVariables qualified

getQualifiedTypeVariables :: Qualified Name (Type Name) -> [TypeVariable Name]
getQualifiedTypeVariables = getTypeVariables
  where
    getTypeVariables (Qualified predicates t) =
      getTypeVariablesOf getPredicateTypeVariables predicates `union`
      getTypeTypeVariables t

getPredicateTypeVariables :: Predicate Name -> [TypeVariable Name]
getPredicateTypeVariables (IsIn _ types) = getTypeVariablesOf getTypeTypeVariables types

getTypeTypeVariables :: Type Name -> [TypeVariable Name]
getTypeTypeVariables = getTypeVariables where
  getTypeVariables (VariableType typeVariable) = [typeVariable]
  getTypeVariables (ApplicationType type1 type2) =
    getTypeVariables type1 `union` getTypeVariables type2
  getTypeVariables _ = []

getTypeVariablesOf :: (a -> [TypeVariable Name]) -> [a] -> [TypeVariable Name]
getTypeVariablesOf f = nub . concatMap f

-- | Get the kind of a type.
typeKind :: Type Name -> Kind
typeKind (ConstructorType typeConstructor) = typeConstructorKind typeConstructor
typeKind (VariableType typeVariable) = typeVariableKind typeVariable
typeKind (ApplicationType typ _) =
  case (typeKind typ) of
    (FunctionKind _ kind) -> kind

--------------------------------------------------------------------------------
-- GOOD NAMING CONVENInferON, UNSORTED

-- | The monomorphism restriction is invoked when one or more of the
-- entries in a list of implicitly typed bindings is simple, meaning
-- that it has an alternative with no left-hand side patterns. The
-- following function provides a way to test for this:
restrictImplicitlyTypedBindings :: [(ImplicitlyTypedBinding Name l)] -> Bool
restrictImplicitlyTypedBindings = any simple
  where
    simple =
      any (null . alternativePatterns) . implicitlyTypedBindingAlternatives

-- | The following function calculates the list of ambiguous variables
-- and pairs each one with the list of predicates that must be
-- satisfied by any choice of a default:
ambiguities :: [TypeVariable Name] -> [Predicate Name] -> [Ambiguity Name]
ambiguities typeVariables predicates =
  [ Ambiguity typeVariable (filter (elem typeVariable . getPredicateTypeVariables) predicates)
  | typeVariable <- getTypeVariablesOf getPredicateTypeVariables predicates \\ typeVariables
  ]

-- | The unifyTypeVariable function is used for the special case of unifying a
-- variable u with a type t.
unifyTypeVariable :: MonadThrow m => TypeVariable Name -> Type Name -> m [Substitution Name]
unifyTypeVariable typeVariable typ
  | typ == VariableType typeVariable = return nullSubst
  | typeVariable `elem` getTypeTypeVariables typ = throwM OccursCheckFails
  | typeVariableKind typeVariable /= typeKind typ = throwM KindMismatch
  | otherwise = return [Substitution typeVariable typ]

unifyPredicates :: Predicate Name -> Predicate Name -> Maybe [Substitution Name]
unifyPredicates = lift' unifyTypeList

oneWayMatchPredicate :: Predicate Name -> Predicate Name -> Maybe [Substitution Name]
oneWayMatchPredicate = lift' oneWayMatchLists

unifyTypes :: MonadThrow m => Type Name -> Type Name -> m [Substitution Name]
unifyTypes (ApplicationType l r) (ApplicationType l' r') = do
              s1 <- unifyTypes l l'
              s2 <- unifyTypes (substituteType s1 r) (substituteType s1 r')
              return (s2 @@ s1)
unifyTypes (VariableType u) t = unifyTypeVariable u t
unifyTypes t (VariableType u) = unifyTypeVariable u t
unifyTypes (ConstructorType tc1) (ConstructorType tc2)
              | tc1 == tc2 = return nullSubst
unifyTypes _ _ = throwM TypeMismatch

unifyTypeList :: MonadThrow m => [Type Name] -> [Type Name] -> m [Substitution Name]
unifyTypeList (x:xs) (y:ys) = do
    s1 <- unifyTypes x y
    s2 <- unifyTypeList (map (substituteType s1) xs) (map (substituteType s1) ys)
    return (s2 @@ s1)
unifyTypeList [] [] = return nullSubst
unifyTypeList _ _ = throwM ListsDoNotUnify

oneWayMatchType :: MonadThrow m => Type Name -> Type Name -> m [Substitution Name]
oneWayMatchType (ApplicationType l r) (ApplicationType l' r') = do
  sl <- oneWayMatchType l l'
  sr <- oneWayMatchType r r'
  merge sl sr
oneWayMatchType (VariableType u) t
  | typeVariableKind u == typeKind t = return [Substitution u t]
oneWayMatchType (ConstructorType tc1) (ConstructorType tc2)
  | tc1 == tc2 = return nullSubst
oneWayMatchType _ _ = throwM TypeMismatchOneWay

oneWayMatchLists :: MonadThrow m => [Type Name] -> [Type Name] -> m [Substitution Name]
oneWayMatchLists ts ts' = do
    ss <- sequence (zipWith oneWayMatchType ts ts')
    foldM merge nullSubst ss

--------------------------------------------------------------------------------
-- Garbage

lookupName
  :: MonadThrow m
  => Name -> [(TypeSignature Name Name)] -> m (Scheme Name)
lookupName name candidates = go name candidates where
  go n [] = throwM (NotInScope candidates n)
  go i ((TypeSignature i'  sc):as) =
    if i == i'
      then return sc
      else go i as

enumId :: Int -> Name
enumId n = NameForall n

inferLiteralType
  :: Monad m
  => SpecialTypes Name -> Literal -> InferT m ([Predicate Name], Type Name)
inferLiteralType specialTypes (CharacterLiteral _) =
  return ([], specialTypesChar specialTypes)
inferLiteralType specialTypes (IntegerLiteral _) = do
  v <- newVariableType StarKind
  return ([IsIn (specialTypesNum specialTypes) [v]], v)
inferLiteralType specialTypes (StringLiteral _) =
  return ([], specialTypesString specialTypes)
inferLiteralType specialTypes (RationalLiteral _) = do
  v <- newVariableType StarKind
  return ([IsIn (specialTypesFractional specialTypes) [v]], v)

inferPattern
  :: MonadThrow m
  => Pattern Name -> InferT m ([Predicate Name], [(TypeSignature Name Name)], Type Name)
inferPattern (VariablePattern i) = do
  v <- newVariableType StarKind
  return ([], [TypeSignature i (toScheme v)], v)
inferPattern WildcardPattern = do
  v <- newVariableType StarKind
  return ([], [], v)
inferPattern (AsPattern i pat) = do
  (ps, as, t) <- inferPattern pat
  return (ps, (TypeSignature i (toScheme t)) : as, t)
inferPattern (LiteralPattern l) = do
  specialTypes <- InferT (gets inferStateSpecialTypes)
  (ps, t) <- inferLiteralType specialTypes l
  return (ps, [], t)
inferPattern (ConstructorPattern (TypeSignature _  sc) pats) = do
  (ps, as, ts) <- inferPatterns pats
  t' <- newVariableType StarKind
  (Qualified qs t) <- freshInst sc
  specialTypes <- InferT (gets inferStateSpecialTypes)
  let makeArrow :: Type Name -> Type Name -> Type Name
      a `makeArrow` b = ApplicationType (ApplicationType (specialTypesFunction specialTypes) a) b
  unify t (foldr makeArrow t' ts)
  return (ps ++ qs, as, t')
-- inferPattern (LazyPattern pat) = inferPattern pat

inferPatterns
  :: MonadThrow m
  => [Pattern Name] -> InferT m ([Predicate Name], [(TypeSignature Name Name)], [Type Name])
inferPatterns pats = do
  psasts <- mapM inferPattern pats
  let ps = concat [ps' | (ps', _, _) <- psasts]
      as = concat [as' | (_, as', _) <- psasts]
      ts = [t | (_, _, t) <- psasts]
  return (ps, as, ts)

predHead :: Predicate Name -> Name
predHead (IsIn i _) = i

lift'
  :: MonadThrow m
  => ([Type Name] -> [Type Name] -> m a) -> Predicate Name -> Predicate Name -> m a
lift' m (IsIn i ts) (IsIn i' ts')
  | i == i' = m ts ts'
  | otherwise = throwM ClassMismatch

lookupClassTypeVariables :: ClassEnvironment Name -> Name -> [TypeVariable Name]
lookupClassTypeVariables ce i =
  fromMaybe
    []
    (fmap classTypeVariables (M.lookup i (classEnvironmentClasses ce)))

lookupClassSuperclasses :: ClassEnvironment Name -> Name -> [Predicate Name]
lookupClassSuperclasses ce i = maybe [] classPredicates (M.lookup i (classEnvironmentClasses ce))

lookupClassInstances :: ClassEnvironment Name -> Name -> [Qualified Name (Predicate Name)]
lookupClassInstances ce i =
  maybe [] classQualifiedPredicates (M.lookup i (classEnvironmentClasses ce))

defined :: Maybe a -> Bool
defined (Just _) = True
defined Nothing = False

modify0 :: ClassEnvironment Name -> Name -> Class Name -> ClassEnvironment Name
modify0 ce i c =
  ce {classEnvironmentClasses = M.insert i c (classEnvironmentClasses ce)}

-- | Add a class to the environment. Example:
--
-- @
-- env <- addClass (Name \"Num\") [TypeVariable (Name \"n\") StarKind] [] mempty
-- @
--
-- Throws 'ReadException' in the case of error.
addClass
  :: MonadThrow m
  => Name
  -> [TypeVariable Name]
  -> [Predicate Name]
  -> ClassEnvironment Name
  -> m (ClassEnvironment Name)
addClass i vs ps ce
  | defined (M.lookup i (classEnvironmentClasses ce)) = throwM ClassAlreadyDefined
  | any (not . defined . flip M.lookup (classEnvironmentClasses ce) . predHead) ps =
    throwM UndefinedSuperclass
  | otherwise = return (modify0 ce i (Class vs ps []))

-- | Add an instance of a class. Example:
--
-- @
-- env <- addInstance [] (IsIn (Name \"Num\") [ConstructorType (TypeConstructor (Name \"Integer\") StarKind)]) mempty
-- @
--
-- Throws 'ReadException' in the case of error.
addInstance
  :: MonadThrow m
  => [Predicate Name] -> Predicate Name -> ClassEnvironment Name -> m (ClassEnvironment Name)
addInstance ps p@(IsIn i _) ce
  | not (defined (M.lookup i (classEnvironmentClasses ce))) =
    throwM NoSuchClassForInstance
  | any (overlap p) qs = throwM OverlappingInstance
  | otherwise = return (modify0 ce i c)
  where
    its = lookupClassInstances ce i
    qs = [q | (Qualified _ q) <- its]
    c = (Class (lookupClassTypeVariables ce i) (lookupClassSuperclasses ce i) (Qualified ps p : its))

overlap :: Predicate Name -> Predicate Name -> Bool
overlap p q = defined (unifyPredicates p q)

bySuper :: ClassEnvironment Name -> Predicate Name -> [Predicate Name]
bySuper ce p@(IsIn i ts) = p : concat (map (bySuper ce) supers)
  where
    supers = map (substitutePredicate substitutions) (lookupClassSuperclasses ce i)
    substitutions = zipWith Substitution (lookupClassTypeVariables ce i) ts

byInst :: ClassEnvironment Name -> Predicate Name -> Maybe [Predicate Name]
byInst ce p@(IsIn i _) = msum [tryInst it | it <- lookupClassInstances ce i]
  where
    tryInst (Qualified ps h) = do
      u <- oneWayMatchPredicate h p
      Just (map (substitutePredicate u) ps)

entail :: ClassEnvironment Name -> [Predicate Name] -> Predicate Name -> Bool
entail ce ps p =
  any (p `elem`) (map (bySuper ce) ps) ||
  case byInst ce p of
    Nothing -> False
    Just qs -> all (entail ce ps) qs

simplify :: ([Predicate Name] -> Predicate Name -> Bool) -> [Predicate Name] -> [Predicate Name]
simplify ent = loop []
  where
    loop rs [] = rs
    loop rs (p:ps)
      | ent (rs ++ ps) p = loop rs ps
      | otherwise = loop (p : rs) ps

reduce :: ClassEnvironment Name -> [Predicate Name] -> [Predicate Name]
reduce ce = simplify (scEntail ce) . elimTauts ce

elimTauts :: ClassEnvironment Name -> [Predicate Name] -> [Predicate Name]
elimTauts ce ps = [p | p <- ps, not (entail ce [] p)]

scEntail :: ClassEnvironment Name -> [Predicate Name] -> Predicate Name -> Bool
scEntail ce ps p = any (p `elem`) (map (bySuper ce) ps)

quantify :: [TypeVariable Name] -> Qualified Name (Type Name) -> Scheme Name
quantify vs qt = Forall ks (substituteQualified s qt)
  where
    vs' = [v | v <- getQualifiedTypeVariables qt, v `elem` vs]
    ks = map typeVariableKind vs'
    s = zipWith Substitution vs' (map GenericType [0 ..])

toScheme :: Type Name -> Scheme Name
toScheme t = Forall [] (Qualified [] t)

merge
  :: MonadThrow m
  => [Substitution Name] -> [Substitution Name] -> m [Substitution Name]
merge s1 s2 =
  if agree
    then return (s1 ++ s2)
    else throwM MergeFail
  where
    agree =
      all
        (\v -> substituteType s1 (VariableType v) == substituteType s2 (VariableType v))
        (map substitutionTypeVariable s1 `intersect`
         map substitutionTypeVariable s2)

inferExpressionType
  :: MonadThrow m
  => ClassEnvironment Name
  -> [(TypeSignature Name Name)]
  -> (Expression Name l)
  -> InferT m ([Predicate Name], Type Name, Expression Name (TypeSignature Name l))
inferExpressionType _ as (VariableExpression l i) = do
  sc <- lookupName i as
  qualified@(Qualified ps t) <- freshInst sc
  let scheme = (Forall [] qualified)
  return (ps, t, VariableExpression (TypeSignature l scheme) i)
inferExpressionType _ _ (ConstantExpression l s@(TypeSignature _  sc)) = do
  (Qualified ps t) <- freshInst sc
  return (ps, t, (ConstantExpression (TypeSignature l sc) s))
inferExpressionType _ _ (LiteralExpression l0 l) = do
  specialTypes <- InferT (gets inferStateSpecialTypes)
  (ps, t) <- inferLiteralType specialTypes l
  let scheme = (Forall [] (Qualified ps t))
  return (ps, t, LiteralExpression (TypeSignature l0 scheme) l)
inferExpressionType ce as (ApplicationExpression l e f) = do
  (ps, te, e') <- inferExpressionType ce as e
  (qs, tf, f') <- inferExpressionType ce as f
  t <- newVariableType StarKind
  specialTypes <- InferT (gets inferStateSpecialTypes)
  let makeArrow :: Type Name -> Type Name -> Type Name
      a `makeArrow` b = ApplicationType (ApplicationType (specialTypesFunction specialTypes) a) b
  unify (tf `makeArrow` t) te
  let scheme = (Forall [] (Qualified (ps++qs) t))
  return (ps ++ qs, t, ApplicationExpression (TypeSignature l scheme) e' f')
inferExpressionType ce as (InfixExpression l x op y) = do
  inferExpressionType
    ce
    as
    (ApplicationExpression
       l
       (ApplicationExpression l x (VariableExpression l op))
       y)
inferExpressionType ce as (LetExpression l bg e) = do
  (ps, as', bg') <- inferBindGroupTypes ce as bg
  (qs, t, e') <- inferExpressionType ce (as' ++ as) e
  let scheme = (Forall [] (Qualified (ps++qs) t))
  return (ps ++ qs, t, LetExpression (TypeSignature l scheme) bg' e')
inferExpressionType ce as (LambdaExpression l alt) = do
  (x, y, s) <- inferAltType ce as alt
  pure
    ( x
    , y
    , LambdaExpression
        (TypeSignature l (typeSignatureScheme (alternativeLabel s)))
        s)
inferExpressionType ce as (IfExpression l e e1 e2) = do
  (ps, t, e') <- inferExpressionType ce as e
  specialTypes <- InferT (gets inferStateSpecialTypes)
  unify t (specialTypesBool specialTypes)
  (ps1, t1, e1') <- inferExpressionType ce as e1
  (ps2, t2, e2') <- inferExpressionType ce as e2
  unify t1 t2
  let scheme = (Forall [] (Qualified (ps ++ ps1 ++ ps2) t1))
  return (ps ++ ps1 ++ ps2, t1, IfExpression (TypeSignature l scheme) e' e1' e2')
inferExpressionType ce as (CaseExpression l e branches) = do
  (ps0, t, e') <- inferExpressionType ce as e
  v <- newVariableType StarKind
  let tiBr (pat, f) = do
        (ps, as', t') <- inferPattern pat
        unify t t'
        (qs, t'', f') <- inferExpressionType ce (as' ++ as) f
        unify v t''
        return (ps ++ qs, (pat, f'))
  branches <- mapM tiBr branches
  let pss = map fst branches
      branches' = map snd branches
  let scheme = (Forall [] (Qualified (ps0 ++ concat pss) v))
  return (ps0 ++ concat pss, v, CaseExpression (TypeSignature l scheme) e' branches')

inferAltType
  :: MonadThrow m
  => ClassEnvironment Name
  -> [(TypeSignature Name Name)]
  -> Alternative Name l
  -> InferT m ([Predicate Name], Type Name, Alternative Name (TypeSignature Name l))
inferAltType ce as (Alternative l pats e) = do
  (ps, as', ts) <- inferPatterns pats
  (qs, t, e') <- inferExpressionType ce (as' ++ as) e
  specialTypes <- InferT (gets inferStateSpecialTypes)
  let makeArrow :: Type Name -> Type Name -> Type Name
      a `makeArrow` b = ApplicationType (ApplicationType (specialTypesFunction specialTypes) a) b
  let scheme = (Forall [] (Qualified (ps ++ qs) (foldr makeArrow t ts)))
  return (ps ++ qs, foldr makeArrow t ts, Alternative (TypeSignature l scheme) pats e')

inferAltTypes
  :: MonadThrow m
  => ClassEnvironment Name
  -> [(TypeSignature Name Name)]
  -> [Alternative Name l]
  -> Type Name
  -> InferT m ([Predicate Name], [Alternative Name (TypeSignature Name l)])
inferAltTypes ce as alts t = do
  psts <- mapM (inferAltType ce as) alts
  mapM_ (unify t) (map snd3 psts)
  return (concat (map fst3 psts), map thd3 psts)
  where snd3 (_,x,_) = x
        thd3 (_,_,x) = x
        fst3 (x,_,_) = x

split
  :: MonadThrow m
  => ClassEnvironment Name -> [TypeVariable Name] -> [TypeVariable Name] -> [Predicate Name] -> m ([Predicate Name], [Predicate Name])
split ce fs gs ps = do
  let ps' = reduce ce ps
      (ds, rs) = partition (all (`elem` fs) . getPredicateTypeVariables) ps'
  rs' <- defaultedPredicates ce (fs ++ gs) rs
  return (ds, rs \\ rs')

candidates :: ClassEnvironment Name -> Ambiguity Name -> [Type Name]
candidates ce (Ambiguity v qs) =
  [ t'
  | let is = [i | IsIn i _ <- qs]
        ts = [t | IsIn _ t <- qs]
  , all ([VariableType v] ==) ts
  , any (`elem` numClasses) is
  , all (`elem` stdClasses) is
  , t' <- []{-classEnvironmentDefaults ce-}
  , all (entail ce []) [IsIn i [t'] | i <- is]
  ]
  where -- disabling these
        numClasses = []
        stdClasses = []

withDefaults
  :: MonadThrow m
  => String->([Ambiguity Name] -> [Type Name] -> a) -> ClassEnvironment Name -> [TypeVariable Name] -> [Predicate Name] -> m a
withDefaults _label f ce vs ps
  | any null tss = throwM AmbiguousInstance
  | otherwise = do
    return (f vps (map head tss))
  where
    -- showp :: Show a => a -> String
    -- showp = \x -> "(" ++ show x ++ ")"
    vps = ambiguities vs ps
    tss = map (candidates ce) vps

defaultedPredicates
  :: MonadThrow m
  => ClassEnvironment Name -> [TypeVariable Name] -> [Predicate Name] -> m [Predicate Name]
defaultedPredicates = withDefaults "defaultedPredicates" (\vps _ -> concat (map ambiguityPredicates vps))

defaultSubst
  :: MonadThrow m
  => ClassEnvironment Name -> [TypeVariable Name] -> [Predicate Name] -> m [Substitution Name]
defaultSubst = withDefaults "defaultSubst" (\vps ts -> zipWith Substitution (map ambiguityTypeVariable vps) ts)

-- extSubst
--   :: Monad m
--   => [Substitution] -> InferT m ()
-- extSubst s' =
--   InferT
--     (modify
--        (\s -> s {inferStateSubstitutions = s' @@ inferStateSubstitutions s}))

freshInst
  :: Monad m
  => Scheme Name -> InferT m (Qualified Name (Type Name))
freshInst (Forall ks qt) = do
  ts <- mapM newVariableType ks
  return (instantiateQualified ts qt)
