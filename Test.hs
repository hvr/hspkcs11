import Pkcs11

main = do
    lib <- loadLibrary "/Library/Frameworks/eToken.framework/Versions/Current/libeToken.dylib"
    info <- getInfo lib
    putStrLn(show info)
    slots <- getSlotList lib True 10
    putStrLn(show slots)

    putStrLn "getSlotInfo"
    slotInfo <- getSlotInfo lib 0
    putStrLn(show slotInfo)

    putStrLn "getTokenInfo"
    tokenInfo <- getTokenInfo lib 0
    putStrLn(show tokenInfo)

    withSession lib 0 serialSession $ \sess -> do
        objects <- findObjects sess [Class PublicKey, KeyType RSA]
        putStrLn $ show objects
