# Architecture

OnYourMarks is one iOS app target (Swift 6, iOS 27, default `MainActor` isolation). Hardware sits behind protocols; the logic that decides anything is pure and tested without hardware.

## Overview

```
StarterView / SettingsView / RecordingsView → ReviewView
        │
StarterViewModel          config, calibrations, camera on/off, session release
        │
StarterEngine             the sequence, the gun schedule, the decision, the session record
   ├── SignalPlayer  ←  AudioController     audio session, engine, scheduling, calibration, hearing
   ├── MovementDetector ← PoseMotionDetector ← PoseTracker ← CameraController
   └── StartRecorder ← StartRecordingController ← VideoFileWriter, RecordingStore
                                                  (frames from CameraController as FrameSource)
                                                  RecordingAnalyser ← SecondPassAnalyser (after the start)

StartReplay, SecondPass      pure, on a RecordedStart (a recording's folder)
Sync/                        clock synchronization between phones, see clock-sync.md
```

1. **Views and view model.** The view model owns the configuration and calibrations, turns the camera on and off and releases the audio session after a run. It does not activate the session; the engine's preflight does.
2. **`StarterEngine`** runs one start: preflight, commands, readiness, the gun's schedule, the decision and the session record.
3. **Hardware protocols**: `SignalPlayer`, `AudioSessionPlayer`, `MovementDetector`, `StartRecorder`, `FrameSource`, `MonotonicClock`, `DatagramTransport`, `RecordingAnalyser`, `PoseDetecting`. Tests use the fakes in `OnYourMarksTests/Helper.swift`.
4. **Pure logic** in `nonisolated` types, for example `OutputTiming`, `CalibrationMath`, `HearingMath`, `DecisionEngine`, `CameraFrameRatePolicy`, `PrecisionWindowMonitor`, `CaptureSettingsPolicy`, `AthleteTracker`, `AthleteStability`, `AthleteMotionMonitor`, `MotionOnsetAnalyzer`, `ProbeStepDetector`, `VideoTimeline`, `ReplayTimeline`, `StartReplay`, `SecondPass`, `ClockSyncEstimator`.

## Time

- One clock for everything: the host clock (`CACurrentMediaTime`), as `MonotonicTimestamp`. Audio sample times and camera frame times are converted to it.
- A time that isn't exact is a `TimeEstimate` or `DurationEstimate`: best, earliest, latest.
- `DecisionEngine` calls a false start only when the whole reaction interval is under the start profile's threshold (block 100 ms, standing 0). Overlap is `uncertain`. `qualify` caps a result at `uncertain` when the gun's time isn't trusted (wireless output without calibration, playback not read back) or the track is `poor`.

## Audio

- **The gun is scheduled on the audio clock** when the hold begins (`schedule(_:at:)`). Heard time = render start + output latency + onset offset in the file + calibration correction, kept as a `SignalTimingBasis` on the `ScheduledSignal`.
- **A gun is out from `ScheduledSignal.cancellableUntil`** (render start minus `OutputTiming.cancellationLead`). The engine checks this at every detector event (`commitGunIfDue`), not by the phase its task is in: an event can arrive after the audio clock started the gun and before the sequence's task ran again.
- After the gun, the render timeline is read back. A gun measured more than `maximumScheduleDeviation` off its schedule gets an interval covering both (`gunTimeRevised`).
- **Preflight** (`prepareForStart()`, inside the wait before the first command): activates the session, verifies sounds, engine and route, starts the microphone listener on the iPhone speaker output, and returns the timing basis. A failed preflight fails the start before any sound.
- **Session transitions are serialized** in `AudioController` and always run to the end, even if the caller is cancelled. An engine stopped by a hardware reconfiguration is restarted; a start is only aborted if a sound was cut off.
- **Outputs**: "Automatic" uses `.playback`; "iPhone speaker" uses `.playAndRecord` with a speaker override, so it needs microphone access. Activation with microphone uses `setActive(true)`: the async `activate()` brings up no input.
- **Calibration**: 2 warm-up clicks, 6 measured, median offset per route ID. The onset is the first sample over the threshold that stays loud for 10 ms. A calibration stores the latency the output reported while it was measured; a start that finds another one adds the difference to the uncertainty.
- **Hearing the gun** (`HearingMath`, `HeardSignal`): on the iPhone speaker output, a `MicrophoneRecorder` on its own engine keeps the last 3 s. When the gun is committed, its onset is searched from the render start to 0.25 s after the model's latest time and recorded as `gunHeard` or `gunNotHeard`. An observation only: it changes no decision and not the gun's time.

