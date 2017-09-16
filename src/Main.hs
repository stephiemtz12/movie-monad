{-
  Movie Monad
  (C) 2017 David lettier
  lettier.com
-}

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Prelude
import Foreign.C.Types
import System.Process
import System.Exit
import System.FilePath
import Control.Monad
import Control.Exception
import Text.Read
import Data.IORef
import Data.Maybe
import Data.Int
import Data.Time.Clock.POSIX
import Data.Text
import Data.GI.Base
import Data.GI.Base.Signals
import Data.GI.Base.Properties
import Filesystem
import Filesystem.Path.CurrentOS
import GI.GLib
import GI.GObject
import qualified GI.Gtk
import GI.Gst
import GI.GstVideo
import GI.Gdk
import GI.GdkPixbuf
import GI.GdkX11
import qualified MovieMonadLib as MML
import Paths_movie_monad

-- Declare Element a type instance of IsVideoOverlay via a newtype wrapper
-- Our GStreamer element is playbin
-- Playbin implements the GStreamer VideoOverlay interface
newtype GstElement = GstElement GI.Gst.Element
instance GI.GstVideo.IsVideoOverlay GstElement

main :: IO ()
main = do
  _ <- GI.Gst.init Nothing
  _ <- GI.Gtk.init Nothing

  gladeFile <- getDataFileName "data/gui.glade"
  builder <- GI.Gtk.builderNewFromFile (pack gladeFile)

  window <- builderGetObject GI.Gtk.Window builder "window"
  fileChooserButton <- builderGetObject GI.Gtk.Button builder "file-chooser-button"
  fileChooserButtonLabel <- builderGetObject GI.Gtk.Label builder "file-chooser-button-label"
  fileChooserDialog <- builderGetObject GI.Gtk.Dialog builder "file-chooser-dialog"
  fileChooserEntry <- builderGetObject GI.Gtk.Entry builder "file-chooser-entry"
  fileChooserWidget <- builderGetObject GI.Gtk.FileChooserWidget builder "file-chooser-widget"
  fileChooserCancelButton <- builderGetObject GI.Gtk.Button builder "file-chooser-cancel-button"
  fileChooserOpenButton <- builderGetObject GI.Gtk.Button builder "file-chooser-open-button"
  drawingAreaEventBox <- builderGetObject GI.Gtk.EventBox builder "drawing-area-event-box"
  drawingArea <- builderGetObject GI.Gtk.Widget builder "drawing-area"
  bottomControlsGtkBox <- builderGetObject GI.Gtk.Box builder "bottom-controls-gtk-box"
  seekScale <- builderGetObject GI.Gtk.Scale builder "seek-scale"
  onOffSwitch <- builderGetObject GI.Gtk.Switch builder "on-off-switch"
  volumeButton <- builderGetObject GI.Gtk.VolumeButton builder "volume-button"
  desiredVideoWidthComboBox <- builderGetObject GI.Gtk.ComboBoxText builder "desired-video-width-combo-box"
  fullscreenButton <- builderGetObject GI.Gtk.Button builder "fullscreen-button"
  bufferingSpinner <- builderGetObject GI.Gtk.Spinner builder "buffering-spinner"
  errorMessageDialog <- builderGetObject GI.Gtk.MessageDialog builder "error-message-dialog"
  aboutButton <- builderGetObject GI.Gtk.Button builder "about-button"
  aboutDialog <- builderGetObject GI.Gtk.AboutDialog builder "about-dialog"

  logoFile <- getDataFileName "data/movie-monad-logo.svg"
  logo <- GI.GdkPixbuf.pixbufNewFromFile (pack logoFile)
  GI.Gtk.aboutDialogSetLogo aboutDialog (Just logo)

  -- Glade does not allow us to use the response ID nicknames so we setup them up programmatically here.
  GI.Gtk.dialogAddActionWidget fileChooserDialog fileChooserCancelButton (enumToInt32 GI.Gtk.ResponseTypeCancel)
  GI.Gtk.dialogAddActionWidget fileChooserDialog fileChooserOpenButton   (enumToInt32 GI.Gtk.ResponseTypeOk)

  playbin <- fromJust <$> GI.Gst.elementFactoryMake "playbin" (Just "MultimediaPlayer")

  isWindowFullScreenRef <- newIORef False
  mouseMovedLastRef <- newIORef 0
  previousFileNamePathRef <- newIORef ""
  videoInfoRef <- newIORef MML.defaultVideoInfo

  bus <- GI.Gst.elementGetBus playbin

  _ <- GI.Gtk.onWidgetRealize drawingArea (
      onDrawingAreaRealize
        window
        fileChooserButton
        drawingAreaEventBox
        drawingArea
        playbin
        seekScale
        onOffSwitch
        desiredVideoWidthComboBox
        fullscreenButton
    )

  _ <- GI.Gtk.onDialogResponse errorMessageDialog (\ _ -> GI.Gtk.widgetHide errorMessageDialog)

  _ <- GI.Gst.busAddWatch bus GI.GLib.PRIORITY_DEFAULT (
      handlePlaybinBustMessage
        window
        fileChooserButton
        drawingAreaEventBox
        drawingArea
        playbin
        seekScale
        onOffSwitch
        desiredVideoWidthComboBox
        fullscreenButton
        fileChooserEntry
        fileChooserButtonLabel
        volumeButton
        errorMessageDialog
        bufferingSpinner
    )

  _ <- GI.Gtk.onWidgetButtonReleaseEvent fileChooserButton (
      onFileChooserButtonClick
        fileChooserEntry
        fileChooserDialog
        previousFileNamePathRef
    )

  _ <- GI.Gtk.onDialogResponse fileChooserDialog (
      fileChooserDialogResponseHandler
        window
        fileChooserButton
        drawingAreaEventBox
        drawingArea
        playbin
        seekScale
        onOffSwitch
        desiredVideoWidthComboBox
        fullscreenButton
        fileChooserEntry
        fileChooserButtonLabel
        volumeButton
        errorMessageDialog
        fileChooserDialog
        isWindowFullScreenRef
        videoInfoRef
        previousFileNamePathRef
    )

  _ <- GI.Gtk.onFileChooserSelectionChanged fileChooserWidget (
      fileChooserSelectionChangedHandler
        fileChooserWidget
        videoInfoRef
        fileChooserEntry
    )

  _ <- GI.Gtk.onEntryIconRelease fileChooserEntry $ \ _ _ -> GI.Gtk.entrySetText fileChooserEntry ""

  _ <- GI.Gtk.onSwitchStateSet onOffSwitch (onSwitchStateSet playbin)

  _ <- GI.Gtk.onScaleButtonValueChanged volumeButton (onScaleButtonValueChanged playbin)

  seekScaleHandlerId <- GI.Gtk.onRangeValueChanged seekScale (
      onRangeValueChanged
        playbin
        seekScale
        videoInfoRef
    )

  _ <- GI.GLib.timeoutAdd GI.GLib.PRIORITY_DEFAULT 41 (
      updateSeekScale
        playbin
        seekScale
        seekScaleHandlerId
    )

  _ <- GI.GLib.timeoutAddSeconds GI.GLib.PRIORITY_DEFAULT 1 (
      hideBottomControlsAndCursorIfFullscreenAndIdle
        isWindowFullScreenRef
        mouseMovedLastRef
        bottomControlsGtkBox
        window
    )

  _ <- GI.Gtk.onComboBoxChanged desiredVideoWidthComboBox (
      onComboBoxChanged
        window
        fileChooserButton
        drawingAreaEventBox
        drawingArea
        seekScale
        onOffSwitch
        desiredVideoWidthComboBox
        fullscreenButton
        fileChooserEntry
        videoInfoRef
    )

  _ <- GI.Gtk.onWidgetButtonReleaseEvent fullscreenButton (
      onFullscreenButtonRelease
        isWindowFullScreenRef
        window
        fileChooserButton
        desiredVideoWidthComboBox
    )

  _ <- GI.Gtk.onWidgetMotionNotifyEvent window    (onWindowMouseMove bottomControlsGtkBox mouseMovedLastRef window)
  _ <- GI.Gtk.onWidgetMotionNotifyEvent seekScale (onWindowMouseMove bottomControlsGtkBox mouseMovedLastRef window)

  _ <- GI.Gtk.onWidgetWindowStateEvent window (onWidgetWindowStateEvent isWindowFullScreenRef)

  _ <- GI.Gtk.onWidgetButtonReleaseEvent aboutButton (onAboutButtonRelease aboutDialog)

  _ <- GI.Gtk.onWidgetDestroy window (onWindowDestroy playbin)

  GI.Gtk.widgetShowAll window
  GI.Gtk.main

