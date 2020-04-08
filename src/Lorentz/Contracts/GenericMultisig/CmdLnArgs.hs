{-# OPTIONS -Wno-partial-fields -Wno-orphans #-}

module Lorentz.Contracts.GenericMultisig.CmdLnArgs where

import Control.Monad (Monad(..))
import Control.Applicative
import Text.Show (Show(..))
import Data.List
import Data.Eq
import Data.Either
import Data.Function (id)
import Data.Functor
import Prelude (FilePath, IO, Ord(..), print, putStrLn)
import Data.String (String)
import Data.Maybe
import Data.Typeable
import Data.Type.Bool

import Lorentz hiding (checkSignature, get)
import Michelson.Parser
import Michelson.Typed.Annotation
import Michelson.Typed.Haskell.Value
import Michelson.Typed.Scope
import Michelson.Typed.Sing
import Michelson.Typed.T
import Michelson.Typed.Value
import Michelson.Typed.Instr
import Michelson.Typed.EntryPoints hiding (parseEpAddress)
import Util.IO
import qualified Michelson.Untyped.Type as U
import Tezos.Crypto (checkSignature)
import qualified Michelson.TypeCheck.Types as TypeCheck
import Michelson.Macro
import Michelson.TypeCheck.Instr

import qualified Options.Applicative as Opt
import qualified Data.Text as T
import qualified Data.Text.Lazy.IO as TL
import qualified Data.ByteString.Base16 as Base16
import Data.Constraint
import Data.Singletons
import Text.Megaparsec (parse)

import Lorentz.Contracts.GenericMultisig.Parsers
import Michelson.Typed.Value.Missing
import Michelson.Typed.Sing.Missing
-- import Lorentz.Contracts.Util ()
import Lorentz.Contracts.SomeContractParam
import Lorentz.Contracts.SomeContractStorage
-- import Lorentz.Contracts.Parse
import qualified Lorentz.Contracts.GenericMultisig.Wrapper as G (parseTypeCheckValue)

import qualified Lorentz.Contracts.GenericMultisig as GenericMultisig
import qualified Lorentz.Contracts.GenericMultisig.Type as GenericMultisig

-- unsafeRootContractRef ::

-- | Assume that the given `EpAddress` points to the contract root
unsafeRootContractRef :: ParameterScope cp => EpAddress -> ContractRef (Value cp)
unsafeRootContractRef EpAddress{..} =
  ContractRef eaAddress $
  SomeEpc $ EntryPointCall
  { epcName = eaEntryPoint
  , epcParamProxy = Proxy
  , epcLiftSequence = EplArgHere
  }



instance (SingI t) => ParameterHasEntryPoints (Value t) where
  type ParameterEntryPointsDerivation (Value t) = EpdNone

-- unsafeIfEq :: Proxy b -> Proxy x -> If b x x :~: x

-- valueContractRef :: forall cp. Address -> ContractRef (Value cp)
-- valueContractRef addr' = _ (toTAddress @(Value cp) addr') -- CallDefault

