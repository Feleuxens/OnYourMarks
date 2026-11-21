# Measurements and Open Questions

What has been measured, what is only reasoned, and what is planned. Numbers come from device tests (their attachments) unless marked otherwise.

## Measured on the iPhone 17 Pro

| | |
|---|---|
| Gun start against its schedule | under 0.1 ms |
| iPhone speaker: timing model against the microphone | 1.7 ms ± 1.1 ms |
| Bluetooth speaker: reported latency / measured correction | 180 ms / +107 ms ± 2 ms (2026-11-13: +105.9 ms ± 1.4 ms) |
| Bluetooth speaker: reported latency by session category | 180.295 ms in `.playback` (44.1 kHz), 180.292 ms in `.playAndRecord` (48 kHz) |
| Camera rates | 15.0 / 119.95 fps, 0 drops without analysis; 59.98 and 237.9 fps when set to 60 and 240 |
| Idle to precision switch | about 0.2 s; when it arrives, median 142 ms, longest 251 ms |
| Sampling three athletes per frame | median 1.5 ms at 120 fps (0 drops), 1.2 ms at 240 fps (9 of 723 frames late) |
| Pose detection | median 10.9 ms per frame; about 88 of 120 fps analysed |
| Poses beside the sampling | about 61 / 95 / 106 per second at 60 / 120 / 240 fps |
| Handheld compensation | image registration median 2.5 ms; about 62 of 120 fps analysed |
| Recording beside the analysis (one run each) | writer skipped 0 frames at 120 and 240 fps; poses per second 107.8 → 82.6 at 120 fps, 78.9 → 83.6 at 240 fps |
| Audio calls on the main actor (debug build) | `play`, `schedule`, `engine.stop()` about 21 ms each (one I/O cycle); first engine start about 90 ms, later ones about 10 ms; `loadSounds` 27 to 84 ms |
| Debugger on the device | every library loaded during a run stops the process: 10 stops of 0.27 to 0.78 s in the first 5.5 s |
| Low-latency video stabilization | supported by 0 of the back camera's 72 formats |
| Simulator audio clock drift | about 0.1 % |

## One recorded start

One real block start exists (240 fps, one athlete, iPhone speaker). The offline replay reproduces it exactly: reaction 287.9 ms (279.7 to 296.2), legal. On it:

- The video's grids differ from the live ones by 0.43 of 255 on average; the onset found is identical.
- The two-pose rule confirmed the movement 16.7 ms after the crossing, without changing its time.
- The picture changes from 23 to 27 ms after the gun's heard time, gradually (probably the speaker shaking the phone). It is not a step, so it doesn't show that audio and camera timestamps agree to a frame.
- Every fourth frame differs more from its neighbour than the others, all through rest. Cause unknown.

One start tunes nothing. No constant has been changed because of it.

## Open questions

### Accuracy

- **No ground truth yet.** Exposure time and rolling shutter are not modelled.
- `OutputTiming.cancellationLead` is reasoned. `cancellationLeadIsMeasured` measures it; it has only run in the simulator (no sound got out at leads of 22.5 ms or more, current lead 25 ms there).
- Hearing the gun has only run in the simulator (46 ms after the model, which doesn't know the Mac's latencies). On the device: does it agree with the model as the calibration did?
- All `MotionProfile` values, the tracker's gate, the quality thresholds, the onset analysis's thresholds and `reactionWindow` (1.5 s) are reasoned. They need recorded starts with several athletes, and hand-labelled `truth.json` files.
- A pose error that repeats on the next frame can still recall a start.
- A movement that began after the gun's render start waits for the read-back, 50 ms after the render start, before it can recall. How often a read-back fails, and how often the heard time it gives differs from the schedule while the render is on time, is unmeasured. On the recorded start it gave a heard time 0.27 ms before the schedule (under the 0.5 ms that revises it). The read-back's latency is not stored, so render and latency can't be told apart afterwards.
- `SecondPass.ambiguousVoteShare` (0.5) is reasoned. It has not met a start with two athletes side by side.
- A short noise just before the gun can still move the onset the microphone hears, by up to the sustain window (10 ms): the sustain check takes the mean, and the gun's energy carries a spike before it. Live this only changes the recorded check; a calibration click is affected, though the median and the spread check limit it. Left open (owner, 2026-11-18).
- `CalibrationMath.maximumChunkGap` (1 ms) is reasoned: the jitter between the microphone's chunk timestamps and how often a chunk goes missing are unmeasured.
- In a recorded standing start the athlete leaned forward through the hold and was 0.16 torso lengths from rest at the gun, just over the tolerance of 0.15. Whether the tolerance is too strict for standing starts needs more recordings.

### Camera

- **The precision rate does not always arrive** (2026-11-13): asked to go from 15 to 60 or 120 fps, the running session sometimes stays at the old rate, although the device reports the new frame durations. It failed in 3 of 8 windows at first and in almost all later ones, never in the 240 fps format, then worked in 12 of 12 windows the same evening. Pressure, thermal state, HDR and the ways of setting the durations made no difference. A session started at 120 fps delivers 120. The app restarts the session once; whether that cures it is what `thePrecisionRateArrivesEveryTime` answers. Also open: whether 240 fps should be the default.
- The camera's deadlines (`arrivalDeadline`, `minimumSettle`, `settleTimeout`, `stallTimeout`, `cameraStartupTimeout`) and the exposure cap are reasoned. The heat of a precision window that now runs for the whole hold is unmeasured.
- Camera failures during a start have only been tested with the fake detector.
- `VNTranslationalImageRegistrationRequest` returned a wrong shift for one synthetic picture. How often it does on real ones is unmeasured; handheld compensation has not been checked on a tripod or in the hand.
- Recording at the precision rate for seconds after the gun: writer skips, drops and file sizes unmeasured. A 240 fps video came out at a tenth of the size of a 120 fps one; not understood.

### Second pass

- It has never seen a real pose: Vision's body-pose request fails in the simulator. Its duration on the phone is unknown (78 s for 1209 frames in the simulator, mostly decoding).

### Several phones

- The synchronization has not run between two real phones: round trips and width over AWDL and over an access point, the real drift against the assumed 200 ppm, losses, violations. `twoPhonesSynchronize` answers these.
- No acoustic cross-check yet, and datagrams are neither authenticated nor encrypted.

## Roadmap

Planned, in no fixed order. Keep what these build on (protocols, timing types and session events that look unused).

- Reaction time accurate to 1/100 s: a live pass that only recalls on a certain false start, and the second pass over the recorded video for the accurate time.
- Several phones: the remote speaker as a `SignalPlayer` (designed in [Clock synchronization](clock-sync.md#the-remote-speaker-design)), then detector events from a camera phone.
- A review that draws the change signal under the timeline, and an export with the overlays drawn into the video.
- Finish timing with a camera or a laser gate.
- Maybe a pressure sensor in the blocks.