hideBottomControlsInterval :: Integral a => a
hideBottomControlsInterval = 5

builderGetObject ::
  (GI.GObject.GObject b, GI.Gtk.IsBuilder a) =>
  (Data.GI.Base.ManagedPtr b -> b) ->
  a ->
  Prelude.String ->
  IO b
builderGetObject objectTypeClass builder objectId =
  fromJust <$> GI.Gtk.builderGetObject builder (pack objectId) >>=
    GI.Gtk.unsafeCastTo objectTypeClass

onDrawingAreaRealize ::
  GI.Gtk.Window ->
  GI.Gtk.Button ->
  GI.Gtk.EventBox ->
  GI.Gtk.Widget ->
  GI.Gst.Element ->
  GI.Gtk.Scale ->
  GI.Gtk.Switch ->
  GI.Gtk.ComboBoxText ->
  GI.Gtk.Button ->
  GI.Gtk.WidgetRealizeCallback
onDrawingAreaRealize
  window
  fileChooserButton
  drawingAreaEventBox
  drawingArea
  playbin
  seekScale
  onOffSwitch
  desiredVideoWidthComboBox
  fullscreenButton
  = do
  gdkWindow <- fromJust <$> GI.Gtk.widgetGetWindow drawingArea
  x11Window <- GI.Gtk.unsafeCastTo GI.GdkX11.X11Window gdkWindow
  xid <- GI.GdkX11.x11WindowGetXid x11Window
  let xid' = fromIntegral xid :: CUIntPtr
  GI.GstVideo.videoOverlaySetWindowHandle (GstElement playbin) xid'
  let eventMask = enumToInt32 GI.Gdk.EventMaskAllEventsMask
  GI.Gtk.widgetAddEvents drawingArea eventMask
  GI.Gtk.widgetAddEvents seekScale eventMask
  resetWindow
    window
    fileChooserButton
    drawingAreaEventBox
    drawingArea
    seekScale
    onOffSwitch
    desiredVideoWidthComboBox
    fullscreenButton

