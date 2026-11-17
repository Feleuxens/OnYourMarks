# Audio Output

The reaction time is measured from the moment the gun is heard, so the app has to know exactly when the speaker plays it. How well it knows depends on the speaker.

> [!WARNING]
> Bluetooth and other wireless speakers delay the sound by an amount that can change while they play. Reaction times on them are less accurate, even after a calibration. Use the iPhone speaker or a wired speaker for accurate results.

## Overview

| Output | Accuracy | Notes |
|---|---|---|
| **iPhone speaker** | Best: about ±2 ms | The phone reports its own delay. Needs microphone access (iOS requires it to force the speaker). |
| Wired speaker or headphones | Good | Chosen with **Automatic**. |
| Bluetooth, AirPlay | Best effort | About 0.1 to 0.2 s of delay that is only estimated, or measured once by a calibration. |

The start screen shows a warning whenever the next start would play on a wireless output.

Without a calibration, a wireless output makes every false start **uncertain**: the app can't know the gun's time well enough to recall anyone.

## Configuration

Settings → **Audio output**.

### Output

- **Automatic** (default): whatever iOS currently plays on. The current output is shown below; tap it to choose another device.
- **iPhone speaker**: always the built-in speaker, even with headphones or Bluetooth connected.

### Calibrate output

For outputs other than the iPhone speaker. The app plays the start signal six times (after two warm-up clicks), listens with the microphone and stores the measured delay for that device. Each output keeps its own calibration.

To calibrate:

1. Connect the speaker and select it as the output.
2. Turn the volume up.
3. Hold the speaker right next to the iPhone, in a quiet room.
4. Tap **Calibrate output**.

The result is shown as a correction with its spread, for example `+107 ms ± 2 ms`. **Remove calibration** deletes it.

> [!TIP]
> The distance between phone and speaker during the calibration ends up in the correction: every metre is 2.9 ms. Hold them together.

## Hearing the gun

On the **iPhone speaker**, the app also listens to every gun it fires and compares when the microphone heard it with when it expected it. The review shows the result, for example "Microphone: gun heard 0.4 ms from the model, within its range." It is a check of the app's timing and never changes a decision.

This only happens on the iPhone speaker, where the microphone sits next to the sound and the gun is far louder than anything else around.

## Limitations

- Bluetooth is supported as best effort. Its delay depends on the device, the codec, the connection and the distance, and can change during a session.
- A calibration is only valid for the delay the output reported while it was measured. If the output later reports another one, the difference is added to the uncertainty.
- If the output changes during a start (headphones unplugged, Bluetooth disconnected), the start is aborted.
