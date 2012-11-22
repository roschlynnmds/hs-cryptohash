{-# LANGUAGE ForeignFunctionInterface, CPP, MultiParamTypeClasses, EmptyDataDecls #-}

-- |
-- Module      : Crypto.Hash.SHA512
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
-- A module containing SHA512 bindings
--
module Crypto.Hash.SHA512
    ( Ctx(..)
    , SHA512

    -- * Incremental hashing Functions
    , init     -- :: Ctx
    , init_t   -- :: Int -> Ctx
    , update   -- :: Ctx -> ByteString -> Ctx
    , finalize -- :: Ctx -> Digest SHA512

    -- * Single Pass hashing
    , hash     -- :: ByteString -> Digest SHA512
    , hashlazy -- :: ByteString -> Digest SHA512
    ) where

import Prelude hiding (init)
import Foreign.Ptr
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Storable
import Foreign.Marshal.Alloc
import qualified Data.ByteString.Lazy as L
import Data.ByteString (ByteString)
import Data.ByteString.Unsafe (unsafeUseAsCStringLen)
import Data.ByteString.Internal (create, toForeignPtr, inlinePerformIO)
import Data.Word
import Crypto.Hash.Types (Digest(..))

data Ctx = Ctx !ByteString
data SHA512

{-# INLINE digestSize #-}
digestSize :: Int
digestSize = 64

{-# INLINE sizeCtx #-}
sizeCtx :: Int
sizeCtx = 256

{-# INLINE withByteStringPtr #-}
withByteStringPtr :: ByteString -> (Ptr Word8 -> IO a) -> IO a
withByteStringPtr b f =
    withForeignPtr fptr $ \ptr -> f (ptr `plusPtr` off)
    where (fptr, off, _) = toForeignPtr b

{-# INLINE memcopy64 #-}
memcopy64 :: Ptr Word64 -> Ptr Word64 -> IO ()
memcopy64 dst src = mapM_ peekAndPoke [0..(32-1)]
    where peekAndPoke i = peekElemOff src i >>= pokeElemOff dst i

withCtxCopy :: Ctx -> (Ptr Ctx -> IO ()) -> IO Ctx
withCtxCopy (Ctx ctxB) f = Ctx `fmap` createCtx
    where createCtx = create sizeCtx $ \dstPtr ->
                      withByteStringPtr ctxB $ \srcPtr -> do
                          memcopy64 (castPtr dstPtr) (castPtr srcPtr)
                          f (castPtr dstPtr)

withCtxThrow :: Ctx -> (Ptr Ctx -> IO a) -> IO a
withCtxThrow (Ctx ctxB) f =
    allocaBytes sizeCtx $ \dstPtr ->
    withByteStringPtr ctxB $ \srcPtr -> do
        memcopy64 (castPtr dstPtr) (castPtr srcPtr)
        f (castPtr dstPtr)

withCtxNew :: (Ptr Ctx -> IO ()) -> IO Ctx
withCtxNew f = Ctx `fmap` create sizeCtx (f . castPtr)

withCtxNewThrow :: (Ptr Ctx -> IO a) -> IO a
withCtxNewThrow f = allocaBytes sizeCtx (f . castPtr)

foreign import ccall unsafe "sha512.h sha512_init"
    c_sha512_init :: Ptr Ctx -> IO ()

foreign import ccall unsafe "sha512.h sha512_init_t"
    c_sha512_init_t :: Ptr Ctx -> Int -> IO ()

foreign import ccall "sha512.h sha512_update"
    c_sha512_update :: Ptr Ctx -> Ptr Word8 -> Word32 -> IO ()

foreign import ccall unsafe "sha512.h sha512_finalize"
    c_sha512_finalize :: Ptr Ctx -> Ptr Word8 -> IO ()

updateInternalIO :: Ptr Ctx -> ByteString -> IO ()
updateInternalIO ptr d =
    unsafeUseAsCStringLen d (\(cs, len) -> c_sha512_update ptr (castPtr cs) (fromIntegral len))

finalizeInternalIO :: Ptr Ctx -> IO (Digest SHA512)
finalizeInternalIO ptr =
    Digest `fmap` create digestSize (c_sha512_finalize ptr)

{-# NOINLINE init #-}
-- | init a context
init :: Ctx
init = inlinePerformIO $ withCtxNew $ c_sha512_init

-- | init a context using FIPS 180-4 for truncated SHA512
init_t :: Int -> Ctx
init_t t = inlinePerformIO $ withCtxNew $ \ptr -> c_sha512_init_t ptr t

{-# NOINLINE update #-}
-- | update a context with a bytestring
update :: Ctx -> ByteString -> Ctx
update ctx d = inlinePerformIO $ withCtxCopy ctx $ \ptr -> updateInternalIO ptr d

{-# NOINLINE finalize #-}
-- | finalize the context into a digest bytestring
finalize :: Ctx -> Digest SHA512
finalize ctx = inlinePerformIO $ withCtxThrow ctx finalizeInternalIO

{-# NOINLINE hash #-}
-- | hash a strict bytestring into a digest bytestring
hash :: ByteString -> Digest SHA512
hash d = inlinePerformIO $ withCtxNewThrow $ \ptr -> do
    c_sha512_init ptr >> updateInternalIO ptr d >> finalizeInternalIO ptr

{-# NOINLINE hashlazy #-}
-- | hash a lazy bytestring into a digest bytestring
hashlazy :: L.ByteString -> Digest SHA512
hashlazy l = inlinePerformIO $ withCtxNewThrow $ \ptr -> do
    c_sha512_init ptr >> mapM_ (updateInternalIO ptr) (L.toChunks l) >> finalizeInternalIO ptr
