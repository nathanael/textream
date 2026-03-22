# Hand Gesture Rewind — Design Spec

## Problem

When presenting with Textream, the speaker sometimes needs to go back a few sentences in the script — to re-read a section, correct a mistake, or recover after going off-script. Currently there is no hands-free way to rewind. The speaker would have to walk to the laptop and tap the screen.

## Solution

Use the Mac's front-facing camera and Apple's Vision framework to detect a raised hand. While the hand is raised, the script rewinds continuously. Hand height controls rewind speed — higher hand = faster rewind. Lowering the hand resumes normal operation.

## Hand Detection Pipeline

A new `HandGestureController` class owns camera capture and Vision processing:

1. **AVCaptureSession** captures frames from the default front-facing camera at low resolution (~640x480) and low frame rate (~15fps)
2. Each frame is processed by **VNDetectHumanHandPoseRequest** which returns hand landmark coordinates
3. The **wrist Y-position** (0.0 = bottom of frame, 1.0 = top in Vision coordinates) is extracted and smoothed with a rolling average of the last 3-4 frames to reduce jitter
4. A **raise threshold** (wrist Y > 0.6) determines whether the hand is raised. Below this, the hand is in the speaker's lap or at their side and is ignored
5. The controller publishes two observable values:
   - `isHandRaised: Bool`
   - `handHeight: Float` (0.0 = just above threshold, 1.0 = top of frame)

### Lifecycle

- Camera starts when a reading session begins (`SpeechRecognizer.start()`)
- Camera stops when the reading session ends (`SpeechRecognizer.stop()`)
- Camera is NOT running when the app is idle

### Camera Selection

Uses the default front-facing camera. No settings UI for camera selection in this iteration.

## Rewind Behavior

### When hand is raised (`isHandRaised` becomes true):

1. **Pause speech recognition** — stop the audio engine and recognition task without setting `isListening = false` (we intend to resume)
2. **Start a rewind timer** — a `Timer` firing every 0.25 seconds
3. Each tick moves `recognizedCharCount` backward by N words (finding previous space characters in `sourceText`). The `handHeight` value controls speed:
   - Low hand (0.0–0.3): 1 word per tick (~4 words/sec)
   - Mid hand (0.3–0.7): 2 words per tick (~8 words/sec)
   - High hand (0.7–1.0): 4 words per tick (~16 words/sec)
4. `recognizedCharCount` is clamped to never go below 0

### When hand is lowered (`isHandRaised` becomes false):

Behavior depends on the current `ListeningMode`:

- **wordTracking:** Immediately set `matchStartOffset = recognizedCharCount` and call `beginRecognition()` to resume speech tracking from the new position
- **classic / silencePaused:** Wait 1.5 seconds before resuming auto-scroll from the new position

### Visual Feedback

MarqueeTextView already observes `recognizedCharCount` and animates scroll position — the rewind will visually scroll backward with no additional UI work needed.

## File Organization

### New File

| File | Responsibility |
|------|---------------|
| `HandGestureController.swift` | AVCaptureSession setup, VNDetectHumanHandPoseRequest processing, wrist position smoothing, publishes `isHandRaised` and `handHeight` |

### Modified Files

| File | Change |
|------|--------|
| `SpeechRecognizer.swift` | Add `HandGestureController` property, start/stop camera with reading session, rewind logic on hand raise, resume logic on hand lower |
| `Info.plist` | Add `NSCameraUsageDescription` for camera permission prompt |

### Unchanged

MarqueeTextView, NotchSettings, ContentView, SettingsView, BrowserServer, ExternalDisplayController — everything downstream of `recognizedCharCount` is untouched.

## Privacy

The app needs `NSCameraUsageDescription` in `Info.plist`. macOS will prompt for camera permission on first use. The camera feed is processed locally — no frames leave the device.

## Supported Listening Modes

The gesture rewind works in all three listening modes:
- **Word Tracking** (speech recognition)
- **Classic** (constant auto-scroll)
- **Voice-Activated** (silence-paused auto-scroll)
