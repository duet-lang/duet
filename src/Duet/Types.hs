{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | Data types for the project.

module Duet.Types where

import           Control.DeepSeq
import           Control.Monad.Catch
import           Control.Monad.State
import           Data.Data (Data, Typeable)
import           Data.Map.Strict (Map)
import           Data.String
import           Data.Text (Text)
import           GHC.Generics
import           Text.Parsec (ParseError)

-- | A declaration.
instance (NFData l, NFData i, NFData (t i)) => NFData (Decl t i l)


data Decl t i l
  = DataDecl l (DataType t i)
  -- | BindGroupDecl l (BindGroup t i l)
  | BindDecl l (Binding t i l)
  | ClassDecl l (Class t i l)
  | InstanceDecl l (Instance t i l)
  deriving (Show, Generic, Data, Typeable)

instance (NFData l, NFData i, NFData (t i)) => NFData (Binding t i l)


data Binding t i l
  = ImplicitBinding (ImplicitlyTypedBinding t i l)
  | ExplicitBinding (ExplicitlyTypedBinding t i l)
  deriving (Show, Generic, Data, Typeable)

bindingIdentifier :: Binding t i l -> i
bindingIdentifier =
  \case
    ImplicitBinding i -> fst (implicitlyTypedBindingId i)
    ExplicitBinding i -> fst (explicitlyTypedBindingId i)

bindingAlternatives :: Binding t i l -> [Alternative t i l]
bindingAlternatives =
  \case
    ImplicitBinding i -> implicitlyTypedBindingAlternatives i
    ExplicitBinding i -> explicitlyTypedBindingAlternatives i

declLabel :: Decl t i l -> l
declLabel =
  \case
    DataDecl l _ -> l
    BindDecl l _ -> l
    ClassDecl l _ -> l
    InstanceDecl l _ -> l

-- | Data type.
instance (NFData i, NFData (t i)) => NFData (DataType t i )


data DataType t i = DataType
  { dataTypeName :: i
  , dataTypeVariables :: [TypeVariable i]
  , dataTypeConstructors :: [DataTypeConstructor t i]
  } deriving (Show, Generic, Data, Typeable)

dataTypeConstructor :: DataType Type Name -> Type Name
dataTypeConstructor (DataType name vs _) =
  ConstructorType (toTypeConstructor name vs)

toTypeConstructor :: Name -> [TypeVariable Name] -> TypeConstructor Name
toTypeConstructor name vars =
  TypeConstructor name (foldr FunctionKind StarKind (map typeVariableKind vars))

dataTypeToConstructor :: DataType t Name -> TypeConstructor Name
dataTypeToConstructor (DataType name vs _) =
  toTypeConstructor name vs

-- | A data type constructor.
instance (NFData i, NFData (t i)) => NFData (DataTypeConstructor t i)


data DataTypeConstructor t i = DataTypeConstructor
  { dataTypeConstructorName :: i
  , dataTypeConstructorFields :: [t i]
  } deriving (Show, Generic, Data, Typeable)

-- | Type for a data typed parsed from user input.
instance (NFData i) => NFData (UnkindedType i)


data UnkindedType i
  = UnkindedTypeConstructor i
  | UnkindedTypeVariable i
  | UnkindedTypeApp (UnkindedType i) (UnkindedType i)
  deriving (Show, Generic, Data, Typeable)

-- | Special built-in types you need for type-checking patterns and
-- literals.
instance (NFData i) => NFData (SpecialTypes i )


data SpecialTypes i = SpecialTypes
  { specialTypesBool       :: DataType Type i
  , specialTypesChar       :: TypeConstructor i
  , specialTypesString     :: TypeConstructor i
  , specialTypesFunction   :: TypeConstructor i
  , specialTypesInteger    :: TypeConstructor i
  , specialTypesRational   :: TypeConstructor i
  } deriving (Show, Generic, Data, Typeable)

-- | Special built-in signatures.
instance (NFData i) => NFData (SpecialSigs i)


data SpecialSigs i = SpecialSigs
  { specialSigsTrue :: i
  , specialSigsFalse :: i
  , specialSigsPlus :: i
  , specialSigsTimes :: i
  , specialSigsSubtract :: i
  , specialSigsDivide :: i
  } deriving (Show, Generic, Data, Typeable)

-- | Type inference monad.
newtype InferT m a = InferT
  { runInferT :: StateT InferState m a
  } deriving (Monad, Applicative, Functor, MonadThrow)

-- | Name is a globally unique identifier for any thing. No claim
-- about "existence", but definitely uniquness. A name names one thing
-- and one thing only.
--
-- So this comes /after/ the parsing step, and /before/ the
-- type-checking step. The renamer's job is to go from Identifier -> Name.
data Name
  = ValueName !Int !String
  | ConstructorName !Int !String
  | TypeName !Int !String
  | ForallName !Int
  | DictName !Int String
  | ClassName !Int String
  | MethodName !Int String
  | PrimopName Primop
  deriving (Show, Generic, Data, Typeable, Eq, Ord)
instance NFData Name

-- | Pre-defined operations.
instance NFData (Primop)
data Primop
  = PrimopIntegerPlus
  | PrimopIntegerSubtract
  | PrimopIntegerTimes
  | PrimopRationalDivide
  | PrimopRationalPlus
  | PrimopRationalSubtract
  | PrimopRationalTimes
  | PrimopStringAppend
  | PrimopStringDrop
  | PrimopStringTake
  deriving (Show, Generic, Data, Typeable, Eq, Ord, Enum, Bounded)

-- | State of inferring.
instance NFData (InferState)
data InferState = InferState
  { inferStateSubstitutions :: ![Substitution Name]
  , inferStateCounter :: !Int
  , inferStateSpecialTypes :: !(SpecialTypes Name)
  } deriving (Show, Generic, Data, Typeable)

data ParseException
  = TokenizerError ParseError
  | ParserError ParseError
 deriving (Typeable, Show)
instance Exception ParseException

data StepException
  = CouldntFindName !Name
  | CouldntFindNameByString !String
  | TypeAtValueScope !Name
  | CouldntFindMethodDict !Name
  deriving (Typeable, Show)
instance Exception StepException


newtype UUID = UUID String
  deriving (Ord, Eq, Show, Generic, Data, Typeable)
instance NFData UUID

instance NFData (RenamerException)
data RenamerException
  = IdentifierNotInVarScope !(Map Identifier Name) !Identifier !Location
  | IdentifierNotInConScope !(Map Identifier Name) !Identifier
  | IdentifierNotInClassScope !(Map Identifier Name) !Identifier
  | IdentifierNotInTypeScope !(Map Identifier Name) !Identifier
  | NameNotInConScope ![TypeSignature Type Name Name] !Name
  | TypeNotInScope ![TypeConstructor Name] !Identifier
  | UnknownTypeVariable ![TypeVariable Name] !Identifier
  | InvalidMethodTypeVariable ![TypeVariable Name] !(TypeVariable Name)
  | KindArgMismatch (Type Name) Kind (Type Name) Kind
  | KindTooManyArgs (Type Name) Kind (Type Name)
  | ConstructorFieldKind Name (Type Name) Kind
  | MustBeStarKind (Type Name) Kind
  | BuiltinNotDefined !String
  | RenamerNameMismatch !Name
  deriving (Show, Generic, Data, Typeable, Typeable)
instance Exception RenamerException

data ContextException = ContextException (SpecialTypes Name) SomeException
  deriving (Show, Generic, Typeable)
instance Exception ContextException

-- | An exception that may be thrown when reading in source code,
-- before we do any type-checking.-}
instance NFData (ReadException)
data ReadException
  = ClassAlreadyDefined
  | NoSuchClassForInstance
  | OverlappingInstance
  | UndefinedSuperclass
  deriving (Show, Generic, Data, Typeable, Typeable)