handlePlaybinBustMessage ::
  GI.Gtk.Window ->
  GI.Gtk.Button ->
  GI.Gtk.EventBox ->
  GI.Gtk.Widget ->
  GI.Gst.Element ->
  GI.Gtk.Scale ->
  GI.Gtk.Switch ->
  GI.Gtk.ComboBoxText ->
  GI.Gtk.Button ->
  GI.Gtk.Entry ->
  GI.Gtk.Label ->
  GI.Gtk.VolumeButton ->
  GI.Gtk.MessageDialog ->
  GI.Gtk.Spinner ->
  GI.Gst.Bus ->
  GI.Gst.Message ->
  IO Bool
handlePlaybinBustMessage
  window
  fileChooserButton
  drawingAreaEventBox
  drawingArea
  playbin
  seekScale
  onOffSwitch
  desiredVideoWidthComboBox
  fullscreenButton
  fileChooserEntry
  fileChooserButtonLabel
  volumeButton
  errorMessageDialog
  bufferingSpinner
  _
  message
  = do
  messageTypes <- GI.Gst.getMessageType message
  let messageType = case messageTypes of
                      [] -> GI.Gst.MessageTypeUnknown
                      (msg:_) -> msg
  entryText <- GI.Gtk.entryGetText fileChooserEntry
  labelText <- GI.Gtk.labelGetText fileChooserButtonLabel
  when (
      messageType == GI.Gst.MessageTypeError &&
      (
        (not . Data.Text.null) entryText ||
        labelText /= "Open"
      )
    ) $ do
      (gError, text) <- GI.Gst.messageParseError message
      gErrorText <- GI.Gst.gerrorMessage gError
      print text
      print gErrorText
      GI.Gtk.entrySetText fileChooserEntry ""
      GI.Gtk.labelSetText fileChooserButtonLabel "Open"
      _ <- GI.Gst.elementSetState playbin GI.Gst.StateNull
      setPlaybinUriAndVolume playbin "" volumeButton
      resetWindow
        window
        fileChooserButton
        drawingAreaEventBox
        drawingArea
        seekScale
        onOffSwitch
        desiredVideoWidthComboBox
        fullscreenButton
      void $ GI.Gtk.dialogRun errorMessageDialog
  when (messageType == GI.Gst.MessageTypeBuffering) $ do
    percent <- GI.Gst.messageParseBuffering message
    isPlaying <- GI.Gtk.getSwitchActive onOffSwitch
    if percent >= 100
      then do
        GI.Gtk.setSpinnerActive bufferingSpinner False
        GI.Gtk.widgetSetSensitive seekScale True
        when isPlaying $ void $ GI.Gst.elementSetState playbin GI.Gst.StatePlaying
      else do
        GI.Gtk.setSpinnerActive bufferingSpinner True
        GI.Gtk.widgetSetSensitive seekScale False
        void $ GI.Gst.elementSetState playbin GI.Gst.StatePaused
    return ()
  return True