-- instance IsoCValue (Value ('Tc ct)) where
--   type ToCT (Value ('Tc ct)) = ct
--   toCVal (VC xs) = xs
--   fromCVal = VC

-- type IsComparable c = ToT c ~ 'Tc (ToCT c)
assertIsComparable ::
     forall (t :: T) a. SingI t
  => (( IsComparable (Value t)
      , SingI (ToCT (Value t))
      , Typeable (ToCT (Value t))
      ) =>
        a)
  -> a
assertIsComparable f =
  case sing @t of
    STc _ -> f
    _ -> error "assertIsComparable"

data CmdLnArgs
  = PrintSpecialized
      { parameterType :: SomeSing T
      , outputPath :: Maybe FilePath
      , oneline :: Bool
      }
  | PrintWrapped
      { contractToWrap :: TypeCheck.SomeContract
      , outputPath :: Maybe FilePath
      , oneline :: Bool
      }
  | InitSpecialized
      { threshold :: Natural
      , signerKeys :: [PublicKey]
      }
  | InitWrapped
      { targetStorage :: SomeContractStorage
      , threshold :: Natural
      , signerKeys :: [PublicKey]
      }
  | GetCounterSpecialized
      { storageText :: Text
      , signerKeys :: [PublicKey]
      }
  | GetCounterWrapped
      { storageType :: SomeSing T
      , storageText :: Text
      , signerKeys :: [PublicKey]
      }
  | ChangeKeysMultisig
      { threshold :: Natural
      , newSignerKeys :: [PublicKey]
      , targetContract :: EpAddress
      , multisigContract :: Address
      , counter :: Natural
      , signatures :: Maybe [Maybe Signature]
      , signerKeys :: [PublicKey]
      }
  | RunMultisig
      { contractParameter :: SomeContractParam
      , targetContract :: EpAddress
      , multisigContract :: Address
      , counter :: Natural
      , signatures :: Maybe [Maybe Signature]
      , signerKeys :: [PublicKey]
      }

argParser :: Opt.Parser CmdLnArgs
argParser = Opt.hsubparser $ mconcat
  [ printSpecializedSubCmd
  , printWrappedSubCmd
  , initSpecializedSubCmd
  , initWrappedSubCmd
  , getCounterSpecializedSubCmd
  , getCounterWrappedSubCmd
  , changeKeysMultisigSubCmd
  , runMultisigSubCmd
  ]
  where
    mkCommandParser commandName parser desc =
      Opt.command commandName $
      Opt.info (Opt.helper <*> parser) $
      Opt.progDesc desc

    printSpecializedSubCmd =
      mkCommandParser "print-specialized"
      (PrintSpecialized <$> parseSomeT "parameter" <*> outputOptions <*> onelineOption)
      "Dump the Specialized Multisig contract in form of Michelson code"

    printWrappedSubCmd =
      mkCommandParser "print-specialized"
      (PrintWrapped <$>
        parseSomeContract "contractToWrap" <*>
        outputOptions <*>
        onelineOption
      )
      "Dump the Wrapped Multisig contract in form of Michelson code"

    initSpecializedSubCmd =
      mkCommandParser "init-specialized"
      (InitSpecialized <$>
        parseNatural "threshold" <*>
        parseSignerKeys "signerKeys"
      )
      "Dump the intial storage for the Specialized Multisig contract"

    initWrappedSubCmd =
      mkCommandParser "init-specialized"
      (InitWrapped <$>
        parseSomeContractStorage "targetStorage" <*>
        parseNatural "threshold" <*>
        parseSignerKeys "signerKeys"
      )
      "Dump the intial storage for the Wrapped Multisig contract"

    getCounterSpecializedSubCmd =
      mkCommandParser "get-counter-specialized"
      (GetCounterSpecialized <$>
        fmap T.pack (parseString "storageText") <*>
        parseSignerKeys "signerKeys"
      )
      ("Parse the storage for the Specialized Multisig contract, " <>
       "ensure the 'signerKeys' match, " <>
       "and return the current counter")

    getCounterWrappedSubCmd =
      mkCommandParser "get-counter-specialized"
      (GetCounterWrapped <$>
        parseSomeT "storage" <*>
        fmap T.pack (parseString "storageText") <*>
        parseSignerKeys "signerKeys"
      )
      ("Parse the storage for the Wrapped Multisig contract, " <>
       "ensure the 'signerKeys' match, " <>
       "and return the current counter")

    changeKeysMultisigSubCmd =
      mkCommandParser "change-keys-multisig"
      (ChangeKeysMultisig <$>
        parseNatural "threshold" <*>
        parseSignerKeys "newSignerKeys" <*>
        parseEpAddress "target-contract" <*>
        parseAddress "multisig-contract" <*>
        parseNatural "counter" <*>
        parseSignatures "signatures" <*>
        parseSignerKeys "signerKeys"
      )
      "Dump the change keys parameter for the Specialized or Wrapped Multisig contract"

    runMultisigSubCmd =
      mkCommandParser "run-multisig"
      (RunMultisig <$>
        parseSomeContractParam "target-parameter" <*>
        parseEpAddress "target-contract" <*>
        parseAddress "multisig-contract" <*>
        parseNatural "counter" <*>
        parseSignatures "signatures" <*>
        parseSignerKeys "signerKeys"
      )
      "Dump the run operation parameter for the Specialized or Wrapped Multisig contract"


infoMod :: Opt.InfoMod CmdLnArgs
infoMod = mconcat
  [ Opt.fullDesc
  , Opt.progDesc "Multisig contract CLI interface"
  ]

runCmdLnArgs :: CmdLnArgs -> IO ()
runCmdLnArgs = \case
  PrintSpecialized (SomeSing (st :: Sing t)) mOutput forceOneLine' ->
    withDict (singIT st) $
    withDict (singTypeableT st) $
    assertOpAbsense @t $
    assertBigMapAbsense @t $
    assertNestedBigMapsAbsense @t $
    maybe TL.putStrLn writeFileUtf8 mOutput $
    printLorentzContract forceOneLine' $
    GenericMultisig.specializedMultisigContract @(Value t) @PublicKey
  PrintWrapped wrappedContract mOutput oneline ->
    case wrappedContract of
      TypeCheck.SomeContract wrappedContractFC ->
        case wrappedContractFC of
          FullContract wrappedContractCode (_ :: ParamNotes cp) (_ :: Notes st) ->
            assertBigMapAbsense @cp $
            maybe TL.putStrLn writeFileUtf8 mOutput $
            printLorentzContract oneline $
            GenericMultisig.genericMultisigContractWrapper @(Value cp) @(Value st) @PublicKey
            (I wrappedContractCode)
  InitSpecialized {..} ->
    if threshold > genericLength signerKeys
       then error "threshold is greater than the number of signer keys"
       else TL.putStrLn $
         printLorentzValue @(GenericMultisig.Storage PublicKey) forceOneLine $
         ( GenericMultisig.initialMultisigCounter
         , ( threshold
           , signerKeys
           )
         )
  InitWrapped (SomeContractStorage (initialWrappedStorage :: Value st)) threshold' signerKeys' ->
    TL.putStrLn $
    withDict (singTypeableT (sing @st)) $
    printLorentzValue @(Value st, GenericMultisig.Storage PublicKey) forceOneLine $
    ( initialWrappedStorage
    , ( GenericMultisig.initialMultisigCounter
      , ( threshold'
        , signerKeys'
        )
      )
    )
  GetCounterSpecialized {..} ->
    let parsedStorage = parseNoEnv
          (G.parseTypeCheckValue @(ToT (GenericMultisig.Storage PublicKey)))
          "specialized-multisig"
          storageText
     in let (storedCounter, (_threshold, storedSignerKeys)) =
              either
                (error . T.pack . show)
                (fromVal @(GenericMultisig.Storage PublicKey))
                parsedStorage
         in if storedSignerKeys == signerKeys
               then print storedCounter
               else do
                 putStrLn @Text "Stored signer keys:"
                 print signerKeys
                 error "Stored signer keys do not match provided signer keys"
  GetCounterWrapped (SomeSing (st :: Sing t)) storageText' signerKeys' ->
    withDict (singIT st) $
    withDict (singTypeableT st) $
    let parsedStorage = parseNoEnv
          (G.parseTypeCheckValue @(ToT (Value t, GenericMultisig.Storage PublicKey)))
          "specialized-multisig"
          storageText'
     in let (_, (storedCounter, (_threshold, storedSignerKeys))) =
              either
                (error . T.pack . show)
                (fromVal @(Value t, GenericMultisig.Storage PublicKey))
                parsedStorage
         in if storedSignerKeys == signerKeys'
               then print storedCounter
               else do
                 putStrLn @Text "Stored signer keys:"
                 print signerKeys'
                 error "Stored signer keys do not match provided signer keys"
  ChangeKeysMultisig {..} ->
    let changeKeysParam = (counter, GenericMultisig.ChangeKeys @PublicKey @((), ContractRef ()) (threshold, newSignerKeys)) in
    if threshold > genericLength newSignerKeys
       then error "threshold is greater than the number of signer keys"
       else
       case signatures of
         Nothing -> print . ("0x" <>) . Base16.encode . lPackValue . asPackType @((), ContractRef ()) $ (toAddress targetContract, changeKeysParam)
         Just someSignatures ->
            if checkSignaturesValid (toAddress targetContract, changeKeysParam) $ zip signerKeys someSignatures
               then
                 TL.putStrLn $
                 printLorentzValue @(GenericMultisig.MainParams PublicKey ((), ContractRef ())) forceOneLine $
                 asParameterType $
                 (changeKeysParam, someSignatures)
               else error "invalid signature(s) provided"
  RunMultisig {..} ->
    case contractParameter of
      SomeContractParam (param :: Value cp) _ (Dict, Dict) ->
        assertNestedBigMapsAbsense @cp $
        let runParam =
              ( counter
              , GenericMultisig.Operation
                  @PublicKey
                  @(Value cp, ContractRef (Value cp))
                  (param, unsafeRootContractRef @cp targetContract))
         in case signatures of
              Nothing -> print . ("0x" <>) . Base16.encode . lPackValue . asPackType @(Value cp, ContractRef (Value cp)) $ (multisigContract, runParam)
              Just someSignatures ->
                if checkSignaturesValid (multisigContract, runParam) $ zip signerKeys someSignatures
                   then
                     TL.putStrLn $
                     printLorentzValue @(GenericMultisig.MainParams PublicKey (Value cp, ContractRef (Value cp))) forceOneLine $
                     asParameterType $
                     (runParam, someSignatures)
                   else error "invalid signature(s) provided"
  where
    forceOneLine = True

    asParameterType :: forall cp. GenericMultisig.MainParams PublicKey cp -> GenericMultisig.MainParams PublicKey cp
    asParameterType = id

    asPackType :: forall cp. (Address, (Natural, GenericMultisig.GenericMultisigAction PublicKey cp)) -> (Address, (Natural, GenericMultisig.GenericMultisigAction PublicKey cp))
    asPackType = id

checkSignaturesValid :: NicePackedValue cp => (Address, (Natural, GenericMultisig.GenericMultisigAction PublicKey (cp, ContractRef cp))) -> [(PublicKey, Maybe Signature)] -> Bool
checkSignaturesValid = all . checkSignatureValid

checkSignatureValid :: NicePackedValue cp => (Address, (Natural, GenericMultisig.GenericMultisigAction PublicKey (cp, ContractRef cp))) -> (PublicKey, Maybe Signature) -> Bool
checkSignatureValid _ (_, Nothing) = True
checkSignatureValid xs (pubKey, Just sig) = checkSignature pubKey sig (lPackValue xs)