instance Exception ReadException

instance NFData (ResolveException)
data ResolveException =
  NoInstanceFor (Predicate Type Name)
  deriving (Show, Generic, Data, Typeable, Typeable)
instance Exception ResolveException

-- | A type error.
instance NFData (InferException)
data InferException
  = ExplicitTypeMismatch (Scheme Type Name Type) (Scheme Type Name Type)
  | ContextTooWeak
  | OccursCheckFails
  | KindMismatch
  | TypeMismatch (Type Name) (Type Name)
  | ListsDoNotUnify
  | TypeMismatchOneWay
  | NotInScope ![TypeSignature Type Name Name] !Name
  | ClassMismatch
  | MergeFail
  | AmbiguousInstance [Ambiguity Name]
  | MissingMethod
  | MissingTypeVar (TypeVariable Name) [(TypeVariable Name, Type Name)]

  deriving (Show, Generic, Data, Typeable, Typeable)
instance Exception InferException

-- | Specify the type of @a@.
instance (NFData (t i), NFData i, NFData a) => NFData (TypeSignature t i a)


data TypeSignature (t :: * -> *) i a = TypeSignature
  { typeSignatureA :: a
  , typeSignatureScheme :: Scheme t i t
  } deriving (Show, Generic, Data, Typeable, Functor, Traversable, Foldable, Eq)