fileChooserDialogResponseHandler ::
  GI.Gtk.Window ->
  GI.Gtk.Button ->
  GI.Gtk.EventBox ->
  GI.Gtk.Widget ->
  GI.Gst.Element ->
  GI.Gtk.Scale ->
  GI.Gtk.Switch ->
  GI.Gtk.ComboBoxText ->
  GI.Gtk.Button ->
  GI.Gtk.Entry ->
  GI.Gtk.Label ->
  GI.Gtk.VolumeButton ->
  GI.Gtk.MessageDialog ->
  GI.Gtk.Dialog ->
  IORef Bool ->
  IORef MML.VideoInfo ->
  IORef Data.Text.Text ->
  Int32 ->
  IO ()
fileChooserDialogResponseHandler
  window
  fileChooserButton
  drawingAreaEventBox
  drawingArea
  playbin
  seekScale
  onOffSwitch
  desiredVideoWidthComboBox
  fullscreenButton
  fileChooserEntry
  fileChooserButtonLabel
  volumeButton
  errorMessageDialog
  fileChooserDialog
  isWindowFullScreenRef
  videoInfoRef
  previousFileNamePathRef
  responseId
  = do
  GI.Gtk.widgetHide fileChooserDialog
  handleResponseType GI.Gtk.ResponseTypeOk
  where
    handleResponseType :: (Enum a, Ord a) => a -> IO ()
    handleResponseType enum
      | enumToInt32 enum == responseId = do
        _ <- GI.Gst.elementSetState playbin GI.Gst.StateNull
        filePathName <- GI.Gtk.entryGetText fileChooserEntry
        let filePathNameStr = Data.Text.unpack filePathName
        (_, fileNameEmpty) <- setFileChooserButtonLabel fileChooserButtonLabel filePathName
        isWindowFullScreen <- readIORef isWindowFullScreenRef
        desiredVideoWidth <- getDesiredVideoWidth desiredVideoWidthComboBox
        setPlaybinUriAndVolume playbin filePathNameStr volumeButton
        handleFileName
          fileNameEmpty
          filePathNameStr
          isWindowFullScreen
          desiredVideoWidth
      | otherwise = do
        filePathName <- readIORef previousFileNamePathRef
        _ <- setFileChooserButtonLabel fileChooserButtonLabel filePathName
        GI.Gtk.entrySetText fileChooserEntry filePathName
    handleFileName ::
      Bool ->
      Prelude.String ->
      Bool ->
      Int ->
      IO ()
    handleFileName True _ _ _ =
      resetWindow
        window
        fileChooserButton
        drawingAreaEventBox
        drawingArea
        seekScale
        onOffSwitch
        desiredVideoWidthComboBox
        fullscreenButton
    handleFileName
      _
      filePathNameStr
      isWindowFullScreen
      desiredVideoWidth
      = do
      retrievedVideoInfo <- getVideoInfo videoInfoRef filePathNameStr
      maybeWindowSize <- getWindowSize desiredVideoWidth retrievedVideoInfo
      GI.Gtk.widgetSetSensitive seekScale True
      if MML.isSeekable retrievedVideoInfo
        then GI.Gtk.widgetShow seekScale
        else GI.Gtk.widgetHide seekScale
      case maybeWindowSize of
        Nothing -> do
          resetWindow
            window
            fileChooserButton
            drawingAreaEventBox
            drawingArea
            seekScale
            onOffSwitch
            desiredVideoWidthComboBox
            fullscreenButton
          void $ GI.Gtk.dialogRun errorMessageDialog
        Just (width, height) -> do
          GI.Gtk.widgetShow onOffSwitch
          GI.Gtk.widgetShow drawingAreaEventBox
          GI.Gtk.widgetShow drawingArea
          GI.Gtk.widgetShow fullscreenButton
          GI.Gtk.switchSetActive onOffSwitch True
          unless isWindowFullScreen $
            setWindowSize width height fileChooserButton drawingArea window
          void $ GI.Gst.elementSetState playbin GI.Gst.StatePlaying

onFileChooserButtonClick ::
  GI.Gtk.Entry ->
  GI.Gtk.Dialog ->
  IORef Data.Text.Text ->
  GI.Gdk.EventButton ->
  IO Bool
onFileChooserButtonClick
  fileChooserEntry
  fileChooserDialog
  previousFileNamePathRef
  _
  = do
  text <- GI.Gtk.entryGetText fileChooserEntry
  atomicWriteIORef previousFileNamePathRef text
  _ <- GI.Gtk.dialogRun fileChooserDialog
  return True

fileChooserSelectionChangedHandler ::
  GI.Gtk.FileChooserWidget ->
  IORef MML.VideoInfo ->
  GI.Gtk.Entry ->
  IO ()