## Camera

- **One format per precision rate** (1080p, 16:9, 8-bit, the slowest format that reaches the rate). Idle (15 fps) and precision differ by frame duration only. Format changes happen on the session queue, only from the settings.
- **Precision window**: opened by the engine when the hold begins, closed at the end of the run or of the recording's follow-through.
- **The camera must be steady before the gun** (`CameraCondition.delivering(isSteady:)`, checked in `runHold`). `PrecisionWindowMonitor`, driven by a 20 ms watchdog on the session queue: the rate has arrived with 4 frames whose 3 intervals are each under 1.5 frame durations. Not arrived after `arrivalDeadline` (0.4 s): the session is restarted once. Still nothing: `missed`, and the start goes on.
- **Exposure, focus, white balance**: auto exposure capped at half the frame duration in precision mode; all three locked once settled (0.1 to 0.5 s after the rate is decided), released when the window closes. Every value goes through `CaptureSettingsPolicy`, because an unsupported mode or rate raises an exception that can't be caught. The same is why rates go through `CameraFrameRatePolicy.supported` and the automatic low-light frame rate stays off.
- **Frames arriving**: `isDelivering` from the first frame until frames stop for 0.5 s (`FrameFlow`), an interruption, a runtime error or `stop()`. A start with the camera on needs frames before its first command. A failure before the gun is out fails the start; after it, frames after the failure are not judged.
- Everything the camera did is a `CameraReport`, recorded as `StartEventKind.camera`.
- The precision rate is never throttled for system pressure; the idle rate drops to 5 fps under serious pressure.

## Athletes