instance (NFData (t i),  NFData i, NFData l) => NFData (BindGroup t i l)


data BindGroup (t :: * -> *) i l = BindGroup
  { bindGroupExplicitlyTypedBindings :: ![ExplicitlyTypedBinding t i l]
  , bindGroupImplicitlyTypedBindings :: ![[ImplicitlyTypedBinding t i l]]
  } deriving (Show, Generic, Data, Typeable, Functor, Traversable, Foldable, Eq)

instance (NFData (t i),  NFData i, NFData l) => NFData (ImplicitlyTypedBinding t i l)


data ImplicitlyTypedBinding (t :: * -> *) i l = ImplicitlyTypedBinding
  { implicitlyTypedBindingLabel :: l
  , implicitlyTypedBindingId :: !(i, l)
  , implicitlyTypedBindingAlternatives :: ![Alternative t i l]
  } deriving (Show, Generic, Data, Typeable, Functor, Traversable, Foldable, Eq)

-- | The simplest case is for explicitly typed bindings, each of which
-- is described by the name of the function that is being defined, the
-- declared type scheme, and the list of alternatives in its
-- definition.
--
-- Haskell requires that each Alt in the definition of a given
-- identifier has the same number of left-hand side arguments, but we
-- do not need to enforce that here.
instance (NFData (t i),  NFData l,NFData i) => NFData (ExplicitlyTypedBinding t i l)


data ExplicitlyTypedBinding t i l = ExplicitlyTypedBinding
  { explicitlyTypedBindingLabel :: l
  , explicitlyTypedBindingId :: !(i, l)
  , explicitlyTypedBindingScheme :: !(Scheme t i t)
  , explicitlyTypedBindingAlternatives :: ![(Alternative t i l)]
  } deriving (Show, Generic, Data, Typeable, Functor, Traversable, Foldable, Eq)

-- | Suppose, for example, that we are about to qualify a type with a
-- list of predicates ps and that vs lists all known variables, both
-- fixed and generic. An ambiguity occurs precisely if there is a type
-- variable that appears in ps but not in vs (i.e., in tv ps \\
-- vs). The goal of defaulting is to bind each ambiguous type variable
-- v to a monotype t. The type t must be chosen so that all of the
-- predicates in ps that involve v will be satisfied once t has been
-- substituted for v.
instance (NFData i) => NFData (Ambiguity i)


data Ambiguity i = Ambiguity
  { ambiguityTypeVariable :: !(TypeVariable i)
  , ambiguityPredicates :: ![Predicate Type i]
  } deriving (Show, Generic, Data, Typeable)

-- | An Alt specifies the left and right hand sides of a function
-- definition. With a more complete syntax for Expr, values of type
-- Alt might also be used in the representation of lambda and case
-- expressions.
instance (NFData (t i),  NFData l, NFData i) => NFData (Alternative t i l)


data Alternative t i l = Alternative
  { alternativeLabel :: l
  , alternativePatterns :: ![Pattern t i l]
  , alternativeExpression :: !(Expression t i l)
  } deriving (Show, Generic, Data, Typeable, Functor, Traversable, Foldable, Eq)

-- | Substitutions-finite functions, mapping type variables to
-- types-play a major role in type inference.
instance (NFData i) => NFData (Substitution i)


data Substitution i = Substitution
  { substitutionTypeVariable :: !(TypeVariable i)
  , substitutionType :: !(Type i)
  } deriving (Show, Generic, Data, Typeable)

-- | A type variable.
instance (NFData i) => NFData (TypeVariable i)


data TypeVariable i = TypeVariable
  { typeVariableIdentifier :: !i
  , typeVariableKind :: !Kind
  } deriving (Ord, Eq, Show, Generic, Data, Typeable)

-- | An identifier used for variables.
newtype Identifier = Identifier
  { identifierString :: String
  } deriving (Eq, IsString, Ord, Show , Generic, Data, Typeable)
instance NFData Identifier

-- | Haskell types can be qualified by adding a (possibly empty) list
-- of predicates, or class constraints, to restrict the ways in which
-- type variables are instantiated.
instance (NFData (t i), NFData typ, NFData i) => NFData (Qualified t i typ)


data Qualified t i typ = Qualified
  { qualifiedPredicates :: ![Predicate t i]
  , qualifiedType :: !typ
  } deriving (Eq, Show , Generic, Data, Typeable)

-- | One of potentially many predicates.
instance (NFData (t i), NFData i) => NFData (Predicate t i)


data Predicate t i =
  IsIn i [t i]
  deriving (Eq, Show , Generic, Data, Typeable)