fileChooserSelectionChangedHandler
  fileChooserWidget
  videoInfoRef
  fileChooserEntry
  = do
  maybeUri <- GI.Gtk.fileChooserGetUri fileChooserWidget
  case maybeUri of
    Nothing -> return ()
    Just uri -> do
      let uriStr = Data.Text.unpack uri
      local <- isLocalFile uriStr
      video <- MML.isVideo <$> getVideoInfo videoInfoRef uriStr
      GI.Gtk.entrySetText fileChooserEntry (if local && video then uri else "")

onSwitchStateSet ::
  GI.Gst.Element ->
  Bool ->
  IO Bool
onSwitchStateSet playbin switchOn = do
  if switchOn
    then void $ GI.Gst.elementSetState playbin GI.Gst.StatePlaying
    else void $ GI.Gst.elementSetState playbin GI.Gst.StatePaused
  return switchOn

onScaleButtonValueChanged ::
  GI.Gst.Element ->
  Double ->
  IO ()
onScaleButtonValueChanged playbin volume =
    void $ Data.GI.Base.Properties.setObjectPropertyDouble playbin "volume" volume

seekRequestLastDeltaThreshold :: MML.VideoInfo -> POSIXTime
seekRequestLastDeltaThreshold MML.VideoInfo { MML.isLocalFile = True }  = 0.0
seekRequestLastDeltaThreshold MML.VideoInfo { MML.isLocalFile = False } = 0.0

onRangeValueChanged ::
  GI.Gst.Element ->
  GI.Gtk.Scale ->
  IORef MML.VideoInfo ->
  IO ()
onRangeValueChanged
  playbin
  seekScale
  videoInfoRef
  = do
  (couldQueryDuration, duration) <- GI.Gst.elementQueryDuration playbin GI.Gst.FormatTime
  when couldQueryDuration $ do
    percentage' <- GI.Gtk.rangeGetValue seekScale
    let percentage = percentage' / 100.0
    let position = fromIntegral (round ((fromIntegral duration :: Double) * percentage) :: Int) :: Int64
    void $ GI.Gst.elementSeekSimple playbin GI.Gst.FormatTime [ GI.Gst.SeekFlagsFlush ] position
    videoInfoGathered <- readIORef videoInfoRef
    -- When playing over a network (not local),
    -- sending too many asynchronous seek requests will cause GStreamer to error.
    -- Block until this seek request finishes which will block the main GTK main thread.
    -- Note that by blocking here, the seek scale will not slide.
    -- The user will have to point and click on the scale track.
    unless (MML.isLocalFile videoInfoGathered) $ void $ GI.Gst.elementGetState playbin GI.Gst.CLOCK_TIME_NONE

updateSeekScale ::
  GI.Gst.Element ->
  GI.Gtk.Scale ->
  Data.GI.Base.Signals.SignalHandlerId ->
  IO Bool
updateSeekScale
  playbin
  seekScale
  seekScaleHandlerId
  = do
  (couldQueryDuration, duration) <- GI.Gst.elementQueryDuration playbin GI.Gst.FormatTime
  (couldQueryPosition, position) <- GI.Gst.elementQueryPosition playbin GI.Gst.FormatTime
  when (couldQueryDuration && couldQueryPosition && duration > 0) $ do
    let percentage = 100.0 * (fromIntegral position / fromIntegral duration :: Double)
    GI.GObject.signalHandlerBlock seekScale seekScaleHandlerId
    GI.Gtk.rangeSetValue seekScale percentage
    GI.GObject.signalHandlerUnblock seekScale seekScaleHandlerId
  return True

onWindowMouseMove ::
  GI.Gtk.Box ->
  IORef Integer ->
  GI.Gtk.Window ->
  GI.Gdk.EventMotion ->
  IO Bool
onWindowMouseMove bottomControlsGtkBox mouseMovedLastRef window _ =
  GI.Gtk.widgetShow bottomControlsGtkBox >>
  getPOSIXTime >>=
  atomicWriteIORef mouseMovedLastRef . round >>
  setCursor window Nothing >>
  return False

hideBottomControlsAndCursorIfFullscreenAndIdle ::
  IORef Bool ->
  IORef Integer ->
  GI.Gtk.Box ->
  GI.Gtk.Window ->
  IO Bool
hideBottomControlsAndCursorIfFullscreenAndIdle
  isWindowFullScreenRef
  mouseMovedLastRef
  bottomControlsGtkBox
  window
  = do
  isWindowFullScreen <- readIORef isWindowFullScreenRef
  mouseMovedLast <- readIORef mouseMovedLastRef
  timeNow <- fmap round getPOSIXTime
  let delta = timeNow - mouseMovedLast
  when (isWindowFullScreen && delta >= hideBottomControlsInterval) $ do
    GI.Gtk.widgetHide bottomControlsGtkBox
    setCursor window (Just "none")
  when (delta >= hideBottomControlsInterval) $ atomicWriteIORef mouseMovedLastRef timeNow
  return True

