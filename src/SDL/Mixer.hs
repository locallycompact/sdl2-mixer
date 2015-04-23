{-|

Module      : SDL.Mixer
License     : BSD3
Stability   : experimental

Bindings to the @SDL2_mixer@ library.

-}

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PatternSynonyms            #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeFamilies               #-}

module SDL.Mixer
  (
  -- * Initialization
    initialize
  , InitFlag(..)
  , quit
  , version

  -- * Configuring audio
  , openAudio
  , Audio(..)
  , defaultAudio
  , ChunkSize
  , Format(..)
  , Output(..)
  , queryAudio
  , closeAudio

  -- * Loading audio data
  , Loadable(..)

  -- * Chunks
  , chunkDecoders
  , Chunk(..)

  -- * Channels and groups
  , Channel
  , pattern AllChannels
  , setChannels
  , getChannels
  , whenChannelFinished
  , playedLast
  , reserveChannels
  , Group
  , pattern DefaultGroup
  , group
  , groupSpan
  , groupCount
  , getAvailable
  , getOldest
  , getNewest

  -- * Music
  , musicDecoders
  , Music(..)

  -- * Playing
  , play
  , playForever
  , Times
  , pattern Once
  , pattern Forever
  , playOn
  , Milliseconds
  , Limit
  , pattern NoLimit
  , playLimit

  -- * Pausing, resuming, halting
  , pause
  , resume
  , halt
  , haltAfter
  , haltGroup
  , playing
  , playingCount
  , paused
  , pausedCount

  -- * Fading in and out
  , fadeIn
  , fadeInOn
  , fadeInLimit
  , fadeOut
  , fadeOutGroup
  , Fading
  , fading

  -- * Setting the volume
  , Volume
  , HasVolume(..)

  ) where