-- | A simple Haskell type.
instance (NFData i) => NFData (Type i)


data Type i
  = VariableType (TypeVariable i)
  | ConstructorType (TypeConstructor i)
  | ApplicationType (Type i) (Type i)
  deriving (Eq, Show, Generic, Data, Typeable)

-- | Kind of a type.
instance NFData (Kind)
data Kind
  = StarKind
  | FunctionKind Kind Kind
  deriving (Eq, Ord, Show, Generic, Data, Typeable)

instance NFData (Location)
data Location = Location
  { locationStartLine :: !Int
  , locationStartColumn :: !Int
  , locationEndLine :: !Int
  , locationEndColumn :: !Int
  } deriving (Show, Generic, Data, Typeable, Eq)

-- | A Haskell expression.
instance (NFData (t i),  NFData l,NFData i) => NFData (Expression t  i l)


data Expression (t :: * -> *) i l
  = VariableExpression l i
  | ConstructorExpression l i
  | ConstantExpression l Identifier
  | LiteralExpression l Literal
  | ApplicationExpression l (Expression t i l) (Expression t i l)
  | InfixExpression l (Expression t i l) (String, Expression t i l) (Expression t i l)
  | LetExpression l (BindGroup t i l) (Expression t i l)
  | LambdaExpression l (Alternative t i l)
  | IfExpression l (Expression t i l) (Expression t i l) (Expression t i l)
  | CaseExpression l (Expression t i l) [CaseAlt t i l]
  | ParensExpression l (Expression t i l)
  deriving (Show, Generic, Data, Typeable, Functor, Traversable, Foldable, Eq)

instance (NFData (t i),  NFData l,NFData i) => NFData (CaseAlt t  i l)


data CaseAlt t i l = CaseAlt
  { caseAltLabel :: l
  , caseAltPattern :: Pattern t i l
  , caseAltExpression :: Expression t i l
  } deriving (Show, Generic, Data, Typeable, Functor, Traversable, Foldable, Eq)

expressionLabel :: Expression t i l -> l
expressionLabel =
  \case
     LiteralExpression l _ -> l
     ConstantExpression l _ -> l
     ApplicationExpression l _ _ -> l
     InfixExpression l _ _ _ -> l
     LetExpression l _ _ -> l
     LambdaExpression l _ -> l
     IfExpression l _ _ _ -> l
     CaseExpression l _ _ -> l
     VariableExpression l _ -> l
     ConstructorExpression l _ -> l
     ParensExpression l _ -> l

-- | A pattern match.
instance (NFData l,NFData i) => NFData (Pattern t  i l)


data Pattern (t :: * -> *) i l
  = VariablePattern l i
  | WildcardPattern l String
  | AsPattern l i (Pattern t i l)
  | LiteralPattern l Literal
  | ConstructorPattern l i [Pattern t i l]
  | BangPattern (Pattern t i l)
  deriving (Show, Generic, Data, Typeable , Eq , Functor, Traversable, Foldable)

patternLabel :: Pattern ty t t1 -> t1
patternLabel (VariablePattern loc _) = loc
patternLabel (ConstructorPattern loc _ _) = loc
patternLabel (WildcardPattern l _) = l
patternLabel (AsPattern l  _ _) = l
patternLabel (LiteralPattern l _) =l
patternLabel (BangPattern p) = patternLabel p

instance NFData (Literal)
data Literal
  = IntegerLiteral Integer
  | CharacterLiteral Char
  | RationalLiteral Rational
  | StringLiteral String
  deriving (Show, Generic, Data, Typeable, Eq)

-- | A class.
instance (NFData (t i), NFData l,NFData i) => NFData (Class t  i l)

data Class (t :: * -> *) i l = Class
  { classTypeVariables :: ![TypeVariable i]
  , classSuperclasses :: ![Predicate t i]
  , classInstances :: ![Instance t i l]
  , className :: i
  , classMethods :: Map i (Scheme t i t)
  } deriving (Show, Generic, Data, Typeable, Traversable, Foldable, Functor)

-- | Class instance.
instance (NFData (t i),  NFData l,NFData i) => NFData (Instance t i l)


data Instance (t :: * -> *) i l = Instance
  { instancePredicate :: !(Scheme t i (Predicate t))
  , instanceDictionary :: !(Dictionary t i l)
  } deriving (Show, Generic, Data, Typeable, Traversable, Foldable, Functor)

instanceClassName :: Instance t1 i t -> i
instanceClassName (Instance (Forall _ (Qualified _ (IsIn x _))) _) = x

-- | A dictionary for a class.
instance (NFData (t i),  NFData l,NFData i) => NFData (Dictionary t i l)