onComboBoxChanged ::
  GI.Gtk.Window ->
  GI.Gtk.Button ->
  GI.Gtk.EventBox ->
  GI.Gtk.Widget ->
  GI.Gtk.Scale ->
  GI.Gtk.Switch ->
  GI.Gtk.ComboBoxText ->
  GI.Gtk.Button ->
  GI.Gtk.Entry ->
  IORef MML.VideoInfo ->
  IO ()
onComboBoxChanged
  window
  fileChooserButton
  drawingAreaEventBox
  drawingArea
  seekScale
  onOffSwitch
  desiredVideoWidthComboBox
  fullscreenButton
  fileChooserEntry
  videoInfoRef
  = do
  filePathName <- Data.Text.unpack <$> GI.Gtk.entryGetText fileChooserEntry
  desiredVideoWidth <- getDesiredVideoWidth desiredVideoWidthComboBox
  retrievedVideoInfo <- getVideoInfo videoInfoRef filePathName
  maybeWindowSize <- getWindowSize desiredVideoWidth retrievedVideoInfo
  case maybeWindowSize of
    Nothing ->
      resetWindow
        window
        fileChooserButton
        drawingAreaEventBox
        drawingArea
        seekScale
        onOffSwitch
        desiredVideoWidthComboBox
        fullscreenButton
    Just (width, height) -> setWindowSize width height fileChooserButton drawingArea window

onFullscreenButtonRelease ::
  IORef Bool ->
  GI.Gtk.Window ->
  GI.Gtk.Button ->
  GI.Gtk.ComboBoxText ->
  GI.Gdk.EventButton ->
  IO Bool
onFullscreenButtonRelease
  isWindowFullScreenRef
  window
  fileChooserButton
  desiredVideoWidthComboBox
  _
  = do
  isWindowFullScreen <- readIORef isWindowFullScreenRef
  if isWindowFullScreen
    then do
      GI.Gtk.widgetShow desiredVideoWidthComboBox
      GI.Gtk.widgetShow fileChooserButton
      void $ GI.Gtk.windowUnfullscreen window
    else do
      GI.Gtk.widgetHide desiredVideoWidthComboBox
      GI.Gtk.widgetHide fileChooserButton
      void $ GI.Gtk.windowFullscreen window
  return True

onWidgetWindowStateEvent ::
  IORef Bool ->
  GI.Gdk.EventWindowState ->
  IO Bool
onWidgetWindowStateEvent isWindowFullScreenRef eventWindowState = do
  windowStates <- GI.Gdk.getEventWindowStateNewWindowState eventWindowState
  let isWindowFullScreen = Prelude.foldl (\ acc x ->
          acc || GI.Gdk.WindowStateFullscreen == x
        ) False windowStates
  atomicWriteIORef isWindowFullScreenRef isWindowFullScreen
  return True

onAboutButtonRelease ::
  GI.Gtk.AboutDialog ->
  GI.Gdk.EventButton ->
  IO Bool
onAboutButtonRelease aboutDialog _ = do
  _ <- GI.Gtk.onDialogResponse aboutDialog (\ _ -> GI.Gtk.widgetHide aboutDialog)
  _ <- GI.Gtk.dialogRun aboutDialog
  return True

onWindowDestroy ::
  GI.Gst.Element ->
  IO ()
onWindowDestroy playbin = do
  _ <- GI.Gst.elementSetState playbin GI.Gst.StateNull
  _ <- GI.Gst.objectUnref playbin
  GI.Gtk.mainQuit

setPlaybinUriAndVolume ::
  GI.Gst.Element ->
  Prelude.String ->
  GI.Gtk.VolumeButton ->
  IO ()
setPlaybinUriAndVolume playbin fileName volumeButton = do
  uri <- addUriSchemeIfNone fileName
  volume <- GI.Gtk.scaleButtonGetValue volumeButton
  Data.GI.Base.Properties.setObjectPropertyDouble playbin "volume" volume
  Data.GI.Base.Properties.setObjectPropertyString playbin "uri" (Just $ pack uri)

getVideoInfoRaw :: Prelude.String -> IO (Maybe Prelude.String)
getVideoInfoRaw uri = do
  (code, out, _) <- catch (
      readProcessWithExitCode
        "gst-discoverer-1.0"
        [uri, "-v"]
        ""
    ) (\ (_ :: Control.Exception.IOException) -> return (ExitFailure 1, "", ""))
  if code == System.Exit.ExitSuccess
    then return (Just out)
    else return Nothing

