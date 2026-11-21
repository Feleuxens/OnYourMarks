# Accuracy

A reaction time is the time from when the athlete heard the gun to when they began to move. OnYourMarks measures both ends and shows how sure it is: `150 ms ± 7 ms`.

> [!WARNING]
> The reaction times have not been checked against an independent reference yet. Until then, treat the times as precise to the stated interval only under the assumptions below.

## Every time is an interval

The app never pretends to know a time exactly. Each measured time has an earliest and a latest possible value, and the ± you see is the larger side of that interval.

A false start is only called when the **whole** interval of the reaction is under the limit. If it overlaps, the result is uncertain and nobody is recalled. A wider interval can only make a recall less likely, never more.

## The gun

The gun is not played "now" when a timer fires. It is placed on the audio hardware's own clock in advance, and the time it is heard is worked out from:

- the moment the audio hardware starts playing it,
- the output's delay, as iOS reports it, or as a [calibration](features/audio-output.md#calibrate-output) measured it,
- where in the sound file the bang begins.

After the gun the app reads back when it actually played. If that differs from the plan, the gun's interval is widened to cover both.

| Measured on the iPhone 17 Pro | |
|---|---|
| Gun start against its schedule | under 0.1 ms |
| iPhone speaker: expected against heard by the microphone | 1.7 ms ± 1.1 ms |
| Bluetooth speaker: delay reported by iOS / measured by calibration | 180 ms / 287 ms ± 2 ms |

The last line is why [Bluetooth is best effort](features/audio-output.md): the reported delay was 107 ms too short.

## The movement

The camera stamps every frame with the time it was captured, on the same clock as the audio. The movement's interval reaches from the last frame in which the athlete still looked at rest to the first frame in which the movement was certain. Usually those are two neighbouring frames:

| Frame rate | Two neighbouring frames |
|---|---|
| 60 fps | 16.7 ms |
| 120 fps | 8.3 ms |
| 240 fps | 4.2 ms |

A dropped frame widens the interval by itself, because the interval is made of the frames that actually arrived.

## What is not in the interval yet

- **Exposure time.** Each frame is exposed for a while (at most half a frame in precision mode); where in that time the stamp lies is not modelled.
- **Rolling shutter.** The sensor reads the picture line by line; the lines are captured a few milliseconds apart.
- **Sound travel.** Sound needs 2.9 ms per metre. The app times the gun at the speaker, so an athlete 3 m from it hears the gun about 9 ms later.
- **The thresholds.** What counts as "still at rest" and "certainly moving" is reasoned, and has been checked on one recorded start only.

## Live and from the video

During the start, the app analyses as many frames as it can, about 90 of 120 per second, and decides. After the start it analyses the recorded video again, every frame, and shows that result next to the live one. The live result decides about the recall; the video result can only be looked at.

## Tips for accurate times

- Use the iPhone speaker or a wired speaker.
- Use a tripod.
- Use 120 or 240 fps, with enough light.
- Place the speaker close to the athletes.