- **Two rates** (`PoseMotionDetector`): every frame is sampled on the capture queue (`MotionSampler`: each stable athlete's region as a 40×40 brightness grid, kept 4 s). Pose detection runs on its own queue on the newest waiting frame.
- **Tracking**: `PoseTracker` returns every body Vision finds; `AthleteTracker` pairs them with known tracks, nearest first, gated by body size. States `tentative` (under 3 frames) → `tracked` → `occluded` (unseen over 0.1 s) → `lost` (over 1 s). Delays are in seconds because the analysed rate varies.
- **Roster**: fixed when monitoring begins (tracked and occluded athletes), numbered from the left. Only they are judged, each once.
- **Stillness** (`AthleteStability`): `moving` → `settling` → `stable` after 0.4 s within the tolerance; the resting pose is the average of that stretch.
- **Movement** in the athlete's own size: per body region the mean joint displacement in torso lengths, weighted by the start type's `MotionProfile`, largest region wins; over 0.3 is a start. Outside the tolerance for 0.3 s without reaching it is `unsteady`.
- **Two poses** (`AthleteMotionMonitor`): a crossing is reported only when the athlete's next judged pose is over the threshold too, within `confirmationWait` (0.25 s). The movement keeps the first pose's time. A crossing nothing confirmed is `movementUnconfirmed`.
- **Onset from pixels** (`MotionOnsetAnalyzer`): after a confirmed movement, walk back through the athlete's grids. Each frame is compared with the mean picture 0.1 to 0.15 s before it, brightness removed, each cell divided by its own spread over the rest. Certain where the change exceeds the resting level by 6 σ and anything rest reached; the onset is the foot of that rise. Not in handheld mode, nor without 0.75 s of frames at the precision rate. The result arrives as `onsetRefined`; the engine revises the result (`decisionRevised`) but never recalls.
- **Readiness** (`runHold`): the gun is scheduled once every visible roster athlete is stable and the camera is steady; the hold counts from then. Lost readiness takes a pending gun back and counts as a restart; after any restart the hold is at least `minimumHoldAfterDisturbance` (1 s). 3 restarts or `readinessTimeout` (10 s) fail the start. A wake-up of the sequence (`wakeSequence`) sticks until the next wakeable sleep.
- **Handheld** (`CameraMotionEstimator`): each frame registered against a copy of the first frame of the monitoring, translation only. A frame whose shift can't be measured is not judged; after 0.1 s of that the reference is renewed and every athlete has to become still again. Never keep one of the camera's own buffers: it stalls the capture.
- **After the gun** the run goes on until every roster athlete has moved, at most `reactionWindow` (1.5 s). On a false start, monitoring goes on for `falseStartCollection` (0.35 s); before the gun only movements within 0.1 s of the first count. With the recall off, every movement before the gun counts.

## Recording

- **The video is the frames the analysis saw** (`VideoFileWriter`, `AVAssetWriter` with a pixel buffer receiver, called after the analysis on the capture queue). Frame `n` sits in the video at its capture time minus the first frame's, in microseconds (`VideoTimeline`); the capture times are stored (`StartRecording.frameTimes`). That mapping places the gun and the movements on frames, so nothing that hides gaps may be used. `AVCaptureMovieFileOutput` is not used: a paused movie closes the gap on its own timeline.
- **The writer never waits** (`appendImmediately`); a frame the encoder isn't ready for is counted and missing from the video only.
- **Span**: from the beginning of the hold to `recordingAfterStart` after the gun (`followThrough`, handed to the recorder as `tail`). A false start has no tail.
- **Storage**: one folder per start, see [Recording and review](../features/recording-and-review.md#export). Only `completed` and `falseStart` replace the last start (in the temporary directory); saving moves it to Application Support. Leftover folders are only swept when the controller is created.
- **Tracking frames** (`athletesTracked`) and **motion samples** (`motionSampled`) go to the recorder, not into the session's events.

## Replay and second pass

- **`StartReplay`** runs the app's own logic again on a recorded start, without hardware: the decision on the session's events (through `DecisionEngine.judge`, which the engine uses too), tracker, stability and monitor on the recorded poses, and the onset analysis on `motion.json`. Constants that may change are arguments (`MotionOnsetAnalyzer.Parameters`, `MotionProfile`, `StartProfile`). It is the regression corpus for every change to a constant.
- **`truth.json`** (`RecordedTruth`), written by hand beside a recording: per roster position, the first frame a person sees moving. The replay compares with it when it exists.
- **Second pass** (`SecondPassAnalyser`, `SecondPass`, `RecordedVideoReader`): after every kept recording, at background priority, cancelled by the next start. Decodes every frame, gives it its stored capture time exactly (a frame without one is left out, never given a neighbour's), finds a pose on every frame, matches the tracks to the live roster, and runs the onset analysis with rest from the whole hold. Stored as `analysis.json`, never in `start.json`, and never used to recall.
- `MotionOnsetAnalyzer.series(in:until:parameters:)` gives the change signal the analysis thresholds, for drawing.

## Probe mode

A run with `StartConfig.probeRegions` set (not stored) is a measurement: same engine, sequence, gun and recording, empty roster, nothing judged. `PoseMotionDetector` samples each region on every frame and feeds a `ProbeStepDetector`: a step is a frame that differs from the one before by 6 σ over the resting level, more than rest ever did and at least one brightness step. Each region's step nearest to the gun is measured against the gun's final time (`probeMeasured`).

## Session record

`StartSession` is the start's event timeline: preflight, the gun's timing basis and what the microphone heard, the camera's reports, movements (confirmed and unconfirmed), reactions, decisions, probe steps, the outcome. The review reads it and `StartReplay` replays it. New facts about a start become events, and new detector facts become cases of `DetectorEvent`, so they can be recorded, replayed or sent from another phone.