getVideoInfo :: IORef MML.VideoInfo -> Prelude.String -> IO MML.VideoInfo
getVideoInfo videoInfoRef filePathName = do
  videoInfoGathered <- readIORef videoInfoRef
  uri <- addUriSchemeIfNone filePathName
  cacheDo (MML.uri videoInfoGathered == uri) videoInfoGathered uri
  where
    widthField :: Data.Text.Text
    widthField = "width: "
    heightField :: Data.Text.Text
    heightField = "height: "
    seekableField :: Data.Text.Text
    seekableField = "seekable: "
    cacheDo :: Bool -> MML.VideoInfo -> Prelude.String -> IO MML.VideoInfo
    cacheDo True  videoInfoGathered _   = return videoInfoGathered
    cacheDo False _                 uri = do
      videoInfoRaw <- getVideoInfoRaw uri
      processVideoInfoRaw videoInfoRaw uri
    processVideoInfoRaw :: Maybe Prelude.String -> Prelude.String -> IO MML.VideoInfo
    processVideoInfoRaw Nothing _ = do
      let videoInfoGathered = MML.defaultVideoInfo
      atomicWriteIORef videoInfoRef videoInfoGathered
      return videoInfoGathered
    processVideoInfoRaw (Just str) uri = do
      let text      = Data.Text.toLower $ Data.Text.pack str
      let textLines = Data.Text.lines text
      let videoInfoGathered = MML.VideoInfo {
              MML.uri          = uri
            , MML.isLocalFile  = hasFileUriScheme uri
            , MML.isVideo      = "video: video/" `Data.Text.isInfixOf` text
            , MML.isSeekable   = "yes" == getField seekableField textLines
            , MML.videoWidth   = getDimension MML.videoWidth  widthField textLines
            , MML.videoHeight  = getDimension MML.videoHeight heightField textLines
          }
      atomicWriteIORef videoInfoRef videoInfoGathered
      return videoInfoGathered
    getDimension :: (MML.VideoInfo -> Int) -> Data.Text.Text -> [Data.Text.Text] -> Int
    getDimension f field lines' = fromMaybe (
        f MML.defaultVideoInfo
      ) (readMaybe (Data.Text.unpack $ getField field lines') :: Maybe Int)
    getField :: Data.Text.Text -> [Data.Text.Text] -> Data.Text.Text
    getField field =
      Prelude.foldl (\ acc l ->
          if not $ Data.Text.null acc
            then acc
            else if field `Data.Text.isInfixOf` l
              then Data.Text.replace field "" $ Data.Text.strip l
              else ""
        ) ""

getWindowSize :: Int -> MML.VideoInfo -> IO (Maybe (Int32, Int32))
getWindowSize desiredVideoWidth retrievedVideoInfo =
  widthHeightToDouble retrievedVideoInfo >>=
  ratio >>=
  windowSize
  where
    widthHeightToDouble :: MML.VideoInfo -> IO (Maybe Double, Maybe Double)
    widthHeightToDouble MML.VideoInfo { MML.isVideo = False } = return (Nothing, Nothing)
    widthHeightToDouble MML.VideoInfo { MML.videoWidth = w, MML.videoHeight = h } =
      return (Just $ fromIntegral w :: Maybe Double, Just $ fromIntegral h :: Maybe Double)
    ratio :: (Maybe Double, Maybe Double) -> IO (Maybe Double)
    ratio (Just width, Just height) =
      if width <= 0.0 then return Nothing else return (Just (height / width))
    ratio _ = return Nothing
    windowSize :: Maybe Double -> IO (Maybe (Int32, Int32))
    windowSize Nothing = return Nothing
    windowSize (Just ratio') =
      return (
          Just (
                fromIntegral desiredVideoWidth :: Int32
              , round ((fromIntegral desiredVideoWidth :: Double) *  ratio') :: Int32
            )
        )

getDesiredVideoWidth :: GI.Gtk.ComboBoxText -> IO Int
getDesiredVideoWidth = fmap (\ x -> read (Data.Text.unpack x) :: Int) . GI.Gtk.comboBoxTextGetActiveText

setWindowSize ::
  Int32 ->
  Int32 ->
  GI.Gtk.Button ->
  GI.Gtk.Widget ->
  GI.Gtk.Window ->
  IO ()
setWindowSize width height fileChooserButton drawingArea window = do
  GI.Gtk.setWidgetWidthRequest fileChooserButton width
  GI.Gtk.setWidgetWidthRequest drawingArea width
  GI.Gtk.setWidgetHeightRequest drawingArea height
  GI.Gtk.setWidgetWidthRequest window width
  GI.Gtk.setWidgetHeightRequest window height
  GI.Gtk.windowResize window width (if height <= 0 then 1 else height)

resetWindow ::
  GI.Gtk.Window ->
  GI.Gtk.Button ->
  GI.Gtk.EventBox ->
  GI.Gtk.Widget ->
  GI.Gtk.Scale ->
  GI.Gtk.Switch ->
  GI.Gtk.ComboBoxText ->
  GI.Gtk.Button ->
  IO ()
resetWindow
  window
  fileChooserButton
  drawingAreaEventBox
  drawingArea
  seekScale
  onOffSwitch
  desiredVideoWidthComboBox
  fullscreenButton
  = do
  desiredVideoWidth <- getDesiredVideoWidth desiredVideoWidthComboBox
  let width = fromIntegral desiredVideoWidth :: Int32
  GI.Gtk.windowUnfullscreen window
  GI.Gtk.switchSetActive onOffSwitch False
  GI.Gtk.widgetHide drawingAreaEventBox
  GI.Gtk.widgetHide drawingArea
  GI.Gtk.widgetHide seekScale
  GI.Gtk.widgetHide onOffSwitch
  GI.Gtk.widgetShow desiredVideoWidthComboBox
  GI.Gtk.widgetHide fullscreenButton
  setWindowSize width 0 fileChooserButton drawingArea window

setFileChooserButtonLabel :: GI.Gtk.Label -> Data.Text.Text -> IO (Data.Text.Text, Bool)
setFileChooserButtonLabel fileChooserButtonLabel filePathName = do
  let fileName = fileNameFromFilePathName filePathName
  let fileNameEmpty = isTextEmpty fileName
  GI.Gtk.labelSetText fileChooserButtonLabel (if fileNameEmpty then "Open" else fileName)
  return (fileName, fileNameEmpty)

fileNameFromFilePathName :: Data.Text.Text -> Data.Text.Text
fileNameFromFilePathName = Data.Text.pack . System.FilePath.takeFileName . Data.Text.unpack

setCursor :: GI.Gtk.Window -> Maybe Text -> IO ()
setCursor window Nothing =
  fromJust <$> GI.Gtk.widgetGetWindow window >>=
  flip GI.Gdk.windowSetCursor (Nothing :: Maybe GI.Gdk.Cursor)
setCursor window (Just cursorType) = do
  gdkWindow <- fromJust <$> GI.Gtk.widgetGetWindow window
  maybeCursor <- makeCursor gdkWindow cursorType
  GI.Gdk.windowSetCursor gdkWindow maybeCursor

makeCursor :: GI.Gdk.Window -> Text -> IO (Maybe GI.Gdk.Cursor)
makeCursor window cursorType =
  GI.Gdk.windowGetDisplay window >>=
  flip GI.Gdk.cursorNewFromName cursorType

isLocalFile :: Prelude.String -> IO Bool
isLocalFile = Filesystem.isFile . Filesystem.Path.CurrentOS.fromText . Data.Text.pack . removeFileUriScheme

enumToInt32 :: (Enum a, Ord a) => a -> Int32
enumToInt32 enum = fromIntegral (fromEnum enum) :: Int32

isTextEmpty :: Data.Text.Text -> Bool
isTextEmpty = Data.Text.null . Data.Text.strip

removeFileUriScheme :: Prelude.String -> Prelude.String
removeFileUriScheme str =
  if hasFileUriScheme str
    then Data.Text.unpack $ Data.Text.replace "file://" "" uri
    else Data.Text.unpack uri
  where
    uri :: Data.Text.Text
    uri = Data.Text.pack str

hasFileUriScheme :: Prelude.String -> Bool
hasFileUriScheme = hasUriScheme "file://"

hasHttpUriScheme :: Prelude.String -> Bool
hasHttpUriScheme str = isHttp || isHttps
  where
    isHttp :: Bool
    isHttp  = hasUriScheme "http://"  str
    isHttps :: Bool
    isHttps = hasUriScheme "https://" str

hasUriScheme :: Prelude.String -> Prelude.String -> Bool
hasUriScheme scheme uri = toLower' scheme `Data.Text.isPrefixOf` toLower' uri
  where
    toLower' :: Prelude.String -> Text
    toLower' = Data.Text.toLower . Data.Text.pack

addUriSchemeIfNone :: Prelude.String -> IO Prelude.String
addUriSchemeIfNone filePathName =
  isLocalFile filePathName >>=
  \ local ->
    return $
      if local
        then if hasFileUriScheme filePathName then filePathName else "file://" ++ filePathName
        else if hasHttpUriScheme filePathName then filePathName else "http://" ++ filePathName