data Dictionary (t :: * -> *) i l = Dictionary
  { dictionaryName :: i
  , dictionaryMethods :: Map i (l, Alternative t i l)
  } deriving (Show, Generic, Data, Typeable, Functor, Traversable, Foldable, Eq)



-- | A type constructor.
instance (NFData i) => NFData (TypeConstructor i)

data TypeConstructor i = TypeConstructor
  { typeConstructorIdentifier :: !i
  , typeConstructorKind :: !Kind
  } deriving (Eq, Show, Generic, Data, Typeable)

-- | A type scheme.
instance (NFData (typ i), NFData (t i), NFData i) => NFData (Scheme t i typ)


data Scheme t i typ =
  Forall [TypeVariable i] (Qualified t i (typ i))
  deriving (Eq, Show, Generic, Data, Typeable)

instance (NFData a) => NFData (Result a)


data Result a
  = OK a
  | Fail
  deriving (Show, Generic, Data, Typeable, Functor)

instance Semigroup a => Semigroup (Result a) where
  Fail <> _ = Fail
  _ <> Fail = Fail
  OK x <> OK y = OK (x <> y)

data Match t i l
  = Success [(i, Expression t i l)]
  | NeedsMoreEval [Int]
  deriving (Eq, Show, Functor)

instance Semigroup (Match t i l) where
  NeedsMoreEval is <> _ = NeedsMoreEval is
  _ <> NeedsMoreEval is = NeedsMoreEval is
  Success xs <> Success ys = Success (xs <> ys)

class Identifiable i where
  identifyValue :: MonadThrow m => i -> m Identifier
  identifyType :: MonadThrow m => i -> m Identifier
  identifyClass :: MonadThrow m => i -> m Identifier
  nonrenamableName :: i -> Maybe Name

instance Identifiable Identifier where
  identifyValue = pure
  identifyType = pure
  identifyClass = pure
  nonrenamableName _ = Nothing

instance Identifiable Name where
  identifyValue =
    \case
      ValueName _ i -> pure (Identifier i)
      ConstructorName _ c -> pure (Identifier c)
      DictName _ i -> pure (Identifier i)
      MethodName _ i -> pure (Identifier i)
      PrimopName {} -> error "identifyValue PrimopName"
      n -> throwM (TypeAtValueScope n)
  identifyType =
    \case
      TypeName _ i -> pure (Identifier i)
      n -> throwM (RenamerNameMismatch n)
  identifyClass =
    \case
      ClassName _ i -> pure (Identifier i)
      n -> throwM (RenamerNameMismatch n)
  nonrenamableName n =
    case n of
      ValueName {} -> Nothing
      ConstructorName {} -> pure n
      TypeName {} -> pure n
      ForallName {} -> pure n
      DictName {} -> pure n
      ClassName {} -> pure n
      MethodName {} -> pure n
      PrimopName {} -> pure n

-- | Context for the type checker.
instance (NFData (t i),NFData l,  NFData i) => NFData (Context t i l)

data Context t i l = Context
  { contextSpecialSigs :: SpecialSigs i
  , contextSpecialTypes :: SpecialTypes i
  , contextSignatures :: [TypeSignature t i i]
  , contextScope :: Map Identifier i
  , contextTypeClasses :: Map i (Class t i (TypeSignature t i l))
  , contextDataTypes :: [DataType t i]
  } deriving (Show, Generic, Data, Typeable)

-- | Builtin context.
instance (NFData l,NFData (t i), NFData i) => NFData (Builtins t i l)

data Builtins t i l = Builtins
  { builtinsSpecialSigs :: SpecialSigs i
  , builtinsSpecialTypes :: SpecialTypes i
  , builtinsSignatures :: [TypeSignature t i i]
  , builtinsTypeClasses :: Map i (Class t i l)
  } deriving (Show, Generic, Data, Typeable, Traversable, Foldable, Functor)

data Token
  = If
  | Imply
  | Then
  | Data
  | ForallToken
  | Else
  | Case
  | Where
  | Of
  | Backslash
  | Let
  | In
  | RightArrow
  | OpenParen
  | CloseParen
  | Equals
  | Colons
  | Variable !Text
  | Constructor !Text
  | Character !Char
  | String !Text
  | Operator !Text
  | Period
  | Comma
  | Integer !Integer
  | Decimal !Double
  | NonIndentedNewline
  | Bar
  | ClassToken
  | InstanceToken
  | Bang
  deriving (Eq, Ord)

data Specials n = Specials
  { specialsSigs :: SpecialSigs n
  , specialsTypes :: SpecialTypes n
  }