import Control.Monad          (void, forM, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Bits              ((.|.), (.&.))
import Data.ByteString        (ByteString, readFile)
import Data.ByteString.Unsafe (unsafeUseAsCStringLen)
import Data.Default.Class     (Default(def))
import Data.Foldable          (foldl)
import Data.IORef             (IORef, newIORef, readIORef, writeIORef)
import Foreign.C.String       (peekCString)
import Foreign.C.Types        (CInt)
import Foreign.Marshal.Alloc  (alloca)
import Foreign.Ptr            (Ptr, FunPtr, castPtr, nullFunPtr, nullPtr, freeHaskellFunPtr)
import Foreign.Storable       (Storable(..))
import Prelude         hiding (foldl, readFile)
import SDL.Exception          (throwIfNeg_, throwIf_, throwIf0, throwIfNull, throwIfNeg)
import SDL.Raw.Filesystem     (rwFromConstMem)
import System.IO.Unsafe       (unsafePerformIO)

import qualified SDL.Raw
import qualified SDL.Raw.Mixer

-- | Initialize the library by loading support for a certain set of
-- sample/music formats.
--
-- Note that calling this is not strictly necessary: support for a certain
-- format will be loaded automatically when attempting to load data in that
-- format. Using 'initialize' allows you to decide /when/ to load support.
--
-- You may call this function multiple times.
initialize :: (Foldable f, Functor m, MonadIO m) => f InitFlag -> m ()
initialize flags = do
  let raw = foldl (\a b -> a .|. initToCInt b) 0 flags
  throwIf_ ((/= raw) . (.&. raw)) "SDL.Mixer.initialize" "Mix_Init" $
    SDL.Raw.Mixer.init raw

-- | Used with 'initialize' to designate loading support for a particular
-- sample/music format.
data InitFlag
  = InitFLAC
  | InitMOD
  | InitMODPlug
  | InitMP3
  | InitOGG
  | InitFluidSynth
  deriving (Eq, Ord, Bounded, Read, Show)

initToCInt :: InitFlag -> CInt
initToCInt = \case
  InitFLAC       -> SDL.Raw.Mixer.INIT_FLAC
  InitMOD        -> SDL.Raw.Mixer.INIT_MOD
  InitMODPlug    -> SDL.Raw.Mixer.INIT_MODPLUG
  InitMP3        -> SDL.Raw.Mixer.INIT_MP3
  InitOGG        -> SDL.Raw.Mixer.INIT_OGG
  InitFluidSynth -> SDL.Raw.Mixer.INIT_FLUIDSYNTH

-- | Cleans up any loaded libraries, freeing memory.
quit :: MonadIO m => m ()
quit = SDL.Raw.Mixer.quit -- FIXME: May not free all init'd libs! Check docs.

-- | Gets the major, minor, patch versions of the linked @SDL2_mixer@ library.
version :: (Integral a, MonadIO m) => m (a, a, a)
version = liftIO $ do
  SDL.Raw.Version major minor patch <- peek =<< SDL.Raw.Mixer.getVersion
  return (fromIntegral major, fromIntegral minor, fromIntegral patch)

-- | Initializes the @SDL2_mixer@ API.
--
-- This should be the first function you call after intializing @SDL@ itself
-- with 'SDL.Init.InitAudio'.
openAudio :: (Functor m, MonadIO m) => Audio -> ChunkSize -> m ()
openAudio (Audio {..}) chunkSize =
  throwIfNeg_ "SDL.Mixer.openAudio" "Mix_OpenAudio" $
    SDL.Raw.Mixer.openAudio
      (fromIntegral audioFrequency)
      (formatToWord audioFormat)
      (outputToCInt audioOutput)
      (fromIntegral chunkSize)

-- | An audio configuration. Use this with 'openAudio'.
data Audio = Audio
  { audioFrequency :: Int    -- ^ A sampling frequency.
  , audioFormat    :: Format -- ^ An output sample format.
  , audioOutput    :: Output -- ^ 'Mono' or 'Stereo' output.
  } deriving (Eq, Read, Show)

instance Default Audio where
  def = Audio { audioFrequency = SDL.Raw.Mixer.DEFAULT_FREQUENCY
              , audioFormat    = wordToFormat SDL.Raw.Mixer.DEFAULT_FORMAT
              , audioOutput    = cIntToOutput SDL.Raw.Mixer.DEFAULT_CHANNELS
              }

-- | A default 'Audio' configuration.
--
-- Same as 'Data.Default.Class.def'.
--
-- Uses 22050 as the 'audioFrequency', 'FormatS16_Sys' as the 'audioFormat' and
-- 'Stereo' as the 'audioOutput'.
defaultAudio :: Audio
defaultAudio = def

-- | The size of each mixed sample.
--
-- The smaller this is, the more often callbacks will be invoked. If this is
-- made too small on a slow system, the sounds may skip. If made too large,
-- sound effects could lag.
type ChunkSize = Int

-- | A sample format.
data Format
  = FormatU8      -- ^ Unsigned 8-bit samples.
  | FormatS8      -- ^ Signed 8-bit samples.
  | FormatU16_LSB -- ^ Unsigned 16-bit samples, in little-endian byte order.
  | FormatS16_LSB -- ^ Signed 16-bit samples, in little-endian byte order.
  | FormatU16_MSB -- ^ Unsigned 16-bit samples, in big-endian byte order.
  | FormatS16_MSB -- ^ signed 16-bit samples, in big-endian byte order.
  | FormatU16_Sys -- ^ Unsigned 16-bit samples, in system byte order.
  | FormatS16_Sys -- ^ Signed 16-bit samples, in system byte order.
  deriving (Eq, Ord, Bounded, Read, Show)

formatToWord :: Format -> SDL.Raw.Mixer.Format
formatToWord = \case
  FormatU8      -> SDL.Raw.Mixer.AUDIO_U8
  FormatS8      -> SDL.Raw.Mixer.AUDIO_S8
  FormatU16_LSB -> SDL.Raw.Mixer.AUDIO_U16LSB
  FormatS16_LSB -> SDL.Raw.Mixer.AUDIO_S16LSB
  FormatU16_MSB -> SDL.Raw.Mixer.AUDIO_U16MSB
  FormatS16_MSB -> SDL.Raw.Mixer.AUDIO_S16MSB
  FormatU16_Sys -> SDL.Raw.Mixer.AUDIO_U16SYS
  FormatS16_Sys -> SDL.Raw.Mixer.AUDIO_S16SYS

wordToFormat :: SDL.Raw.Mixer.Format -> Format
wordToFormat = \case
  SDL.Raw.Mixer.AUDIO_U8     -> FormatU8
  SDL.Raw.Mixer.AUDIO_S8     -> FormatS8
  SDL.Raw.Mixer.AUDIO_U16LSB -> FormatU16_LSB
  SDL.Raw.Mixer.AUDIO_S16LSB -> FormatS16_LSB
  SDL.Raw.Mixer.AUDIO_U16MSB -> FormatU16_MSB
  SDL.Raw.Mixer.AUDIO_S16MSB -> FormatS16_MSB
  SDL.Raw.Mixer.AUDIO_U16SYS -> FormatU16_Sys
  SDL.Raw.Mixer.AUDIO_S16SYS -> FormatS16_Sys
  _ -> error "SDL.Mixer.wordToFormat: unknown Format."

-- | The number of sound channels in output.
data Output = Mono | Stereo
  deriving (Eq, Ord, Bounded, Read, Show)

outputToCInt :: Output -> CInt
outputToCInt = \case
  Mono   -> 1
  Stereo -> 2

cIntToOutput :: CInt -> Output
cIntToOutput = \case
  1 -> Mono
  2 -> Stereo
  _ -> error "SDL.Mixer.cIntToOutput: unknown number of channels."

-- | Get the audio format in use by the opened audio device.
--
-- This may or may not match the 'Audio' you asked for when calling
-- 'openAudio'.
queryAudio :: (MonadIO m) => m Audio
queryAudio =
  liftIO .
    alloca $ \freq ->
      alloca $ \form ->
        alloca $ \chan -> do
          void . throwIf0 "SDL.Mixer.queryAudio" "Mix_QuerySpec" $
            SDL.Raw.Mixer.querySpec freq form chan
          Audio
            <$> (fromIntegral <$> peek freq)
            <*> (wordToFormat <$> peek form)
            <*> (cIntToOutput <$> peek chan)

-- | Shut down and clean up the @SDL2_mixer@ API.
--
-- After calling this, all audio stops and no functions except 'openAudio'
-- should be used.
closeAudio :: MonadIO m => m ()
closeAudio = SDL.Raw.Mixer.closeAudio

-- | A class of all values that can be loaded from some source. You can load
-- both 'Chunk's and 'Music' this way.
--
-- Note that you must call 'openAudio' before using these, since they have to
-- know the audio configuration to properly convert the data for playback.
class Loadable a where

  -- | Load the value from a 'ByteString'.
  decode :: MonadIO m => ByteString -> m a

  -- | Same as 'decode', but loads from a file instead.
  load :: MonadIO m => FilePath -> m a
  load = (decode =<<) . liftIO . readFile

  -- | Frees the value's memory. It should no longer be used.
  --
  -- Note that __you shouldn't free those values that are currently playing__.
  free :: MonadIO m => a -> m ()

-- | A volume, where 0 is silent and 128 loudest.
--
-- 'Volume's lesser than 0 or greater than 128 function as if they are 0 and
-- 128, respectively.
type Volume = Int

volumeToCInt :: Volume -> CInt
volumeToCInt = fromIntegral . max 0 . min 128

-- | A class of all values that have a 'Volume'.
class HasVolume a where

  -- | Gets the value's currently set 'Volume'.
  --
  -- If the value is a 'Channel' and 'AllChannels' is used, gets the /average/
  -- 'Volume' of all 'Channel's.
  getVolume :: MonadIO m => a -> m Volume

  -- | Sets a value's 'Volume'.
  --
  -- If the value is a 'Chunk', the volume setting only takes effect when the
  -- 'Chunk' is used on a 'Channel', being mixed into the output.
  --
  -- In case of being used on a 'Channel', the volume setting takes effect
  -- during the final mix, along with the 'Chunk' volume. For instance, setting
  -- the 'Volume' of a certain 'Channel' to 64 will halve the volume of all
  -- 'Chunk's played on that 'Channel'. If 'AllChannels' is used, sets all
  -- 'Channel's to the given 'Volume' instead.
  setVolume :: MonadIO m => Volume -> a -> m ()

-- | Returns the names of all chunk decoders currently available.
--
-- These depend on the availability of shared libraries for each of the
-- formats. The list may contain any of the following, and possibly others:
-- @WAVE@, @AIFF@, @VOC@, @OFF@, @FLAC@, @MP3@.
chunkDecoders :: MonadIO m => m [String]
chunkDecoders =
  liftIO $ do
    num <- SDL.Raw.Mixer.getNumChunkDecoders
    forM [0 .. num - 1] $ \i ->
      SDL.Raw.Mixer.getChunkDecoder i >>= peekCString

-- | A loaded audio chunk.
newtype Chunk = Chunk (Ptr SDL.Raw.Mixer.Chunk) deriving (Eq, Show)

instance Loadable Chunk where
  decode bytes = liftIO $ do
    unsafeUseAsCStringLen bytes $ \(cstr, len) -> do
      rw <- rwFromConstMem (castPtr cstr) (fromIntegral len)
      fmap Chunk .
        throwIfNull "SDL.Mixer.decode<Chunk>" "IMG_LoadWAV_RW" $
          SDL.Raw.Mixer.loadWAV_RW rw 0

  free (Chunk p) = liftIO $ SDL.Raw.Mixer.freeChunk p

instance HasVolume Chunk where
  getVolume   (Chunk p) = fmap fromIntegral $ SDL.Raw.Mixer.volumeChunk p (-1)
  setVolume v (Chunk p) = void . SDL.Raw.Mixer.volumeChunk p $ volumeToCInt v

-- | A mixing channel.
--
-- Use the 'Integral' instance to define these: the first channel is 0, the
-- second 1 and so on.
--
-- The default number of 'Channel's available at startup is 8, so note that you
-- cannot usemore than these starting 8 if you haven't created more with
-- 'setChannels'.
--
-- The starting 'Volume' of each 'Channel' is the maximum: 128.
newtype Channel = Channel CInt deriving (Eq, Ord, Enum, Integral, Real, Num)

instance Show Channel where
  show = \case
    AllChannels -> "AllChannels"
    Channel c   -> "Channel " ++ show c

-- | Prepares a given number of 'Channel's for use.
--
-- There are 8 such 'Channel's already prepared for use after 'openAudio' is
-- called.
--
-- You may call this multiple times, even with sounds playing. If setting a
-- lesser number of 'Channel's than are currently in use, the higher 'Channel's
-- will be stopped, their finish callbacks invoked, and their memory freed.
-- Passing in 0 or less will therefore stop and free all mixing channels.
--
-- Any 'Music' playing is not affected by this function.
setChannels :: MonadIO m => Int -> m ()
setChannels = void . SDL.Raw.Mixer.allocateChannels . fromIntegral . max 0

-- | Gets the number of 'Channel's currently in use.
getChannels :: MonadIO m => m Int
getChannels = fromIntegral <$> SDL.Raw.Mixer.allocateChannels (-1)

-- | Reserve a given number of 'Channel's, starting from 'Channel' 0.
--
-- A reserved 'Channel' is considered not to be available for playing samples
-- when using any 'play' or 'fadeIn' function variant with 'AllChannels'. In
-- other words, whenever you let 'SDL.Mixer' pick the first available 'Channel'
-- itself, these reserved 'Channel's will not be considered.
reserveChannels :: MonadIO m => Int -> m Int
reserveChannels =
  fmap fromIntegral . SDL.Raw.Mixer.reserveChannels . fromIntegral

-- | Gets the most recent 'Chunk' played on a 'Channel', if any.
--
-- Using 'AllChannels' is not valid here, and will return 'Nothing'.
--
-- Note that the returned 'Chunk' might be invalid if it was already 'free'd.
playedLast :: MonadIO m => Channel -> m (Maybe Chunk)
playedLast (Channel c) = do
  p <- SDL.Raw.Mixer.getChunk c
  return $ if p == nullPtr then Nothing else Just (Chunk p)

-- | Use this value when you wish to perform an operation on /all/ 'Channel's.
--
-- For more information, see each of the functions accepting a 'Channel'.
pattern AllChannels = (-1) :: Channel

instance HasVolume Channel where
  getVolume   (Channel c) = fmap fromIntegral $ SDL.Raw.Mixer.volume c (-1)
  setVolume v (Channel c) = void . SDL.Raw.Mixer.volume c $ volumeToCInt v

-- | Play a 'Chunk' once, using the first available 'Channel'.
play :: MonadIO m => Chunk -> m ()
play = void . playOn (-1) Once

-- | Same as 'play', but keeps playing the 'Chunk' forever.
playForever :: MonadIO m => Chunk -> m ()
playForever = void . playOn (-1) Forever

-- | How many times should a certain 'Chunk' be played?
newtype Times = Times CInt deriving (Eq, Ord, Enum, Integral, Real, Num)

-- | A shorthand for playing once.
pattern Once = 1 :: Times

-- | A shorthand for looping a 'Chunk' forever.
pattern Forever = 0 :: Times

-- | Same as 'play', but plays the 'Chunk' using a given 'Channel' a certain
-- number of 'Times'.
--
-- If 'AllChannels' is used, then plays the 'Chunk' using the first available
-- 'Channel' instead.
--
-- Returns the 'Channel' that was used.
playOn :: MonadIO m => Channel -> Times -> Chunk -> m Channel
playOn = playLimit NoLimit

-- | A time in milliseconds.
type Milliseconds = Int

-- | An upper limit of time, in milliseconds.
type Limit = Milliseconds

-- | A lack of an upper limit.
pattern NoLimit = (-1) :: Limit

-- | Same as 'playOn', but imposes an upper limit in 'Milliseconds' to how long
-- the 'Chunk' can play.
--
-- The playing may still stop before the limit is reached.
--
-- This is the most generic play function variant.
playLimit :: MonadIO m => Limit -> Channel -> Times -> Chunk -> m Channel
playLimit l (Channel c) (Times t) (Chunk p) =
  throwIfNeg "SDL.Mixer.playLimit" "Mix_PlayChannelTimed" $
    fromIntegral <$> SDL.Raw.Mixer.playChannelTimed c p (t - 1) (fromIntegral l)

-- | Same as 'play', but fades in the 'Chunk' by making the 'Channel' 'Volume'
-- start at 0 and rise to a full 128 over the course of a given number of
-- 'Milliseconds'.
--
-- The 'Chunk' may end playing before the fade-in is complete, if it doesn't
-- last as long as the given fade-in time.
fadeIn :: MonadIO m => Milliseconds -> Chunk -> m ()
fadeIn ms  = void . fadeInOn AllChannels Once ms

-- | Same as 'fadeIn', but allows you to specify the 'Channel' to play on and
-- how many 'Times' to play it, similar to 'playOn'.
--
-- If 'AllChannels' is used, will play the 'Chunk' on the first available
-- 'Channel'.
--
-- Returns the 'Channel' that was used.
fadeInOn :: MonadIO m => Channel -> Times -> Milliseconds -> Chunk -> m Channel
fadeInOn = fadeInLimit NoLimit

-- | Same as 'fadeInOn', but imposes an upper limit in 'Milliseconds' to how
-- long the 'Chunk' can play, similar to 'playLimit'.
--
-- This is the most generic fade-in function variant.
fadeInLimit
  :: MonadIO m =>
     Limit -> Channel -> Times -> Milliseconds -> Chunk -> m Channel
fadeInLimit l (Channel c) (Times t) ms (Chunk p) =
  throwIfNeg "SDL.Mixer.fadeInLimit" "Mix_FadeInChannelTimed" $
    fromIntegral <$>
      SDL.Raw.Mixer.fadeInChannelTimed
        c p (t - 1) (fromIntegral ms) (fromIntegral l)

-- | Gradually fade out a given playing 'Channel' during the next
-- 'Milliseconds', even if it is 'pause'd.
--
-- If 'AllChannels' is used, fades out all the playing 'Channel's instead.
fadeOut :: MonadIO m => Milliseconds -> Channel -> m ()
fadeOut ms (Channel c) = void $ SDL.Raw.Mixer.fadeOutChannel c $ fromIntegral ms

-- | Same as 'fadeOut', but fades out an entire 'Group' instead.
--
-- Using 'DefaultGroup' here is the same as calling 'fadeOut' with
-- 'AllChannels'.
fadeOutGroup :: MonadIO m => Milliseconds -> Group -> m ()
fadeOutGroup ms = \case
  DefaultGroup -> fadeOut ms AllChannels
  Group g      -> void $ SDL.Raw.Mixer.fadeOutGroup g $ fromIntegral ms

-- | Pauses the given 'Channel', if it is actively playing.
--
-- If 'AllChannels' is used, will pause all actively playing 'Channel's
-- instead.
--
-- Note that 'pause'd 'Channel's may still be 'halt'ed.
pause :: MonadIO m => Channel -> m ()
pause (Channel c) = SDL.Raw.Mixer.pause c

-- | Resumes playing a 'Channel', or all 'Channel's if 'AllChannels' is used.
resume :: MonadIO m => Channel -> m ()
resume (Channel c) = SDL.Raw.Mixer.resume c

-- | Halts playback on a 'Channel', or all 'Channel's if 'AllChannels' is used.
halt :: MonadIO m => Channel -> m ()
halt (Channel c) = void $ SDL.Raw.Mixer.haltChannel c

-- | Same as 'halt', but only does so after a certain number of 'Milliseconds'.
--
-- If 'AllChannels' is used, it will halt all the 'Channel's after the given
-- time instead.
haltAfter :: MonadIO m => Milliseconds -> Channel -> m ()
haltAfter ms (Channel c) =
  void . SDL.Raw.Mixer.expireChannel c $ fromIntegral ms

-- | Same as 'halt', but halts an entire 'Group' instead.
--
-- Note that using 'DefaultGroup' here is the same as calling 'halt'
-- 'AllChannels'.
haltGroup :: MonadIO m => Group -> m ()
haltGroup = \case
  DefaultGroup -> halt AllChannels
  Group g      -> void $ SDL.Raw.Mixer.haltGroup g

-- Quackery of the highest order! We keep track of a pointer we gave SDL_mixer,
-- so we can free it at a later time. May the gods have mercy...
{-# NOINLINE channelFinishedFunPtr #-}
channelFinishedFunPtr :: IORef (FunPtr (SDL.Raw.Mixer.Channel -> IO ()))
channelFinishedFunPtr = unsafePerformIO $ newIORef nullFunPtr

-- | Sets a callback that gets invoked each time a 'Channel' finishes playing.
--
-- A 'Channel' finishes playing both when playback ends normally and when it is
-- 'halt'ed (also possibly via 'setChannels').
--
-- __Note: don't call other 'SDL.Mixer' functions within this callback.__
whenChannelFinished :: MonadIO m => (Channel -> IO ()) -> m ()
whenChannelFinished callback = liftIO $ do

  -- Sets the callback.
  let callback' = callback . Channel
  callbackRaw <- SDL.Raw.Mixer.wrapChannelCallback callback'
  SDL.Raw.Mixer.channelFinished callbackRaw

  -- Free the function we set last time, if any.
  lastFunPtr <- readIORef channelFinishedFunPtr
  when (lastFunPtr /= nullFunPtr) $ freeHaskellFunPtr lastFunPtr

  -- Then remember the new one. And weep in shame.
  writeIORef channelFinishedFunPtr callbackRaw

-- | Returns whether the given 'Channel' is playing or not.
--
-- If 'AllChannels' is used, this returns whether /any/ of the channels is
-- currently playing.
playing :: MonadIO m => Channel -> m Bool
playing (Channel c) = (> 0) <$> SDL.Raw.Mixer.playing c

-- | Returns how many 'Channel's are currently playing.
playingCount :: MonadIO m => m Int
playingCount = fromIntegral <$> SDL.Raw.Mixer.playing (-1)

-- | Returns whether the given 'Channel' is paused or not.
--
-- If 'AllChannels' is used, this returns whether /any/ of the channels is
-- currently paused.
paused :: MonadIO m => Channel -> m Bool
paused (Channel c) = (> 0) <$> SDL.Raw.Mixer.paused c

-- | Returns how many 'Channel's are currently paused.
pausedCount :: MonadIO m => m Int
pausedCount = fromIntegral <$> SDL.Raw.Mixer.paused (-1)

-- | Describes whether a 'Channel' is fading in, out, or not at all.
data Fading = NoFading | FadingIn | FadingOut
  deriving (Eq, Ord, Show, Read)

wordToFading :: SDL.Raw.Mixer.Fading -> Fading
wordToFading = \case
  SDL.Raw.Mixer.NO_FADING  -> NoFading
  SDL.Raw.Mixer.FADING_IN  -> FadingIn
  SDL.Raw.Mixer.FADING_OUT -> FadingOut
  _ -> error "SDL.Mixer.wordToFading: unknown Fading value."

-- | Returns a `Channel`'s 'Fading' status.
--
-- Note that using 'AllChannels' here is not valid, and will simply return the
-- 'Fading' status of the first 'Channel' instead.
fading :: MonadIO m => Channel -> m Fading
fading (Channel c) = wordToFading <$> SDL.Raw.Mixer.fadingChannel c

-- | A group of 'Channel's.
--
-- Grouping 'Channel's together allows you to perform some operations on all of
-- them at once.
--
-- By default, all 'Channel's are members of the 'DefaultGroup'.
newtype Group = Group CInt deriving (Eq, Ord, Enum, Integral, Real, Num)

-- | The default 'Group' all 'Channel's are in the moment they are created.
pattern DefaultGroup = (-1) :: Group

-- | Assigns a given 'Channel' to a certain 'Group'.
--
-- If 'DefaultGroup' is used, assigns the 'Channel' the the default starting
-- 'Group' (essentially /ungrouping/ them).
--
-- If 'AllChannels' is used, assigns all 'Channel's to the given 'Group'.
--
-- Returns whether the 'Channel' was successfully grouped or not. Failure is
-- poosible if the 'Channel' does not exist, for instance.
group :: MonadIO m => Group -> Channel -> m Bool
group wrapped@(Group g) channel =
  case channel of
    AllChannels -> do
      total <- getChannels
      if total > 0 then
        (> 0) <$> groupSpan wrapped 0 (Channel $ fromIntegral $ total - 1)
      else
        return True -- No channels available -- still a success probably.
    Channel c ->
      (== 1) <$> SDL.Raw.Mixer.groupChannel c g

-- | Same as 'groupChannel', but groups all 'Channel's between the first and
-- last given, inclusive.
--
-- If 'DefaultGroup' is used, assigns the entire 'Channel' span to the default
-- starting 'Group' (essentially /ungrouping/ them).
--
-- Using 'AllChannels' is invalid.
--
-- Returns the number of 'Channel's successfully grouped. This number may be
-- less than the number of 'Channel's given, for instance if some of them do
-- not exist.
groupSpan :: MonadIO m => Group -> Channel -> Channel -> m Int
groupSpan (Group g) (Channel from) (Channel to) =
  fromIntegral <$> SDL.Raw.Mixer.groupChannels from to g

-- | Returns the number of 'Channels' within a 'Group'.
--
-- If 'DefaultGroup' is used, will return the number of all 'Channel's, since
-- all of them are within the default 'Group'.
groupCount :: MonadIO m => Group -> m Int
groupCount (Group g) = fromIntegral <$> SDL.Raw.Mixer.groupCount g

-- | Gets the first inactive (not playing) 'Channel' within a given 'Group',
-- if any.
--
-- Using 'DefaultGroup' will give you the first inactive 'Channel' out of all
-- that exist.
getAvailable :: MonadIO m => Group -> m (Maybe Channel)
getAvailable (Group g) = do
  found <- SDL.Raw.Mixer.groupAvailable g
  return $ if found >= 0 then Just $ fromIntegral found else Nothing

-- | Gets the oldest actively playing 'Channel' within a given 'Group'.
--
-- Returns 'Nothing' when the 'Group' is empty or no 'Channel's within it are
-- playing.
getOldest :: MonadIO m => Group -> m (Maybe Channel)
getOldest (Group g) = do
  found <- SDL.Raw.Mixer.groupOldest g
  return $ if found >= 0 then Just $ fromIntegral found else Nothing

-- | Gets the newest actively playing 'Channel' within a given 'Group'.
--
-- Returns 'Nothing' when the 'Group' is empty or no 'Channel's within it are
-- playing.
getNewest :: MonadIO m => Group -> m (Maybe Channel)
getNewest (Group g) = do
  found <- SDL.Raw.Mixer.groupNewer g
  return $ if found >= 0 then Just $ fromIntegral found else Nothing

-- | Returns the names of all music decoders currently available.
--
-- These depend on the availability of shared libraries for each of the
-- formats. The list may contain any of the following, and possibly others:
-- @WAVE@, @MODPLUG@, @MIKMOD@, @TIMIDITY@, @FLUIDSYNTH@, @NATIVEMIDI@, @OGG@,
-- @FLAC@, @MP3@.
musicDecoders :: MonadIO m => m [String]
musicDecoders =
  liftIO $ do
    num <- SDL.Raw.Mixer.getNumMusicDecoders
    forM [0 .. num - 1] $ \i ->
      SDL.Raw.Mixer.getMusicDecoder i >>= peekCString

-- | A loaded music file.
newtype Music = Music (Ptr SDL.Raw.Mixer.Music) deriving (Eq, Show)

instance Loadable Music where
  decode bytes = liftIO $ do
    unsafeUseAsCStringLen bytes $ \(cstr, len) -> do
      rw <- rwFromConstMem (castPtr cstr) (fromIntegral len)
      fmap Music .
        throwIfNull "SDL.Mixer.decode<Music>" "IMG_LoadMUS_RW" $
          SDL.Raw.Mixer.loadMUS_RW rw 0

  free (Music p) = liftIO $ SDL.Raw.Mixer.freeMusic p

-- Music
-- TODO: playMusic
-- TODO: fadeInMusic
-- TODO: fadeInMusicPos
-- TODO: hookMusic
-- TODO: volumeMusic
-- TODO: pauseMusic
-- TODO: resumeMusic
-- TODO: rewindMusic
-- TODO: setMusicPosition
-- TODO: setMusicCMD
-- TODO: haltMusic
-- TODO: fadeOutMusic
-- TODO: hookMusicFinished
-- TODO: getMusicType
-- TODO: playingMusic
-- TODO: pausedMusic
-- TODO: fadingMusic
-- TODO: getMusicHookData

-- Effects
-- TODO: registerEffect
-- TODO: unregisterEffect
-- TODO: unregisterAllEffects
-- TODO: setPostMix
-- TODO: setPanning
-- TODO: setDistance
-- TODO: setPosition
-- TODO: setReverseStereo

-- SoundFonts
-- TODO: setSynchroValue
-- TODO: getSynchroValue
-- TODO: setSoundFonts
-- TODO: getSoundFonts
-- TODO: eachSoundFont
