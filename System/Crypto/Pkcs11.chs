{-# LANGUAGE ForeignFunctionInterface #-}
module System.Crypto.Pkcs11 (
    -- * Library
    Library,
    loadLibrary,

    -- ** Reading library information
    Version,
    versionMajor,
    versionMinor,
    Info,
    getInfo,
    infoCryptokiVersion,
    infoManufacturerId,
    infoFlags,
    infoLibraryDescription,
    infoLibraryVersion,

    -- * Slots
    SlotId,
    getSlotList,

    -- ** Reading slot information
    SlotInfo,
    getSlotInfo,
    slotInfoDescription,
    slotInfoManufacturerId,
    slotInfoFlags,
    slotInfoHardwareVersion,
    slotInfoFirmwareVersion,

    -- ** Reading token information
    TokenInfo,
    getTokenInfo,
    tokenInfoLabel,
    tokenInfoManufacturerId,
    tokenInfoModel,
    tokenInfoSerialNumber,
    tokenInfoFlags,

    -- * Mechanisms
    MechType(RsaPkcsKeyPairGen,RsaPkcs,AesEcb,AesCbc,AesMac,AesMacGeneral,AesCbcPad,AesCtr),
    MechInfo,
    getMechanismList,
    getMechanismInfo,
    mechInfoMinKeySize,
    mechInfoMaxKeySize,
    mechInfoFlags,

    -- * Session management
    Session,
    UserType(User,SecurityOfficer,ContextSpecific),
    withSession,
    login,
    logout,

    -- * Object attributes
    ObjectHandle,
    Attribute(Class,Label,KeyType,Modulus,ModulusBits,PublicExponent,Token,Decrypt),
    ClassType(PrivateKey,SecretKey),
    KeyTypeValue(RSA,DSA,DH,ECDSA,EC,AES),
    -- ** Searching objects
    findObjects,
    -- ** Reading object attributes
    getModulus,
    getPublicExponent,
    getDecryptFlag,

    -- * Key generation
    generateKeyPair,

    -- * Key wrapping/unwrapping
    unwrapKey,

    -- * Encryption/decryption
    decrypt,
    encrypt,
) where
import Foreign
import Foreign.Marshal.Utils
import Foreign.Marshal.Alloc
import Foreign.C
import Foreign.Ptr
import System.Posix.DynamicLinker
import Control.Monad
import Control.Exception
import qualified Data.ByteString.UTF8 as BU8
import qualified Data.ByteString as BS
import Data.ByteString.Unsafe

#include "pkcs11import.h"

{-
 Currently cannot use c2hs structure alignment and offset detector since it does not support pragma pack
 which is required by PKCS11, which is using 1 byte packing
 https://github.com/haskell/c2hs/issues/172
-}

_serialSession = {#const CKF_SERIAL_SESSION#} :: Int
_rwSession = {#const CKF_RW_SESSION#} :: Int

rsaPkcsKeyPairGen = {#const CKM_RSA_PKCS_KEY_PAIR_GEN#} :: Int

type ObjectHandle = {#type CK_OBJECT_HANDLE#}
type SlotId = Int
type Rv = {#type CK_RV#}
type CK_BYTE = {#type CK_BYTE#}
type CK_FLAGS = {#type CK_FLAGS#}
type GetFunctionListFunPtr = {#type CK_C_GetFunctionList#}
type GetSlotListFunPtr = {#type CK_C_GetSlotList#}
type NotifyFunPtr = {#type CK_NOTIFY#}
type SessionHandle = {#type CK_SESSION_HANDLE#}

{#pointer *CK_FUNCTION_LIST as FunctionListPtr#}
{#pointer *CK_INFO as InfoPtr -> Info#}
{#pointer *CK_SLOT_INFO as SlotInfoPtr -> SlotInfo#}
{#pointer *CK_TOKEN_INFO as TokenInfoPtr -> TokenInfo#}
{#pointer *CK_ATTRIBUTE as LlAttributePtr -> LlAttribute#}
{#pointer *CK_MECHANISM_INFO as MechInfoPtr -> MechInfo#}
{#pointer *CK_MECHANISM as MechPtr -> Mech#}

-- defined this one manually because I don't know how to make c2hs to define it yet
type GetFunctionListFun = (C2HSImp.Ptr (FunctionListPtr)) -> (IO C2HSImp.CULong)

foreign import ccall unsafe "dynamic"
  getFunctionList'_ :: GetFunctionListFunPtr -> GetFunctionListFun

data Version = Version {
    versionMajor :: Int,
    versionMinor :: Int
} deriving (Show)

instance Storable Version where
  sizeOf _ = {#sizeof CK_VERSION#}
  alignment _ = {#alignof CK_VERSION#}
  peek p = Version
    <$> liftM fromIntegral ({#get CK_VERSION->major#} p)
    <*> liftM fromIntegral ({#get CK_VERSION->minor#} p)
  poke p x = do
    {#set CK_VERSION->major#} p (fromIntegral $ versionMajor x)
    {#set CK_VERSION->minor#} p (fromIntegral $ versionMinor x)

data Info = Info {
    infoCryptokiVersion :: Version,
    infoManufacturerId :: String,
    infoFlags :: Int,
    infoLibraryDescription :: String,
    infoLibraryVersion :: Version
} deriving (Show)

instance Storable Info where
  sizeOf _ = (2+32+4+32+10+2)
  alignment _ = 1
  peek p = do
    ver <- peek (p `plusPtr` {#offsetof CK_INFO->cryptokiVersion#}) :: IO Version
    manufacturerId <- peekCStringLen ((p `plusPtr` 2), 32)
    flags <- (\ptr -> do {C2HSImp.peekByteOff ptr (2+32) :: IO C2HSImp.CULong}) p
    --flags <- {#get CK_INFO->flags#} p
    libraryDescription <- peekCStringLen ((p `plusPtr` (2+32+4+10)), 32)
    --libraryDescription <- {# get CK_INFO->libraryDescription #} p
    libVer <- peek (p `plusPtr` (2+32+4+32+10)) :: IO Version
    return Info {infoCryptokiVersion=ver,
                 infoManufacturerId=manufacturerId,
                 infoFlags=fromIntegral flags,
                 infoLibraryDescription=libraryDescription,
                 infoLibraryVersion=libVer
                 }


peekInfo :: Ptr Info -> IO Info
peekInfo ptr = peek ptr


data SlotInfo = SlotInfo {
    slotInfoDescription :: String,
    slotInfoManufacturerId :: String,
    slotInfoFlags :: Int,
    slotInfoHardwareVersion :: Version,
    slotInfoFirmwareVersion :: Version
} deriving (Show)

instance Storable SlotInfo where
  sizeOf _ = (64+32+4+2+2)
  alignment _ = 1
  peek p = do
    description <- peekCStringLen ((p `plusPtr` 0), 64)
    manufacturerId <- peekCStringLen ((p `plusPtr` 64), 32)
    flags <- C2HSImp.peekByteOff p (64+32) :: IO C2HSImp.CULong
    hwVer <- peek (p `plusPtr` (64+32+4)) :: IO Version
    fwVer <- peek (p `plusPtr` (64+32+4+2)) :: IO Version
    return SlotInfo {slotInfoDescription=description,
                     slotInfoManufacturerId=manufacturerId,
                     slotInfoFlags=fromIntegral flags,
                     slotInfoHardwareVersion=hwVer,
                     slotInfoFirmwareVersion=fwVer
                     }


data TokenInfo = TokenInfo {
    tokenInfoLabel :: String,
    tokenInfoManufacturerId :: String,
    tokenInfoModel :: String,
    tokenInfoSerialNumber :: String,
    tokenInfoFlags :: Int--,
    --tokenInfoHardwareVersion :: Version,
    --tokenInfoFirmwareVersion :: Version
} deriving (Show)

instance Storable TokenInfo where
    sizeOf _ = (64+32+4+2+2)
    alignment _ = 1
    peek p = do
        label <- peekCStringLen ((p `plusPtr` 0), 32)
        manufacturerId <- peekCStringLen ((p `plusPtr` 32), 32)
        model <- peekCStringLen ((p `plusPtr` (32+32)), 16)
        serialNumber <- peekCStringLen ((p `plusPtr` (32+32+16)), 16)
        flags <- C2HSImp.peekByteOff p (32+32+16+16) :: IO C2HSImp.CULong
        --hwVer <- peek (p `plusPtr` (64+32+4)) :: IO Version
        --fwVer <- peek (p `plusPtr` (64+32+4+2)) :: IO Version
        return TokenInfo {tokenInfoLabel=label,
                          tokenInfoManufacturerId=manufacturerId,
                          tokenInfoModel=model,
                          tokenInfoSerialNumber=serialNumber,
                          tokenInfoFlags=fromIntegral flags--,
                          --tokenInfoHardwareVersion=hwVer,
                          --tokenInfoFirmwareVersion=fwVer
                          }


data MechInfo = MechInfo {
    mechInfoMinKeySize :: Int,
    mechInfoMaxKeySize :: Int,
    mechInfoFlags :: Int
} deriving (Show)

instance Storable MechInfo where
  sizeOf _ = {#sizeof CK_MECHANISM_INFO#}
  alignment _ = 1
  peek p = MechInfo
    <$> liftM fromIntegral ({#get CK_MECHANISM_INFO->ulMinKeySize#} p)
    <*> liftM fromIntegral ({#get CK_MECHANISM_INFO->ulMaxKeySize#} p)
    <*> liftM fromIntegral ({#get CK_MECHANISM_INFO->flags#} p)
  poke p x = do
    {#set CK_MECHANISM_INFO->ulMinKeySize#} p (fromIntegral $ mechInfoMinKeySize x)
    {#set CK_MECHANISM_INFO->ulMaxKeySize#} p (fromIntegral $ mechInfoMaxKeySize x)
    {#set CK_MECHANISM_INFO->flags#} p (fromIntegral $ mechInfoFlags x)


data Mech = Mech {
    mechType :: MechType,
    mechParamPtr :: Ptr (),
    mechParamSize :: Int
}

instance Storable Mech where
    sizeOf _ = {#sizeof CK_MECHANISM_TYPE#} + {#sizeof CK_VOID_PTR#} + {#sizeof CK_ULONG#}
    alignment _ = 1
    poke p x = do
        poke (p `plusPtr` 0) (fromEnum $ mechType x)
        poke (p `plusPtr` {#sizeof CK_MECHANISM_TYPE#}) (mechParamPtr x :: {#type CK_VOID_PTR#})
        poke (p `plusPtr` ({#sizeof CK_MECHANISM_TYPE#} + {#sizeof CK_VOID_PTR#})) (mechParamSize x)



{#fun unsafe CK_FUNCTION_LIST.C_Initialize as initialize
 {`FunctionListPtr',
  alloca- `()' } -> `Rv' fromIntegral#}

{#fun unsafe CK_FUNCTION_LIST.C_GetInfo as getInfo'
 {`FunctionListPtr',
  alloca- `Info' peekInfo* } -> `Rv' fromIntegral#}


getSlotList' functionListPtr active num = do
  alloca $ \arrayLenPtr -> do
    poke arrayLenPtr (fromIntegral num)
    allocaArray num $ \array -> do
      res <- {#call unsafe CK_FUNCTION_LIST.C_GetSlotList#} functionListPtr (fromBool active) array arrayLenPtr
      arrayLen <- peek arrayLenPtr
      slots <- peekArray (fromIntegral arrayLen) array
      return (fromIntegral res, slots)


{#fun unsafe CK_FUNCTION_LIST.C_GetSlotInfo as getSlotInfo'
  {`FunctionListPtr',
   `Int',
   alloca- `SlotInfo' peek* } -> `Rv' fromIntegral
#}


{#fun unsafe CK_FUNCTION_LIST.C_GetTokenInfo as getTokenInfo'
  {`FunctionListPtr',
   `Int',
   alloca- `TokenInfo' peek* } -> `Rv' fromIntegral
#}


openSession' functionListPtr slotId flags =
  alloca $ \slotIdPtr -> do
    res <- {#call unsafe CK_FUNCTION_LIST.C_OpenSession#} functionListPtr (fromIntegral slotId) (fromIntegral flags) nullPtr nullFunPtr slotIdPtr
    slotId <- peek slotIdPtr
    return (fromIntegral res, fromIntegral slotId)


{#fun unsafe CK_FUNCTION_LIST.C_CloseSession as closeSession'
 {`FunctionListPtr',
  `CULong' } -> `Rv' fromIntegral#}


{#fun unsafe CK_FUNCTION_LIST.C_Finalize as finalize
 {`FunctionListPtr',
  alloca- `()' } -> `Rv' fromIntegral#}


getFunctionList :: GetFunctionListFunPtr -> IO ((Rv), (FunctionListPtr))
getFunctionList getFunctionListPtr =
  alloca $ \funcListPtrPtr -> do
    res <- (getFunctionList'_ getFunctionListPtr) funcListPtrPtr
    funcListPtr <- peek funcListPtrPtr
    return (fromIntegral res, funcListPtr)


findObjectsInit' functionListPtr session attribs = do
    _withAttribs attribs $ \attribsPtr -> do
        res <- {#call unsafe CK_FUNCTION_LIST.C_FindObjectsInit#} functionListPtr session attribsPtr (fromIntegral $ length attribs)
        return (fromIntegral res)


findObjects' functionListPtr session maxObjects = do
  alloca $ \arrayLenPtr -> do
    poke arrayLenPtr (fromIntegral 0)
    allocaArray maxObjects $ \array -> do
      res <- {#call unsafe CK_FUNCTION_LIST.C_FindObjects#} functionListPtr session array (fromIntegral maxObjects) arrayLenPtr
      arrayLen <- peek arrayLenPtr
      objectHandles <- peekArray (fromIntegral arrayLen) array
      return (fromIntegral res, objectHandles)


{#fun unsafe CK_FUNCTION_LIST.C_FindObjectsFinal as findObjectsFinal'
 {`FunctionListPtr',
  `CULong' } -> `Rv' fromIntegral#}


{#enum define UserType {CKU_USER as User, CKU_SO as SecurityOfficer, CKU_CONTEXT_SPECIFIC as ContextSpecific} deriving (Eq) #}


_login :: FunctionListPtr -> SessionHandle -> UserType -> BU8.ByteString -> IO (Rv)
_login functionListPtr session userType pin = do
    unsafeUseAsCStringLen pin $ \(pinPtr, pinLen) -> do
        res <- {#call unsafe CK_FUNCTION_LIST.C_Login#} functionListPtr session (fromIntegral $ fromEnum userType) (castPtr pinPtr) (fromIntegral pinLen)
        return (fromIntegral res)


_generateKeyPair :: FunctionListPtr -> SessionHandle -> MechType -> [Attribute] -> [Attribute] -> IO (Rv, ObjectHandle, ObjectHandle)
_generateKeyPair functionListPtr session mechType pubAttrs privAttrs = do
    alloca $ \pubKeyHandlePtr -> do
        alloca $ \privKeyHandlePtr -> do
            alloca $ \mechPtr -> do
                poke mechPtr (Mech {mechType = mechType, mechParamPtr = nullPtr, mechParamSize = 0})
                _withAttribs pubAttrs $ \pubAttrsPtr -> do
                    _withAttribs privAttrs $ \privAttrsPtr -> do
                        res <- {#call unsafe CK_FUNCTION_LIST.C_GenerateKeyPair#} functionListPtr session mechPtr pubAttrsPtr (fromIntegral $ length pubAttrs) privAttrsPtr (fromIntegral $ length privAttrs) pubKeyHandlePtr privKeyHandlePtr
                        pubKeyHandle <- peek pubKeyHandlePtr
                        privKeyHandle <- peek privKeyHandlePtr
                        return (fromIntegral res, fromIntegral pubKeyHandle, fromIntegral privKeyHandle)



_getMechanismList :: FunctionListPtr -> Int -> Int -> IO (Rv, [Int])
_getMechanismList functionListPtr slotId maxMechanisms = do
    alloca $ \arrayLenPtr -> do
        poke arrayLenPtr (fromIntegral maxMechanisms)
        allocaArray maxMechanisms $ \array -> do
            res <- {#call unsafe CK_FUNCTION_LIST.C_GetMechanismList#} functionListPtr (fromIntegral slotId) array arrayLenPtr
            arrayLen <- peek arrayLenPtr
            objectHandles <- peekArray (fromIntegral arrayLen) array
            return (fromIntegral res, map (fromIntegral) objectHandles)


{#fun unsafe CK_FUNCTION_LIST.C_GetMechanismInfo as _getMechanismInfo
  {`FunctionListPtr',
   `Int',
   `Int',
   alloca- `MechInfo' peek* } -> `Rv' fromIntegral
#}


rvToStr :: Rv -> String
rvToStr {#const CKR_OK#} = "ok"
rvToStr {#const CKR_ARGUMENTS_BAD#} = "bad arguments"
rvToStr {#const CKR_ATTRIBUTE_READ_ONLY#} = "attribute is read-only"
rvToStr {#const CKR_ATTRIBUTE_TYPE_INVALID#} = "invalid attribute type specified in template"
rvToStr {#const CKR_ATTRIBUTE_VALUE_INVALID#} = "invalid attribute value specified in template"
rvToStr {#const CKR_BUFFER_TOO_SMALL#} = "buffer too small"
rvToStr {#const CKR_CRYPTOKI_NOT_INITIALIZED#} = "cryptoki not initialized"
rvToStr {#const CKR_DATA_INVALID#} = "data invalid"
rvToStr {#const CKR_DEVICE_ERROR#} = "device error"
rvToStr {#const CKR_DEVICE_MEMORY#} = "device memory"
rvToStr {#const CKR_DEVICE_REMOVED#} = "device removed"
rvToStr {#const CKR_DOMAIN_PARAMS_INVALID#} = "invalid domain parameters"
rvToStr {#const CKR_ENCRYPTED_DATA_INVALID#} = "encrypted data is invalid"
rvToStr {#const CKR_ENCRYPTED_DATA_LEN_RANGE#} = "encrypted data length not in range"
rvToStr {#const CKR_FUNCTION_CANCELED#} = "function canceled"
rvToStr {#const CKR_FUNCTION_FAILED#} = "function failed"
rvToStr {#const CKR_GENERAL_ERROR#} = "general error"
rvToStr {#const CKR_HOST_MEMORY#} = "host memory"
rvToStr {#const CKR_KEY_FUNCTION_NOT_PERMITTED#} = "key function not permitted"
rvToStr {#const CKR_KEY_HANDLE_INVALID#} = "key handle invalid"
rvToStr {#const CKR_KEY_SIZE_RANGE#} = "key size range"
rvToStr {#const CKR_KEY_TYPE_INCONSISTENT#} = "key type inconsistent"
rvToStr {#const CKR_MECHANISM_INVALID#} = "invalid mechanism"
rvToStr {#const CKR_MECHANISM_PARAM_INVALID#} = "invalid mechanism parameter"
rvToStr {#const CKR_OPERATION_ACTIVE#} = "there is already an active operation in-progress"
rvToStr {#const CKR_OPERATION_NOT_INITIALIZED#} = "operation was not initialized"
rvToStr {#const CKR_PIN_EXPIRED#} = "PIN is expired, you need to setup a new PIN"
rvToStr {#const CKR_PIN_INCORRECT#} = "PIN is incorrect, authentication failed"
rvToStr {#const CKR_PIN_LOCKED#} = "PIN is locked, authentication failed"
rvToStr {#const CKR_SESSION_CLOSED#} = "session was closed in a middle of operation"
rvToStr {#const CKR_SESSION_COUNT#} = "session count"
rvToStr {#const CKR_SESSION_HANDLE_INVALID#} = "session handle is invalid"
rvToStr {#const CKR_SESSION_PARALLEL_NOT_SUPPORTED#} = "parallel session not supported"
rvToStr {#const CKR_SESSION_READ_ONLY#} = "session is read-only"
rvToStr {#const CKR_SESSION_READ_ONLY_EXISTS#} = "read-only session exists, SO cannot login"
rvToStr {#const CKR_SESSION_READ_WRITE_SO_EXISTS#} = "read-write SO session exists"
rvToStr {#const CKR_SLOT_ID_INVALID#} = "slot id invalid"
rvToStr {#const CKR_TEMPLATE_INCOMPLETE#} = "provided template is incomplete"
rvToStr {#const CKR_TEMPLATE_INCONSISTENT#} = "provided template is inconsistent"
rvToStr {#const CKR_TOKEN_NOT_PRESENT#} = "token not present"
rvToStr {#const CKR_TOKEN_NOT_RECOGNIZED#} = "token not recognized"
rvToStr {#const CKR_TOKEN_WRITE_PROTECTED#} = "token is write protected"
rvToStr {#const CKR_UNWRAPPING_KEY_HANDLE_INVALID#} = "unwrapping key handle invalid"
rvToStr {#const CKR_UNWRAPPING_KEY_SIZE_RANGE#} = "unwrapping key size not in range"
rvToStr {#const CKR_UNWRAPPING_KEY_TYPE_INCONSISTENT#} = "unwrapping key type inconsistent"
rvToStr {#const CKR_USER_NOT_LOGGED_IN#} = "user needs to be logged in to perform this operation"
rvToStr {#const CKR_USER_ALREADY_LOGGED_IN#} = "user already logged in"
rvToStr {#const CKR_USER_ANOTHER_ALREADY_LOGGED_IN#} = "another user already logged in, first another user should be logged out"
rvToStr {#const CKR_USER_PIN_NOT_INITIALIZED#} = "user PIN not initialized, need to setup PIN first"
rvToStr {#const CKR_USER_TOO_MANY_TYPES#} = "cannot login user, somebody should logout first"
rvToStr {#const CKR_USER_TYPE_INVALID#} = "invalid value for user type"
rvToStr {#const CKR_WRAPPED_KEY_INVALID#} = "wrapped key invalid"
rvToStr {#const CKR_WRAPPED_KEY_LEN_RANGE#} = "wrapped key length not in range"
rvToStr rv = "unknown value for error " ++ (show rv)


-- Attributes

{#enum define ClassType {
    CKO_DATA as Data,
    CKO_CERTIFICATE as Certificate,
    CKO_PUBLIC_KEY as PublicKey,
    CKO_PRIVATE_KEY as PrivateKey,
    CKO_SECRET_KEY as SecretKey,
    CKO_HW_FEATURE as HWFeature,
    CKO_DOMAIN_PARAMETERS as DomainParameters,
    CKO_MECHANISM as Mechanism
} deriving (Show, Eq)
#}

{#enum define KeyTypeValue {
    CKK_RSA as RSA,
    CKK_DSA as DSA,
    CKK_DH as DH,
    CKK_ECDSA as ECDSA,
    CKK_EC as EC,
    CKK_AES as AES
    } deriving (Show, Eq) #}

{#enum define AttributeType {
    CKA_CLASS as ClassType,
    CKA_KEY_TYPE as KeyTypeType,
    CKA_LABEL as LabelType,
    CKA_MODULUS_BITS as ModulusBitsType,
    CKA_MODULUS as ModulusType,
    CKA_PUBLIC_EXPONENT as PublicExponentType,
    CKA_PRIVATE_EXPONENT as PrivateExponentType,
    CKA_PRIME_1 as Prime1Type,
    CKA_PRIME_2 as Prime2Type,
    CKA_EXPONENT_1 as Exponent1Type,
    CKA_EXPONENT_2 as Exponent2Type,
    CKA_COEFFICIENT as CoefficientType,
    CKA_TOKEN as TokenType,
    CKA_DECRYPT as DecryptType
    } deriving (Show, Eq) #}

data Attribute = Class ClassType
    | KeyType KeyTypeValue
    | Label String
    | ModulusBits Int
    | Token Bool
    | Decrypt Bool
    | Modulus Integer
    | PublicExponent Integer
    deriving (Show)

data LlAttribute = LlAttribute {
    attributeType :: AttributeType,
    attributeValuePtr :: Ptr (),
    attributeSize :: {#type CK_ULONG#}
}

instance Storable LlAttribute where
    sizeOf _ = {#sizeof CK_ATTRIBUTE_TYPE#} + {#sizeof CK_VOID_PTR#} + {#sizeof CK_ULONG#}
    alignment _ = 1
    poke p x = do
        poke (p `plusPtr` 0) (fromEnum $ attributeType x)
        poke (p `plusPtr` {#sizeof CK_ATTRIBUTE_TYPE#}) (attributeValuePtr x :: {#type CK_VOID_PTR#})
        poke (p `plusPtr` ({#sizeof CK_ATTRIBUTE_TYPE#} + {#sizeof CK_VOID_PTR#})) (attributeSize x)
    peek p = do
        attrType <- peek (p `plusPtr` 0) :: IO {#type CK_ATTRIBUTE_TYPE#}
        valPtr <- peek (p `plusPtr` {#sizeof CK_ATTRIBUTE_TYPE#})
        valSize <- peek (p `plusPtr` ({#sizeof CK_ATTRIBUTE_TYPE#} + {#sizeof CK_VOID_PTR#}))
        return $ LlAttribute (toEnum $ fromIntegral attrType) valPtr valSize


_attrType :: Attribute -> AttributeType
_attrType (Class _) = ClassType
_attrType (KeyType _) = KeyTypeType
_attrType (Label _) = LabelType
_attrType (ModulusBits _) = ModulusBitsType
_attrType (Token _) = TokenType


_valueSize :: Attribute -> Int
_valueSize (Class _) = {#sizeof CK_OBJECT_CLASS#}
_valueSize (KeyType _) = {#sizeof CK_KEY_TYPE#}
_valueSize (Label l) = BU8.length $ BU8.fromString l
_valueSize (ModulusBits _) = {#sizeof CK_ULONG#}
_valueSize (Token _) = {#sizeof CK_BBOOL#}


_pokeValue :: Attribute -> Ptr () -> IO ()
_pokeValue (Class c) ptr = poke (castPtr ptr :: Ptr {#type CK_OBJECT_CLASS#}) (fromIntegral $ fromEnum c)
_pokeValue (KeyType k) ptr = poke (castPtr ptr :: Ptr {#type CK_KEY_TYPE#}) (fromIntegral $ fromEnum k)
_pokeValue (Label l) ptr = unsafeUseAsCStringLen (BU8.fromString l) $ \(src, len) -> copyBytes ptr (castPtr src :: Ptr ()) len
_pokeValue (ModulusBits l) ptr = poke (castPtr ptr :: Ptr {#type CK_ULONG#}) (fromIntegral l :: {#type CK_KEY_TYPE#})
_pokeValue (Token b) ptr = poke (castPtr ptr :: Ptr {#type CK_BBOOL#}) (fromBool b :: {#type CK_BBOOL#})


_pokeValues :: [Attribute] -> Ptr () -> IO ()
_pokeValues [] p = return ()
_pokeValues (a:rem) p = do
    _pokeValue a p
    _pokeValues rem (p `plusPtr` (_valueSize a))


_valuesSize :: [Attribute] -> Int
_valuesSize attribs = foldr (+) 0 (map (_valueSize) attribs)


_makeLowLevelAttrs :: [Attribute] -> Ptr () -> [LlAttribute]
_makeLowLevelAttrs [] valuePtr = []
_makeLowLevelAttrs (a:rem) valuePtr =
    let valuePtr' = valuePtr `plusPtr` (_valueSize a)
        llAttr = LlAttribute {attributeType=_attrType a, attributeValuePtr=valuePtr, attributeSize=(fromIntegral $ _valueSize a)}
    in
        llAttr:(_makeLowLevelAttrs rem valuePtr')


_withAttribs :: [Attribute] -> (Ptr LlAttribute -> IO a) -> IO a
_withAttribs attribs f = do
    allocaBytes (_valuesSize attribs) $ \valuesPtr -> do
        _pokeValues attribs valuesPtr
        allocaArray (length attribs) $ \attrsPtr -> do
            pokeArray attrsPtr (_makeLowLevelAttrs attribs valuesPtr)
            f attrsPtr


_peekBigInt :: Ptr () -> CULong -> IO Integer
_peekBigInt ptr len = do
    arr <- peekArray (fromIntegral len) (castPtr ptr :: Ptr Word8)
    return $ foldl (\acc v -> (fromIntegral v) + (acc * 256)) 0 arr


_llAttrToAttr :: LlAttribute -> IO Attribute
_llAttrToAttr (LlAttribute ClassType ptr len) = do
    val <- peek (castPtr ptr :: Ptr {#type CK_OBJECT_CLASS#})
    return (Class $ toEnum $ fromIntegral val)
_llAttrToAttr (LlAttribute ModulusType ptr len) = do
    val <- _peekBigInt ptr len
    return (Modulus val)
_llAttrToAttr (LlAttribute PublicExponentType ptr len) = do
    val <- _peekBigInt ptr len
    return (PublicExponent val)
_llAttrToAttr (LlAttribute DecryptType ptr len) = do
    val <- peek (castPtr ptr :: Ptr {#type CK_BBOOL#})
    return $ Decrypt(val /= 0)


-- High level API starts here


data Library = Library {
    libraryHandle :: DL,
    functionListPtr :: FunctionListPtr
}


data Session = Session SessionHandle FunctionListPtr


loadLibrary :: String -> IO Library
loadLibrary libraryPath = do
    lib <- dlopen libraryPath []
    getFunctionListFunPtr <- dlsym lib "C_GetFunctionList"
    (rv, functionListPtr) <- getFunctionList getFunctionListFunPtr
    if rv /= 0
        then fail $ "failed to get list of functions " ++ (rvToStr rv)
        else do
            rv <- initialize functionListPtr
            if rv /= 0
                then fail $ "failed to initialize library " ++ (rvToStr rv)
                else return Library { libraryHandle = lib, functionListPtr = functionListPtr }


releaseLibrary lib = do
    rv <- finalize $ functionListPtr lib
    dlclose $ libraryHandle lib


getInfo :: Library -> IO Info
getInfo (Library _ functionListPtr) = do
    (rv, info) <- getInfo' functionListPtr
    if rv /= 0
        then fail $ "failed to get library information " ++ (rvToStr rv)
        else return info


getSlotList :: Library -> Bool -> Int -> IO [SlotId]
getSlotList (Library _ functionListPtr) active num = do
    (rv, slots) <- getSlotList' functionListPtr active num
    if rv /= 0
        then fail $ "failed to get list of slots " ++ (rvToStr rv)
        else return $ map (fromIntegral) slots


getSlotInfo :: Library -> SlotId -> IO SlotInfo
getSlotInfo (Library _ functionListPtr) slotId = do
    (rv, slotInfo) <- getSlotInfo' functionListPtr slotId
    if rv /= 0
        then fail $ "failed to get slot information " ++ (rvToStr rv)
        else return slotInfo


getTokenInfo :: Library -> SlotId -> IO TokenInfo
getTokenInfo (Library _ functionListPtr) slotId = do
    (rv, slotInfo) <- getTokenInfo' functionListPtr slotId
    if rv /= 0
        then fail $ "failed to get token information " ++ (rvToStr rv)
        else return slotInfo


_openSessionEx :: Library -> SlotId -> Int -> IO Session
_openSessionEx (Library _ functionListPtr) slotId flags = do
    (rv, sessionHandle) <- openSession' functionListPtr slotId flags
    if rv /= 0
        then fail $ "failed to open slot: " ++ (rvToStr rv)
        else return $ Session sessionHandle functionListPtr


_closeSessionEx :: Session -> IO ()
_closeSessionEx (Session sessionHandle functionListPtr) = do
    rv <- closeSession' functionListPtr sessionHandle
    if rv /= 0
        then fail $ "failed to close slot: " ++ (rvToStr rv)
        else return ()


withSession :: Library -> SlotId -> Bool -> (Session -> IO a) -> IO a
withSession lib slotId writable f = do
    let flags = if writable then _rwSession else 0
    bracket
        (_openSessionEx lib slotId (flags .|. _serialSession))
        (_closeSessionEx)
        (f)



_findObjectsInitEx :: Session -> [Attribute] -> IO ()
_findObjectsInitEx (Session sessionHandle functionListPtr) attribs = do
    rv <- findObjectsInit' functionListPtr sessionHandle attribs
    if rv /= 0
        then fail $ "failed to initialize search: " ++ (rvToStr rv)
        else return ()


_findObjectsEx :: Session -> IO [ObjectHandle]
_findObjectsEx (Session sessionHandle functionListPtr) = do
    (rv, objectsHandles) <- findObjects' functionListPtr sessionHandle 10
    if rv /= 0
        then fail $ "failed to execute search: " ++ (rvToStr rv)
        else return objectsHandles


_findObjectsFinalEx :: Session -> IO ()
_findObjectsFinalEx (Session sessionHandle functionListPtr) = do
    rv <- findObjectsFinal' functionListPtr sessionHandle
    if rv /= 0
        then fail $ "failed to finalize search: " ++ (rvToStr rv)
        else return ()


findObjects :: Session -> [Attribute] -> IO [ObjectHandle]
findObjects session attribs = do
    _findObjectsInitEx session attribs
    finally (_findObjectsEx session) (_findObjectsFinalEx session)


generateKeyPair :: Session -> MechType -> [Attribute] -> [Attribute] -> IO (ObjectHandle, ObjectHandle)
generateKeyPair (Session sessionHandle functionListPtr) mechType pubKeyAttrs privKeyAttrs = do
    (rv, pubKeyHandle, privKeyHandle) <- _generateKeyPair functionListPtr sessionHandle mechType pubKeyAttrs privKeyAttrs
    if rv /= 0
        then fail $ "failed to generate key pair: " ++ (rvToStr rv)
        else return (pubKeyHandle, privKeyHandle)


getObjectAttr :: Session -> ObjectHandle -> AttributeType -> IO Attribute
getObjectAttr (Session sessionHandle functionListPtr) objHandle attrType = do
    alloca $ \attrPtr -> do
        poke attrPtr (LlAttribute attrType nullPtr 0)
        rv <- {#call unsafe CK_FUNCTION_LIST.C_GetAttributeValue#} functionListPtr sessionHandle objHandle attrPtr 1
        attrWithLen <- peek attrPtr
        allocaBytes (fromIntegral $ attributeSize attrWithLen) $ \attrVal -> do
            poke attrPtr (LlAttribute attrType attrVal (attributeSize attrWithLen))
            rv <- {#call unsafe CK_FUNCTION_LIST.C_GetAttributeValue#} functionListPtr sessionHandle objHandle attrPtr 1
            if rv /= 0
                then fail $ "failed to get attribute: " ++ (rvToStr rv)
                else do
                    llAttr <- peek attrPtr
                    _llAttrToAttr llAttr


getDecryptFlag :: Session -> ObjectHandle -> IO Bool
getDecryptFlag sess objHandle = do
    (Decrypt v) <- getObjectAttr sess objHandle DecryptType
    return v

getModulus :: Session -> ObjectHandle -> IO Integer
getModulus sess objHandle = do
    (Modulus m) <- getObjectAttr sess objHandle ModulusType
    return m

getPublicExponent :: Session -> ObjectHandle -> IO Integer
getPublicExponent sess objHandle = do
    (PublicExponent v) <- getObjectAttr sess objHandle PublicExponentType
    return v


login :: Session -> UserType -> BU8.ByteString -> IO ()
login (Session sessionHandle functionListPtr) userType pin = do
    rv <- _login functionListPtr sessionHandle userType pin
    if rv /= 0
        then fail $ "login failed: " ++ (rvToStr rv)
        else return ()


logout :: Session -> IO ()
logout (Session sessionHandle functionListPtr) = do
    rv <- {#call unsafe CK_FUNCTION_LIST.C_Logout#} functionListPtr sessionHandle
    if rv /= 0
        then fail $ "logout failed: " ++ (rvToStr rv)
        else return ()


{#enum define MechType {
    CKM_RSA_PKCS_KEY_PAIR_GEN as RsaPkcsKeyPairGen,
    CKM_RSA_PKCS as RsaPkcs,
    CKM_RSA_9796 as Rsa9796,
    CKM_RSA_X_509 as RsaX509,
    CKM_MD2_RSA_PKCS               as Md2RsaPkcs,-- 0x00000004
    CKM_MD5_RSA_PKCS               as Md5RsaPkcs,-- 0x00000005
    CKM_SHA1_RSA_PKCS              as Sha1RsaPkcs,-- 0x00000006
    CKM_RIPEMD128_RSA_PKCS         as RipeMd128RsaPkcs,-- 0x00000007
    CKM_RIPEMD160_RSA_PKCS         as RipeMd160RsaPkcs,-- 0x00000008
    CKM_RSA_PKCS_OAEP              as RsaPkcsOaep,-- 0x00000009
    CKM_RSA_X9_31_KEY_PAIR_GEN     as RsaX931KeyPairGen,-- 0x0000000A
    CKM_RSA_X9_31                  as RsaX931,-- 0x0000000B
    CKM_SHA1_RSA_X9_31             as Sha1RsaX931,-- 0x0000000C
    CKM_RSA_PKCS_PSS               as RsaPkcsPss,-- 0x0000000D
    CKM_SHA1_RSA_PKCS_PSS          as Sha1RsaPkcsPss,-- 0x0000000E
    CKM_DSA_KEY_PAIR_GEN           as DsaKeyPairGen,-- 0x00000010
    CKM_DSA                        as Dsa,-- 0x00000011
    CKM_DSA_SHA1                   as DsaSha1,-- 0x00000012
    CKM_DH_PKCS_KEY_PAIR_GEN       as DhPkcsKeyPairGen,-- 0x00000020
    CKM_DH_PKCS_DERIVE             as DhPkcsDerive,-- 0x00000021
    CKM_X9_42_DH_KEY_PAIR_GEN      as X942DhKeyPairGen,-- 0x00000030
    CKM_X9_42_DH_DERIVE            as X942DhDerive,-- 0x00000031
    CKM_X9_42_DH_HYBRID_DERIVE     as X942DhHybridDerive,-- 0x00000032
    CKM_X9_42_MQV_DERIVE           as X942MqvDerive,-- 0x00000033
    CKM_SHA256_RSA_PKCS            as Sha256RsaPkcs,-- 0x00000040
    CKM_SHA384_RSA_PKCS            as Sha384RsaPkcs,-- 0x00000041
    CKM_SHA512_RSA_PKCS            as Sha512RsaPkcs,-- 0x00000042
    CKM_SHA256_RSA_PKCS_PSS        as Sha256RsaPkcsPss,-- 0x00000043
    CKM_SHA384_RSA_PKCS_PSS        as Sha384RsaPkcsPss,-- 0x00000044
    CKM_SHA512_RSA_PKCS_PSS        as Sha512RsaPkcsPss,-- 0x00000045

    -- SHA-224 RSA mechanisms are new for PKCS #11 v2.20 amendment 3
    CKM_SHA224_RSA_PKCS            as Sha224RsaPkcs,-- 0x00000046
    CKM_SHA224_RSA_PKCS_PSS        as Sha224RsaPkcsPss,-- 0x00000047

    CKM_RC2_KEY_GEN                as Rc2KeyGen,-- 0x00000100
    CKM_RC2_ECB                    as Rc2Ecb,-- 0x00000101
    CKM_RC2_CBC                    as Rc2Cbc,-- 0x00000102
    CKM_RC2_MAC                    as Rc2Mac,-- 0x00000103

    -- CKM_RC2_MAC_GENERAL and CKM_RC2_CBC_PAD are new for v2.0
    CKM_RC2_MAC_GENERAL            as Rc2MacGeneral,-- 0x00000104
    CKM_RC2_CBC_PAD                as Rc2CbcPad,--0x00000105

    CKM_RC4_KEY_GEN                as Rc4KeyGen,--0x00000110
    CKM_RC4                        as Rc4,--0x00000111
    CKM_DES_KEY_GEN                as DesKeyGen,--0x00000120
    CKM_DES_ECB                    as DesEcb,--0x00000121
    CKM_DES_CBC                    as DesCbc,--0x00000122
    CKM_DES_MAC                    as DesMac,--0x00000123

    -- CKM_DES_MAC_GENERAL and CKM_DES_CBC_PAD are new for v2.0
    CKM_DES_MAC_GENERAL            as DesMacGeneral,--0x00000124
    CKM_DES_CBC_PAD                as DesCbcPad,--0x00000125

    CKM_DES2_KEY_GEN               as Des2KeyGen,--0x00000130
    CKM_DES3_KEY_GEN               as Des3KeyGen,--0x00000131
    CKM_DES3_ECB                   as Des3Ecb,--0x00000132
    CKM_DES3_CBC                   as Des3Cbc,--0x00000133
    CKM_DES3_MAC                   as Des3Mac,--0x00000134

    -- CKM_DES3_MAC_GENERAL, CKM_DES3_CBC_PAD, CKM_CDMF_KEY_GEN,
    -- CKM_CDMF_ECB, CKM_CDMF_CBC, CKM_CDMF_MAC,
    -- CKM_CDMF_MAC_GENERAL, and CKM_CDMF_CBC_PAD are new for v2.0
    CKM_DES3_MAC_GENERAL           as Des3MacGeneral,--0x00000135
    CKM_DES3_CBC_PAD               as Des3CbcPad,--0x00000136
    CKM_CDMF_KEY_GEN               as CdmfKeyGen,--0x00000140
    CKM_CDMF_ECB                   as CdmfEcb,--0x00000141
    CKM_CDMF_CBC                   as CdmfCbc,--0x00000142
    CKM_CDMF_MAC                   as CdmfMac,--0x00000143
    CKM_CDMF_MAC_GENERAL           as CdmfMacGeneral,--0x00000144
    CKM_CDMF_CBC_PAD               as CdmfCbcPad,--0x00000145

    -- the following four DES mechanisms are new for v2.20
    CKM_DES_OFB64                  as DesOfb64,--0x00000150
    CKM_DES_OFB8                   as DesOfb8,--0x00000151
    CKM_DES_CFB64                  as DesCfb64,--0x00000152
    CKM_DES_CFB8                   as DesCfb8,--0x00000153

    CKM_MD2                        as Md2,--0x00000200

    -- CKM_MD2_HMAC and CKM_MD2_HMAC_GENERAL are new for v2.0
    CKM_MD2_HMAC                   as Md2Hmac,--0x00000201
    CKM_MD2_HMAC_GENERAL           as Md2HmacGeneral,--0x00000202

    CKM_MD5                        as Md5,--0x00000210

    -- CKM_MD5_HMAC and CKM_MD5_HMAC_GENERAL are new for v2.0
    CKM_MD5_HMAC                   as Md5Hmac,--0x00000211
    CKM_MD5_HMAC_GENERAL           as Md5HmacGeneral,--0x00000212

    CKM_SHA_1                      as Sha1,--0x00000220

    -- CKM_SHA_1_HMAC and CKM_SHA_1_HMAC_GENERAL are new for v2.0
    CKM_SHA_1_HMAC                 as Sha1Hmac,--0x00000221
    CKM_SHA_1_HMAC_GENERAL         as Sha1HmacGeneral,--0x00000222

    -- CKM_RIPEMD128, CKM_RIPEMD128_HMAC,
    -- CKM_RIPEMD128_HMAC_GENERAL, CKM_RIPEMD160, CKM_RIPEMD160_HMAC,
    -- and CKM_RIPEMD160_HMAC_GENERAL are new for v2.10
    CKM_RIPEMD128                  as RipeMd128,--0x00000230
    CKM_RIPEMD128_HMAC             as RipeMd128Hmac,--0x00000231
    CKM_RIPEMD128_HMAC_GENERAL     as RipeMd128HmacGeneral,--0x00000232
    CKM_RIPEMD160                  as Ripe160,--0x00000240
    CKM_RIPEMD160_HMAC             as Ripe160Hmac,--0x00000241
    CKM_RIPEMD160_HMAC_GENERAL     as Ripe160HmacGeneral,--0x00000242

    -- CKM_SHA256/384/512 are new for v2.20
    CKM_SHA256                     as Sha256,--0x00000250
    CKM_SHA256_HMAC                as Sha256Hmac,--0x00000251
    CKM_SHA256_HMAC_GENERAL        as Sha256HmacGeneral,--0x00000252

    -- SHA-224 is new for PKCS #11 v2.20 amendment 3
    CKM_SHA224                     as Sha224,--0x00000255
    CKM_SHA224_HMAC                as Sha224Hmac,--0x00000256
    CKM_SHA224_HMAC_GENERAL        as Sha224HmacGeneral,--0x00000257

    CKM_SHA384                     as Sha384,--0x00000260
    CKM_SHA384_HMAC                as Sha384Hmac,--0x00000261
    CKM_SHA384_HMAC_GENERAL        as Sha384HmacGeneral,--0x00000262
    CKM_SHA512                     as Sha512,--0x00000270
    CKM_SHA512_HMAC                as Sha512Hmac,--0x00000271
    CKM_SHA512_HMAC_GENERAL        as Sha512HmacGeneral,--0x00000272

    -- SecurID is new for PKCS #11 v2.20 amendment 1
    --CKM_SECURID_KEY_GEN            0x00000280
    --CKM_SECURID                    0x00000282

    -- HOTP is new for PKCS #11 v2.20 amendment 1
    --CKM_HOTP_KEY_GEN    0x00000290
    --CKM_HOTP            0x00000291

    -- ACTI is new for PKCS #11 v2.20 amendment 1
    --CKM_ACTI            0x000002A0
    --CKM_ACTI_KEY_GEN    0x000002A1

    -- All of the following mechanisms are new for v2.0
    -- Note that CAST128 and CAST5 are the same algorithm
    CKM_CAST_KEY_GEN               as CastKeyGen,--0x00000300
    CKM_CAST_ECB                   as CastEcb,--0x00000301
    CKM_CAST_CBC                   as CastCbc,--0x00000302
    CKM_CAST_MAC                   as CastMac,--0x00000303
    CKM_CAST_MAC_GENERAL           as CastMacGeneral,--0x00000304
    CKM_CAST_CBC_PAD               as CastCbcPad,--0x00000305
    CKM_CAST3_KEY_GEN              as Cast3KeyGen,--0x00000310
    CKM_CAST3_ECB                  as Cast3Ecb,--0x00000311
    CKM_CAST3_CBC                  as Cast3Cbc,--0x00000312
    CKM_CAST3_MAC                  as Cast3Mac,--0x00000313
    CKM_CAST3_MAC_GENERAL          as Cast3MacGeneral,--0x00000314
    CKM_CAST3_CBC_PAD              as Cast3CbcPad,--0x00000315
    CKM_CAST5_KEY_GEN              as Cast5KeyGen,--0x00000320
    CKM_CAST128_KEY_GEN            as Cast128KeyGen,--0x00000320
    CKM_CAST5_ECB                  as Cast5Ecb,--0x00000321
    CKM_CAST128_ECB                as Cast128Ecb,--0x00000321
    CKM_CAST5_CBC                  as Cast5Cbc,--0x00000322
    CKM_CAST128_CBC                as Cast128Cbc,--0x00000322
    CKM_CAST5_MAC                  as Cast5Mac,--0x00000323
    CKM_CAST128_MAC                as Cast128Mac,--0x00000323
    CKM_CAST5_MAC_GENERAL          as Cast5MacGeneral,--0x00000324
    CKM_CAST128_MAC_GENERAL        as Cast128MacGeneral,--0x00000324
    CKM_CAST5_CBC_PAD              as Cast5CbcPad,--0x00000325
    CKM_CAST128_CBC_PAD            as Cast128CbcPad,--0x00000325
    CKM_RC5_KEY_GEN                as Rc5KeyGen,--0x00000330
    CKM_RC5_ECB                    as Rc5Ecb,--0x00000331
    CKM_RC5_CBC                    as Rc5Cbc,--0x00000332
    CKM_RC5_MAC                    as Rc5Mac,--0x00000333
    CKM_RC5_MAC_GENERAL            as Rc5MacGeneral,--0x00000334
    CKM_RC5_CBC_PAD                as Rc5CbcPad,--0x00000335
    CKM_IDEA_KEY_GEN               as IdeaKeyGen,--0x00000340
    CKM_IDEA_ECB                   as IdeaEcb,--0x00000341
    CKM_IDEA_CBC                   as IdeaCbc,--0x00000342
    CKM_IDEA_MAC                   as IdeaMac,--0x00000343
    CKM_IDEA_MAC_GENERAL           as IdeaMacGeneral,--0x00000344
    CKM_IDEA_CBC_PAD               as IdeaCbcPad,--0x00000345
    CKM_GENERIC_SECRET_KEY_GEN     as GeneralSecretKeyGen,--0x00000350
    CKM_CONCATENATE_BASE_AND_KEY   as ConcatenateBaseAndKey,--0x00000360
    CKM_CONCATENATE_BASE_AND_DATA  as ConcatenateBaseAndData,--0x00000362
    CKM_CONCATENATE_DATA_AND_BASE  as ConcatenateDataAndBase,--0x00000363
    CKM_XOR_BASE_AND_DATA          as XorBaseAndData,--0x00000364
    CKM_EXTRACT_KEY_FROM_KEY       as ExtractKeyFromKey,--0x00000365
    CKM_SSL3_PRE_MASTER_KEY_GEN    as Ssl3PreMasterKeyGen,--0x00000370
    CKM_SSL3_MASTER_KEY_DERIVE     as Ssl3MasterKeyDerive,--0x00000371
    CKM_SSL3_KEY_AND_MAC_DERIVE    as Ssl3KeyAndMacDerive,--0x00000372

    -- CKM_SSL3_MASTER_KEY_DERIVE_DH, CKM_TLS_PRE_MASTER_KEY_GEN,
    -- CKM_TLS_MASTER_KEY_DERIVE, CKM_TLS_KEY_AND_MAC_DERIVE, and
    -- CKM_TLS_MASTER_KEY_DERIVE_DH are new for v2.11
    --CKM_SSL3_MASTER_KEY_DERIVE_DH  0x00000373
    --CKM_TLS_PRE_MASTER_KEY_GEN     0x00000374
    --CKM_TLS_MASTER_KEY_DERIVE      0x00000375
    --CKM_TLS_KEY_AND_MAC_DERIVE     0x00000376
    --CKM_TLS_MASTER_KEY_DERIVE_DH   0x00000377

    -- CKM_TLS_PRF is new for v2.20
    --CKM_TLS_PRF                    0x00000378

    --CKM_SSL3_MD5_MAC               0x00000380
    --CKM_SSL3_SHA1_MAC              0x00000381
    --CKM_MD5_KEY_DERIVATION         0x00000390
    --CKM_MD2_KEY_DERIVATION         0x00000391
    --CKM_SHA1_KEY_DERIVATION        0x00000392

    -- CKM_SHA256/384/512 are new for v2.20
    --CKM_SHA256_KEY_DERIVATION      0x00000393
    --CKM_SHA384_KEY_DERIVATION      0x00000394
    --CKM_SHA512_KEY_DERIVATION      0x00000395

    -- SHA-224 key derivation is new for PKCS #11 v2.20 amendment 3
    CKM_SHA224_KEY_DERIVATION      as Sha224KeyDerivation,--0x00000396

    CKM_PBE_MD2_DES_CBC            as PbeMd2DesCbc,--0x000003A0
    CKM_PBE_MD5_DES_CBC            as PbeMd5DesCbc,--0x000003A1
    CKM_PBE_MD5_CAST_CBC           as PbeMd5CastCbc,--0x000003A2
    CKM_PBE_MD5_CAST3_CBC          as PbeMd5Cast3Cbc,--0x000003A3
    CKM_PBE_MD5_CAST5_CBC          as PbeMd5Cast5Cbc,--0x000003A4
    CKM_PBE_MD5_CAST128_CBC        as PbeMd5Cast128Cbc,--0x000003A4
    CKM_PBE_SHA1_CAST5_CBC         as PbeSha1Cast5Cbc,--0x000003A5
    CKM_PBE_SHA1_CAST128_CBC       as PbeSha1Cast128Cbc,--0x000003A5
    CKM_PBE_SHA1_RC4_128           as PbeSha1Rc4128,--0x000003A6
    CKM_PBE_SHA1_RC4_40            as PbeSha1Rc440,--0x000003A7
    CKM_PBE_SHA1_DES3_EDE_CBC      as PbeSha1Des3EdeCbc,--0x000003A8
    CKM_PBE_SHA1_DES2_EDE_CBC      as PbeSha1Des2EdeCbc,--0x000003A9
    CKM_PBE_SHA1_RC2_128_CBC       as PbeSha1Rc2128Cbc,--0x000003AA
    CKM_PBE_SHA1_RC2_40_CBC        as PbeSha1Rc240Cbc,--0x000003AB

    -- CKM_PKCS5_PBKD2 is new for v2.10
    CKM_PKCS5_PBKD2                as Pkcs5Pbkd2,--0x000003B0

    CKM_PBA_SHA1_WITH_SHA1_HMAC    as PbaSha1WithSha1Hmac,--0x000003C0

    -- WTLS mechanisms are new for v2.20
    --CKM_WTLS_PRE_MASTER_KEY_GEN         0x000003D0
    --CKM_WTLS_MASTER_KEY_DERIVE          0x000003D1
    --CKM_WTLS_MASTER_KEY_DERIVE_DH_ECC   0x000003D2
    --CKM_WTLS_PRF                        0x000003D3
    --CKM_WTLS_SERVER_KEY_AND_MAC_DERIVE  0x000003D4
    --CKM_WTLS_CLIENT_KEY_AND_MAC_DERIVE  0x000003D5

    --CKM_KEY_WRAP_LYNKS             0x00000400
    --CKM_KEY_WRAP_SET_OAEP          0x00000401

    -- CKM_CMS_SIG is new for v2.20
    --CKM_CMS_SIG                    0x00000500

    -- CKM_KIP mechanisms are new for PKCS #11 v2.20 amendment 2
    --CKM_KIP_DERIVE	               0x00000510
    --CKM_KIP_WRAP	               0x00000511
    --CKM_KIP_MAC	               0x00000512

    -- Camellia is new for PKCS #11 v2.20 amendment 3
    --CKM_CAMELLIA_KEY_GEN           0x00000550
    --CKM_CAMELLIA_ECB               0x00000551
    --CKM_CAMELLIA_CBC               0x00000552
    --CKM_CAMELLIA_MAC               0x00000553
    --CKM_CAMELLIA_MAC_GENERAL       0x00000554
    --CKM_CAMELLIA_CBC_PAD           0x00000555
    --CKM_CAMELLIA_ECB_ENCRYPT_DATA  0x00000556
    --CKM_CAMELLIA_CBC_ENCRYPT_DATA  0x00000557
    --CKM_CAMELLIA_CTR               0x00000558

    -- ARIA is new for PKCS #11 v2.20 amendment 3
    --CKM_ARIA_KEY_GEN               0x00000560
    --CKM_ARIA_ECB                   0x00000561
    --CKM_ARIA_CBC                   0x00000562
    --CKM_ARIA_MAC                   0x00000563
    --CKM_ARIA_MAC_GENERAL           0x00000564
    --CKM_ARIA_CBC_PAD               0x00000565
    --CKM_ARIA_ECB_ENCRYPT_DATA      0x00000566
    --CKM_ARIA_CBC_ENCRYPT_DATA      0x00000567

    -- Fortezza mechanisms
    --CKM_SKIPJACK_KEY_GEN           0x00001000
    --CKM_SKIPJACK_ECB64             0x00001001
    --CKM_SKIPJACK_CBC64             0x00001002
    --CKM_SKIPJACK_OFB64             0x00001003
    --CKM_SKIPJACK_CFB64             0x00001004
    --CKM_SKIPJACK_CFB32             0x00001005
    --CKM_SKIPJACK_CFB16             0x00001006
    --CKM_SKIPJACK_CFB8              0x00001007
    --CKM_SKIPJACK_WRAP              0x00001008
    --CKM_SKIPJACK_PRIVATE_WRAP      0x00001009
    --CKM_SKIPJACK_RELAYX            0x0000100a
    --CKM_KEA_KEY_PAIR_GEN           0x00001010
    --CKM_KEA_KEY_DERIVE             0x00001011
    --CKM_FORTEZZA_TIMESTAMP         0x00001020
    --CKM_BATON_KEY_GEN              0x00001030
    --CKM_BATON_ECB128               0x00001031
    --CKM_BATON_ECB96                0x00001032
    --CKM_BATON_CBC128               0x00001033
    --CKM_BATON_COUNTER              0x00001034
    --CKM_BATON_SHUFFLE              0x00001035
    --CKM_BATON_WRAP                 0x00001036

    -- CKM_ECDSA_KEY_PAIR_GEN is deprecated in v2.11,
    -- CKM_EC_KEY_PAIR_GEN is preferred
    CKM_ECDSA_KEY_PAIR_GEN         as EcdsaKeyPairGen,--0x00001040
    CKM_EC_KEY_PAIR_GEN            as EcKeyPairGen,--0x00001040

    CKM_ECDSA                      as Ecdsa,--0x00001041
    CKM_ECDSA_SHA1                 as EcdsaSha1,--0x00001042

    -- CKM_ECDH1_DERIVE, CKM_ECDH1_COFACTOR_DERIVE, and CKM_ECMQV_DERIVE
    -- are new for v2.11
    CKM_ECDH1_DERIVE               as Ecdh1Derive,--0x00001050
    CKM_ECDH1_COFACTOR_DERIVE      as Ecdh1CofactorDerive,--0x00001051
    CKM_ECMQV_DERIVE               as DcmqvDerive,--0x00001052

    CKM_JUNIPER_KEY_GEN            as JuniperKeyGen,--0x00001060
    CKM_JUNIPER_ECB128             as JuniperEcb128,--0x00001061
    CKM_JUNIPER_CBC128             as JuniperCbc128,--0x00001062
    CKM_JUNIPER_COUNTER            as JuniperCounter,--0x00001063
    CKM_JUNIPER_SHUFFLE            as JuniperShuffle,--0x00001064
    CKM_JUNIPER_WRAP               as JuniperWrap,--0x00001065
    CKM_FASTHASH                   as FastHash,--0x00001070

    -- CKM_AES_KEY_GEN, CKM_AES_ECB, CKM_AES_CBC, CKM_AES_MAC,
    -- CKM_AES_MAC_GENERAL, CKM_AES_CBC_PAD, CKM_DSA_PARAMETER_GEN,
    -- CKM_DH_PKCS_PARAMETER_GEN, and CKM_X9_42_DH_PARAMETER_GEN are
    -- new for v2.11
    CKM_AES_KEY_GEN                as AesKeyGen,--0x00001080
    CKM_AES_ECB                    as AesEcb,
    CKM_AES_CBC                    as AesCbc,
    CKM_AES_MAC                    as AesMac,
    CKM_AES_MAC_GENERAL            as AesMacGeneral,
    CKM_AES_CBC_PAD                as AesCbcPad,

    -- AES counter mode is new for PKCS #11 v2.20 amendment 3
    CKM_AES_CTR                    as AesCtr,

    CKM_AES_GCM                    as AesGcm,--0x00001087
    CKM_AES_CCM                    as AesCcm,--0x00001088
    CKM_AES_KEY_WRAP               as AesKeyWrap,--0x00001090
    CKM_AES_KEY_WRAP_PAD           as AesKeyWrapPad,--0x00001091

    -- BlowFish and TwoFish are new for v2.20
    CKM_BLOWFISH_KEY_GEN           as BlowfishKeyGen,
    CKM_BLOWFISH_CBC               as BlowfishCbc,
    CKM_TWOFISH_KEY_GEN            as TwoFishKeyGen,
    CKM_TWOFISH_CBC                as TwoFishCbc,

    -- CKM_xxx_ENCRYPT_DATA mechanisms are new for v2.20
    CKM_DES_ECB_ENCRYPT_DATA       as DesEcbEncryptData,
    CKM_DES_CBC_ENCRYPT_DATA       as DesCbcEncryptData,
    CKM_DES3_ECB_ENCRYPT_DATA      as Des3EcbEncryptData,
    CKM_DES3_CBC_ENCRYPT_DATA      as Des3CbcEncryptData,
    CKM_AES_ECB_ENCRYPT_DATA       as AesEcbEncryptData,
    CKM_AES_CBC_ENCRYPT_DATA       as AesCbcEncryptData,

    CKM_DSA_PARAMETER_GEN as DsaParameterGen,
    CKM_DH_PKCS_PARAMETER_GEN      as DhPkcsParameterGen,
    CKM_X9_42_DH_PARAMETER_GEN     as X9_42DhParameterGen,

    CKM_VENDOR_DEFINED             as VendorDefined
    } deriving (Eq,Show) #}


_decryptInit :: MechType -> Session -> ObjectHandle -> IO ()
_decryptInit mechType (Session sessionHandle functionListPtr) obj = do
    alloca $ \mechPtr -> do
        poke mechPtr (Mech {mechType = mechType, mechParamPtr = nullPtr, mechParamSize = 0})
        rv <- {#call unsafe CK_FUNCTION_LIST.C_DecryptInit#} functionListPtr sessionHandle mechPtr obj
        if rv /= 0
            then fail $ "failed to initiate decryption: " ++ (rvToStr rv)
            else return ()


decrypt :: MechType -> Session -> ObjectHandle -> BS.ByteString -> IO BS.ByteString
decrypt mechType (Session sessionHandle functionListPtr) obj encData = do
    _decryptInit mechType (Session sessionHandle functionListPtr) obj
    unsafeUseAsCStringLen encData $ \(encDataPtr, encDataLen) -> do
        putStrLn $ "in data len " ++ (show encDataLen)
        putStrLn $ show encData
        allocaBytes encDataLen $ \outDataPtr -> do
            alloca $ \outDataLenPtr -> do
                poke outDataLenPtr (fromIntegral encDataLen)
                rv <- {#call unsafe CK_FUNCTION_LIST.C_Decrypt#} functionListPtr sessionHandle (castPtr encDataPtr) (fromIntegral encDataLen) outDataPtr outDataLenPtr
                if rv /= 0
                    then fail $ "failed to decrypt: " ++ (rvToStr rv)
                    else do
                        outDataLen <- peek outDataLenPtr
                        res <- BS.packCStringLen (castPtr outDataPtr, fromIntegral outDataLen)
                        return res


_encryptInit :: MechType -> Session -> ObjectHandle -> IO ()
_encryptInit mechType (Session sessionHandle functionListPtr) obj = do
    alloca $ \mechPtr -> do
        poke mechPtr (Mech {mechType = mechType, mechParamPtr = nullPtr, mechParamSize = 0})
        rv <- {#call unsafe CK_FUNCTION_LIST.C_EncryptInit#} functionListPtr sessionHandle mechPtr obj
        if rv /= 0
            then fail $ "failed to initiate decryption: " ++ (rvToStr rv)
            else return ()


encrypt :: MechType -> Session -> ObjectHandle -> BS.ByteString -> IO BS.ByteString
encrypt mechType (Session sessionHandle functionListPtr) obj encData = do
    _encryptInit mechType (Session sessionHandle functionListPtr) obj
    let outLen = 1000
    unsafeUseAsCStringLen encData $ \(encDataPtr, encDataLen) -> do
        allocaBytes outLen $ \outDataPtr -> do
            alloca $ \outDataLenPtr -> do
                poke outDataLenPtr (fromIntegral outLen)
                rv <- {#call unsafe CK_FUNCTION_LIST.C_Encrypt#} functionListPtr sessionHandle (castPtr encDataPtr) (fromIntegral encDataLen) outDataPtr outDataLenPtr
                if rv /= 0
                    then fail $ "failed to decrypt: " ++ (rvToStr rv)
                    else do
                        outDataLen <- peek outDataLenPtr
                        res <- BS.packCStringLen (castPtr outDataPtr, fromIntegral outDataLen)
                        return res


unwrapKey :: MechType -> Session -> ObjectHandle -> BS.ByteString -> [Attribute] -> IO ObjectHandle
unwrapKey mechType (Session sessionHandle functionListPtr) key wrappedKey template = do
    _withAttribs template $ \attribsPtr -> do
        alloca $ \mechPtr -> do
            poke mechPtr (Mech {mechType = mechType, mechParamPtr = nullPtr, mechParamSize = 0})
            unsafeUseAsCStringLen wrappedKey $ \(wrappedKeyPtr, wrappedKeyLen) -> do
                alloca $ \unwrappedKeyPtr -> do
                    rv <- {#call unsafe CK_FUNCTION_LIST.C_UnwrapKey#} functionListPtr sessionHandle mechPtr key (castPtr wrappedKeyPtr) (fromIntegral wrappedKeyLen) attribsPtr (fromIntegral $ length template) unwrappedKeyPtr
                    if rv /= 0
                        then fail $ "failed to unwrap key: " ++ (rvToStr rv)
                        else do
                            unwrappedKey <- peek unwrappedKeyPtr
                            return unwrappedKey


getMechanismList :: Library -> SlotId -> Int -> IO [Int]
getMechanismList (Library _ functionListPtr) slotId maxMechanisms = do
    (rv, types) <- _getMechanismList functionListPtr slotId maxMechanisms
    if rv /= 0
        then fail $ "failed to get list of mechanisms: " ++ (rvToStr rv)
        else return $ map (fromIntegral) types


-- | Retrieves mechanism info
getMechanismInfo :: Library -> SlotId -> MechType -> IO MechInfo
getMechanismInfo (Library _ functionListPtr) slotId mechId = do
    (rv, types) <- _getMechanismInfo functionListPtr slotId (fromEnum mechId)
    if rv /= 0
        then fail $ "failed to get mechanism information: " ++ (rvToStr rv)
        else return types
