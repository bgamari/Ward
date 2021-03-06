{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Types where

import Algebra.Algebra
import Control.Concurrent.Chan (Chan, writeChan)
import Control.Monad.IO.Class (MonadIO(..))
import qualified Data.Aeson as A
import Data.Foldable (fold)
import Data.HashSet (HashSet)
import Data.HashMap.Strict (HashMap)
import Data.Hashable (Hashable(..))
import Data.Map.Strict (Map)
import Data.Monoid ((<>), Endo(..))
import qualified Data.Semigroup
import Data.Semigroup (Semigroup)
import Data.Text (Text)
import GHC.Exts (IsString(..))
import GHC.Generics (Generic)
import Language.C.Data.Ident (Ident(..))
import Language.C.Data.Node (NodeInfo(..))
import Language.C.Data.Position (posFile, posRow)
import Language.C.Syntax.AST -- *
import qualified Language.C.Parser as CParser
import qualified Data.HashMap.Strict as HashMap
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Sequence
import qualified Data.Text as Text

import Orphans ()

--------------------------------------------------------------------------------
-- Permissions
--------------------------------------------------------------------------------

-- | A permission is a label on a function describing the operations it's
-- allowed to perform.
newtype PermissionName = PermissionName Text
  deriving (Eq, Hashable, IsString, Ord)
  deriving newtype (A.FromJSON, A.ToJSON)

instance Show PermissionName where
  show (PermissionName name) = Text.unpack name

-- | A permission action is a pair of an action and a permission, such as
-- @grant(foo)@. An action describes the effect on the context before and after
-- a call to a function.
--
-- * @'Need' p@: The function indirectly needs @p@ because it calls other
--   functions that need or use @p@.
--
-- * @'Use' p@: The function directly needs @p@ because it makes use of the fact
--   that the permission is available. For example @use(locked)@ implies that
--   the function directly performs operations that require some lock held.
--
-- * @'Grant' p@: The function adds @p@ to the context; before the call, the
--   context 'Lacks' @p@, and afterward, it 'Has' @p@.
--
-- * @'Revoke' p@: The function removes @p@ from the context; before the call,
--   the context 'Has' @p@, and afterward, it 'Lacks' @p@.
--
-- * @'Deny' p@: The function cannot operate if @p@ is in the context. This
--   should never be necessary, but may be used to assert invariants and produce
--   better diagnostics.
--
-- * @'Waive' p@: If a permission @p@ was declared @implicit@ in the config
--   file, then it's implicitly granted to all functions unless they explicitly
--   'Waive' it.
--
data PermissionAction
  = Need !PermissionName
  | Use !PermissionName
  | Grant !PermissionName
  | Revoke !PermissionName
  | Deny !PermissionName
  | Waive !PermissionName
  deriving (Eq, Generic, Ord)

instance A.ToJSON PermissionAction
instance A.FromJSON PermissionAction

instance Show PermissionAction where
  show = \ case
    Need p -> concat ["need(", show p, ")"]
    Use p -> concat ["use(", show p, ")"]
    Grant p -> concat ["grant(", show p, ")"]
    Revoke p -> concat ["revoke(", show p, ")"]
    Deny p -> concat ["deny(", show p, ")"]
    Waive p -> concat ["waive(", show p, ")"]

instance Hashable PermissionAction

permissionActionName :: PermissionAction -> PermissionName
permissionActionName = \case
  Need n -> n
  Use n -> n
  Grant n -> n
  Revoke n -> n
  Deny n -> n
  Waive n -> n

-- | A set of permission actions. This is what a Ward annotation in a source
-- file represents.
--
type PermissionActionSet = HashSet PermissionAction

-- | Information about permissions before and after a given call site. These are
-- used during permission checking, inferred from 'PermissionAction's and the
-- 'CallTree' of each function.
--
-- The permission information present at each site is a product of two
-- lattices: the 'Usage' lattice and the 'Capability' lattice.
--
-- Usage tracks the intrinsic consumption of permissions (ie, those call sites
-- that make use of a permission (e.g. a call to lock a mutex intrinsically
-- uses the lock permission).  Usage is a simple binary lattice:
--
-- @
--               Uses
--                |
--                |
--            UsageUnknown (==bottom)
-- @
--
-- Capability tracks the potential to make use of a permisson.
--
-- * @'CapHas'@: This call site has access to permission @p@. This appears when a
--   call @need@s @p@, before it @revoke@s @p@, or after it @grant@s @p@.
--
-- * @'CapLacks'@: This call site does not have access to permission @p@. This
--   appears after a call @revoke@s @p@, or before it @grant@s @p@.
--
-- * @'CapConflict'@: This call site was inferred to have conflicting
--   information about @p@, that is, both 'Has' and 'Lacks' were inferred. All
--   'Conflicts' are reported as errors after checking.
--
-- * @'CapUnknown'@: We don't know anything about this call site yet.
--
-- Capability forms a diamon lattice:
--
-- @
--             CapConflict (== top)
--              /      \\
--             /        \\
--         CapHas     CapLacks
--             \\        /
--              \\      /
--             CapUnknown (== bottom)
-- @
--
--
-- 'PermissionPresence' is a product 'BoundedJoinSemiLattice' (ie, @'bottom' ==
-- 'PermissionPresence' bottom bottom@, similarly for top, and meets and joins
-- are taken componentwise.)
data PermissionPresence = PermissionPresence
  { presenceUsage :: !Usage
  , presenceCapability :: !Capability
  }
  deriving (Eq, Generic)

instance Show PermissionPresence where
  show p =
    let
      showUsage UsageUnknown = ""
      showUsage Uses = "&uses"
    in case p of
      PermissionPresence UsageUnknown CapHas -> "has"
      PermissionPresence Uses CapHas -> "uses"
      PermissionPresence u CapLacks -> "lacks" ++ showUsage u
      PermissionPresence u CapConflict -> "conflicts" ++ showUsage u
      PermissionPresence u CapUnknown -> "unknown" ++ showUsage u

instance JoinSemiLattice PermissionPresence where
  PermissionPresence u c \/ PermissionPresence u' c' = PermissionPresence (u \/ u') (c \/ c')

instance BoundedJoinSemiLattice PermissionPresence where
  bottom = PermissionPresence bottom bottom

instance MeetSemiLattice PermissionPresence where
  PermissionPresence u c /\ PermissionPresence u' c' = PermissionPresence (u /\ u') (c /\ c')

-- | See 'PermissionPresence'
data Usage = UsageUnknown | Uses
  deriving (Eq, Ord, Generic, Show)

instance JoinSemiLattice Usage where
  (\/) = max

instance BoundedJoinSemiLattice Usage where
  bottom = UsageUnknown

instance MeetSemiLattice Usage where
  (/\) = min

-- | See 'PermisisonPresence'
data Capability = CapUnknown | CapHas | CapLacks | CapConflict
  deriving (Eq, Generic, Show)

instance JoinSemiLattice Capability where
  c          \/ c' | c == c' = c
  CapUnknown \/ c            = c
  c          \/ CapUnknown   = c
  _          \/ _            = CapConflict

instance BoundedJoinSemiLattice Capability where
  bottom = CapUnknown

instance MeetSemiLattice Capability where
  c           /\ c' | c == c' = c
  CapConflict /\ c            = c
  c           /\ CapConflict  = c
  _           /\ _            = CapUnknown


instance PartialOrd Usage where
  leq = joinLeq

instance PartialOrd Capability where
  leq = joinLeq

instance PartialOrd PermissionPresence where
  leq = joinLeq

instance Hashable Usage

instance Hashable Capability

instance Hashable PermissionPresence

has :: PermissionPresence
has = PermissionPresence bottom CapHas

lacks :: PermissionPresence
lacks = PermissionPresence bottom CapLacks

uses :: PermissionPresence
uses = PermissionPresence Uses bottom

conflicts :: PermissionPresence
conflicts = PermissionPresence bottom CapConflict

-- | Convenience function for testing whether we found a conflict.
conflicting :: PermissionPresence -> Bool
conflicting p = presenceCapability p == CapConflict

-- | A mapping from permission names to permission presences; each call site
-- has one of these.
--
-- The 'PermissionPresenceSet' enjoys a lattice structure that derives
-- pointwise from the lattice structucture on 'PermissonPresence' - the order
-- is given by keyset inclusion and when keys are present in both maps, the
-- corresponding values must be ordered with respect to the
-- 'PermissionPresence' 'PartialOrd'.  The bottom element is the empty set.
--
-- (Note we don't derive 'Monoid' instances because the underlying 'HashMap'
-- 'Monoid' instance has a non-commutative ('<>') operation which we never want
-- to use - we always want ('\/'))
newtype PermissionPresenceSet =
  PermissionPresenceSet
  {
    unPermissionPresenceSet :: HashMap PermissionName PermissionPresence
  }
  deriving (Eq, JoinSemiLattice, BoundedJoinSemiLattice)

-- | Given a 'PermissionName' look up its presence in the given
-- 'PermissionPresenceSet' or 'bottom' if its not in the set.
lookupPresence :: PermissionName -> PermissionPresenceSet -> PermissionPresence
lookupPresence pn = HashMap.lookupDefault bottom pn . unPermissionPresenceSet

-- | Given a 'PermissionName' and a modification function,
-- update the 'PermissionPresenceSet' with the modified presence.
-- 
-- * If the presence was previously not in the set, the modification function will be passed 'bottom'.
-- * If the modification function returns 'bottom', the element is /not/ removed.
modifyPresence :: PermissionName -> (PermissionPresence -> PermissionPresence) -> PermissionPresenceSet -> PermissionPresenceSet
modifyPresence pn f =
  PermissionPresenceSet . HashMap.alter f' pn . unPermissionPresenceSet
  where
    f' Nothing = Just $ f bottom
    f' (Just p) = Just $ f p

-- | Construct a 'PermissionPresenceSet' mapping the single element 
singletonPresence
  :: PermissionName -> PermissionPresence -> PermissionPresenceSet
singletonPresence pn = PermissionPresenceSet . HashMap.singleton pn

-- | Get the 'PermisionName's from the given 'PermissionPresenceSet
presenceKeys :: PermissionPresenceSet -> [PermissionName]
presenceKeys = HashMap.keys . unPermissionPresenceSet

-- | Keep just the 'conflicting' elements of the 'PermissionPresenceSet'
conflictingPresence :: PermissionPresenceSet -> PermissionPresenceSet
conflictingPresence =
  PermissionPresenceSet . HashMap.filter conflicting . unPermissionPresenceSet

-- | Return @True@ iff the given 'PermissionPresenceSet' is empty.
nullPresence :: PermissionPresenceSet -> Bool
nullPresence = HashMap.null . unPermissionPresenceSet


--------------------------------------------------------------------------------
-- Call graphs
--------------------------------------------------------------------------------

-- | Built from a collection of translation units, a 'NameMap' describes where a
-- function came from, its definition (if available), and the permission actions
-- described by its annotations.
--
type NameMap = Map Ident (NodeInfo, Maybe CFunDef, PermissionActionSet)

-- | Built from a 'NameMap', a 'CallMap' contains a compact 'CallTree' for each
-- function instead of the whole definition.
--
newtype CallMap = CallMap { getCallMap :: Map Ident (NodeInfo, CallSequence Ident, PermissionActionSet) }
  deriving (Generic)

instance Show CallMap where
  show (CallMap m) = unlines
    [ unlines [ showIdent ident <> ": "
              , show nodeInfo
              , show perms
              , show (fmap showIdent callTree)
              ]
    | (ident, (nodeInfo, callTree, perms)) <- Map.assocs m
    ]
    where showIdent (Ident s _ _) = s

instance Monoid CallMap where
  mempty = CallMap mempty
  mappend = (<>)

instance Semigroup CallMap where
  CallMap x <> CallMap y =
      CallMap $ Map.unionWith mergeCallMapItems x y
    where
      mergeCallMapItems (n1, c1, p1) (_n2, c2, p2) =
          (n1, c, p1 <> p2)
        where
          c | not (nullCallSequence c1) && not (nullCallSequence c2) =
              if c1 /= c2
              then error $ "Multiple definitions of "++show n1
              else c1
            | nullCallSequence c1 = c2
            | otherwise = c1

instance A.FromJSON CallMap
instance A.ToJSON CallMap

-- | A 'CallTree' describes the calls that a function makes in its definition. A
--
-- 'Choice' refers to functions that are called in different branches of an @if@
-- or @?:@, such as:
--
-- > // [ Call "foo", Choice [Call "bar"] [Call "baz"] ] :: CallSequence
-- > if (foo ()) {
-- >   bar ();
-- > } else {
-- >   baz ();
-- > }
--
-- Since we don't statically know which branch will be taken, choices are
-- handled during checking by checking each branch of the choice and then
-- merging their effects on the context.
--
data CallTree a
  = Choice !(CallSequence a) !(CallSequence a)
  | Call !a
  -- Abort  - the Monoid identity for 'CallTree' with respect to the 'Choice' operator
  deriving (Eq, Foldable, Functor, Traversable, Generic)

instance A.ToJSON ident => A.ToJSON (CallTree ident)
instance A.FromJSON ident => A.FromJSON (CallTree ident)

instance (Show a) => Show (CallTree a) where
  showsPrec p = \ case
    Choice a b -> showParen (p > choicePrec)
      $ showsPrec choicePrec a . showString " | " . showsPrec choicePrec b
    Call ident -> shows ident
    where
      choicePrec = 0

newtype CallSequence a
  = CallSequence (Sequence.Seq (CallTree a))
  deriving (Eq, Semigroup, Monoid, Foldable, Functor, Traversable, Generic)

instance A.ToJSON a => A.ToJSON (CallSequence a)
instance A.FromJSON a => A.FromJSON (CallSequence a)

instance (Show a) => Show (CallSequence a) where
  showsPrec p (CallSequence ts) =
    showParen (p > sequencePrec)
    $ appEndo $ fold
    $ Sequence.intersperse (Endo $ showString " ; ")
    $ fmap (Endo . showsPrec sequencePrec) ts
    where
      sequencePrec = 1


callSequenceLength :: CallSequence a -> Int
callSequenceLength (CallSequence ts) = length ts

callSequenceIndex :: Int -> CallSequence a -> CallTree a
callSequenceIndex index (CallSequence ts) = Sequence.index ts index

nullCallSequence :: CallSequence a -> Bool
nullCallSequence (CallSequence ts) = Sequence.null ts

singletonCallSequence :: CallTree a -> CallSequence a
singletonCallSequence = CallSequence . Sequence.singleton

viewlCallSequence :: CallSequence a -> Maybe (CallTree a, CallSequence a)
viewlCallSequence (CallSequence ts) =
  case Sequence.viewl ts of
    (t Sequence.:< ts') -> Just (t, CallSequence ts')
    Sequence.EmptyL -> Nothing

-- | Traverse the @CallTree a@ elements of a @CallSequence b@
--
-- This is a @Traversal@ in the sense of the lens library (although we do not depend on lens)
-- @
--   callTreesOfCallSequence :: Traversal (CallSequence a) (CallSequence b) (CallTree a) (CallTree b)
-- @
callTreesOfCallSequence :: Applicative f => (CallTree a -> f (CallTree b)) -> CallSequence a -> f (CallSequence b)
callTreesOfCallSequence f (CallSequence ts) = CallSequence <$> traverse f ts

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

-- | An error that may occur while parsing a callmap graph file.
type CallMapParseError = String

-- | An error parsing one of the processing units.  Either a C parse error or a CallMapParseError
data ProcessingUnitParseError =
  CSourceUnitParseError CParser.ParseError
  | CallMapUnitParseError CallMapParseError
  deriving (Show)

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------

-- | An entry in the output, consisting of an error category, source location,
-- and error message. 'Error' is for fatal errors; 'Warning' for non-fatal
-- errors; and 'Note' for additional context or explanation.
data Entry
  = Note !NodeInfo !Text
  | Warning !NodeInfo !Text
  | Error !NodeInfo !Text
  deriving (Eq)

posPrefix :: NodeInfo -> String
posPrefix (OnlyPos pos _) = concat
  [ posFile pos
  , ":"
  , show $ posRow pos
  ]
posPrefix (NodeInfo pos _ _) = concat
  [ posFile pos
  , ":"
  , show $ posRow pos
  ]

-- | A logger monad, providing access to a channel where entries can be sent
-- using 'record'. Sending @'Just' e@ for some entry @e@ should record the
-- entry, while sending @Nothing@ should close the channel.
newtype Logger a = Logger { runLogger :: Chan (Maybe Entry) -> IO a }

instance Functor Logger where
  fmap f (Logger g) = Logger $ fmap f . g

instance Applicative Logger where
  pure = Logger . const . return
  Logger f <*> Logger g = Logger (\ entries -> f entries <*> g entries)

instance Monad Logger where
  Logger f >>= g = Logger
    $ \ entries -> flip runLogger entries . g =<< f entries

instance MonadIO Logger where
  liftIO = Logger . const

-- | Sends an entry to the logging channel. The Boolean argument indicates
-- whether to send a message, which could be used to conveniently control
-- logging levels, like so:
--
-- > record (logLevel >= Debug) $ Note pos "Frobnicating..."
--
record :: Bool -> Entry -> Logger ()
record False _ = return ()
record True entry = Logger $ \ entries -> writeChan entries $ Just entry

-- | Closes the logging channel.
endLog :: Logger ()
endLog = Logger $ \ entries -> writeChan entries Nothing

-- | The Ward output mode: 'CompilerOutput' is for generating compiler-style
-- output, prefixing log entries with source location info:
--
-- > /path/to/file:line:column: message
--
-- 'HtmlOutput' is for generating an HTML report.
data OutputMode
  = CompilerOutput
  | HtmlOutput
  deriving (Eq)

-- | The Ward output action:
--
--   * 'AnalysisAction' runs the analyses with results formatted according to
--     the given 'OutputMode'.
--
--   * 'GraphAction' simply parses the C sources and emits the inferred call
--     graph.
data OutputAction
  = AnalysisAction !OutputMode
  | GraphAction
  deriving (Eq)

-- | Format an 'Entry' according to an 'OutputMode'.
format :: OutputMode -> Entry -> String

format CompilerOutput entry = case entry of
  Note p t -> concat [posPrefix p, ": note: ", Text.unpack t, "\n"]
  Warning p t -> concat [posPrefix p, ": warning: ", Text.unpack t, "\n"]
  Error p t -> concat [posPrefix p, ": error: ", Text.unpack t, "\n"]

-- TODO: Convert position to URL for hyperlinked output.
format HtmlOutput entry = case entry of
  Note _ t -> row "note" t
  Warning _ t -> row "warning" t
  Error _ t -> row "error" t
  where
    row category text = concat
      ["<li class='", category, "'>", Text.unpack text, "</li>"]

-- | The header to output before entries for a given 'OutputMode'.
formatHeader :: OutputMode -> String
formatHeader CompilerOutput = ""
formatHeader HtmlOutput = "\
  \<html>\n\
  \<head>\n\
  \<title>Ward Report</title>\n\
  \</head>\n\
  \<body>\n\
  \<ul>\n\
  \\&"

-- | The footer to output after entries for a given 'OutputMode'.
formatFooter :: OutputMode -> String -> String
formatFooter CompilerOutput extra = extra <> "\n"
formatFooter HtmlOutput extra = "\
  \</ul>\n\
  \\&" <> extra <> "\n\
  \</body>\n\
  \</html>\n\
  \\&"

-- | Partitions a list of entries into lists of notes, warnings, and errors.
partitionEntries
  :: [Entry]
  -> ([(NodeInfo, Text)], [(NodeInfo, Text)], [(NodeInfo, Text)])
partitionEntries = go mempty
  where
    go (ns, ws, es) = \ case
      Note a b : rest -> go ((a, b) : ns, ws, es) rest
      Warning a b : rest -> go (ns, (a, b) : ws, es) rest
      Error a b : rest -> go (ns, ws, (a, b) : es) rest
      [] -> (reverse ns, reverse ws, reverse es)

-- | Why a particular permission action is being applied.
data Reason
  = NoReason !NodeInfo
  | BecauseCall !Ident


instance Show Reason where
  show = \ case
    NoReason _ -> "unspecified reason"
    BecauseCall (Ident name _ _) -> concat ["call to '", name, "'"]

reasonPos :: Reason -> NodeInfo
reasonPos (NoReason pos) = pos
reasonPos (BecauseCall (Ident _ _ pos)) = pos

type FunctionName = Text

--------------------------------------------------------------------------------
-- Configuration files
--------------------------------------------------------------------------------

-- | A 'Config' consists of a set of permission declarations and a set of
-- enforcements. This is parsed from a user-specified file; see @Config.hs@.
data Config = Config
  { configDeclarations :: !(Map PermissionName Declaration)
  , configEnforcements :: [Enforcement]
  } deriving (Eq, Show)

-- Multiple configs may be merged.
instance Data.Semigroup.Semigroup Config where
  (Config declA enfA) <> (Config declB enfB) = Config
    (Map.unionWith (<>) declA declB)
    (enfA <> enfB)

instance Monoid Config where
  mempty = Config mempty mempty
  mappend = (Data.Semigroup.<>)

-- | A 'Declaration' describes a permission that the user wants to check. It may
-- be @implicit@, in which case it is granted by default to every function that
-- does not explicitly 'Waive' it; it may have a human-readable 'Description' of
-- its purpose, such as @"permission to assume the foo lock is held"@; and it
-- may have additional 'Restriction's relating it to other permissions.
data Declaration = Declaration
  { declImplicit :: !Bool
  , declDescription :: !(Maybe Description)
  , declRestrictions :: [(Expression, Maybe Description)]
  } deriving (Eq, Show)

instance Data.Semigroup.Semigroup Declaration where
  a <> b = Declaration
    { declImplicit = declImplicit a || declImplicit b
    , declDescription = case (declDescription a, declDescription b) of
      (Just da, Just db) -> Just (da <> "; " <> db)
      (da@Just{}, Nothing) -> da
      (Nothing, db@Just{}) -> db
      _ -> Nothing
    , declRestrictions = declRestrictions a <> declRestrictions b
    }

instance Monoid Declaration where
  mempty = Declaration False Nothing mempty
  mappend = (Data.Semigroup.<>)

-- | A 'Restriction', declared in a config file, describes /relationships/
-- between permissions. For instance, a user might write a restriction like this
-- in their config:
--
-- > lock "permission to take the lock"
-- >   -> !locked "cannot take the lock recursively";
--
-- Then if the user attempts to use a function that would take the lock
-- recursively, Ward will report that this restriction has been violated.
--
-- If the /condition/ part of a restriction is present in the context, and the
-- /expression/ part evaluates to false in the context, then the violated
-- restriction is reported along with the human-readable /description/ if any.
--
data Restriction = Restriction
  { restName :: !PermissionName
  , restExpression :: !Expression
  , restDescription :: !(Maybe Description)
  }


instance Show Restriction where
  show r = case restDescription r of
    Just desc -> concat
      [ "\""
      , Text.unpack desc
      , "\" ("
      , implication
      , ")"
      ]
    Nothing -> implication
    where
      implication = concat
        [ "uses("
        , show $ restName r
        , ") -> "
        , show $ restExpression r
        ]

-- | An 'Expression' is an assertion about the presence of some permission in
-- the context ('Context') or a combination of these using Boolean operations
-- 'And', 'Or', and 'Not'.
data Expression
  = Context !PermissionName !PermissionPresence
  | !Expression `And` !Expression
  | !Expression `Or` !Expression
  | Not !Expression
  deriving (Eq)

-- These allow expressions to be used infix in Haskell code for readability.
infixr 3 `And`
infixr 2 `Or`

instance IsString Expression where
  fromString = flip Context has . fromString

instance Show Expression where
  showsPrec p = \ case
    Context nm presence -> shows presence . showParen True (shows nm)
    a `And` b -> showParen (p > andPrec)
      $ showsPrec andPrec a . showString " & " . showsPrec andPrec b
    a `Or` b -> showParen (p > orPrec)
      $ showsPrec orPrec a . showString " & " . showsPrec orPrec b
    Not a -> showParen (p > notPrec)
      $ showString "!" . showsPrec notPrec a
    where
    andPrec = 3
    orPrec = 2
    notPrec = 10

-- | An 'Enforcement', declared in a config file, describes the functions that
-- Ward will force to be fully annotated. It may be:
--
-- * @EnforcePath path@: enforce annotations for all functions declared or
--   defined in a path ending with @path@. (E.g., a public header.)
--
-- * @'EnforceFunction' name@: enforce annotations for all functions named
--   @name@. (E.g., a particular private function.)
--
-- * @'EnforcePathFunction' path name@ enforce annotations for a function named
--   @name@ only if declared or defined in the given @path@. (E.g., @static@
--   functions with non-unique names.)
--
data Enforcement = EnforcePath FilePath
                 | EnforceFunction FunctionName
                 | EnforcePathFunction FilePath FunctionName
                 deriving (Eq, Show)

-- | A description is just an arbitrary docstring read from a config file.
type Description = Text
