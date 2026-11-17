# Timing Probe [Diagnostics]

The timing probe measures the app against an independent reference: a light that switches on when it hears the gun. If everything is right, the camera sees the light change exactly when the app says the gun was heard.

> [!NOTE]
> This is a measurement mode, not a start. Nobody is judged and nothing is recalled.

## Overview

A sound-triggered light (for example a clap switch with an LED) placed next to the speaker turns on when the gun sounds. The app films it and measures when the light changed, against the gun's heard time. The result should be 0 ms.

That one number checks the whole chain at once: the gun's schedule, the speaker's delay, a calibration if there is one, and the camera's frame timestamps.

## Running a measurement

1. Set the phone up as for a start, with the light in the picture.
2. Open Settings → Diagnostics → **Timing probe**.
3. Draw a rectangle around the light on the picture, or tap **Whole picture**. You can draw several.
4. Tap **Start measurement**. The normal sequence plays.

The result per region, for example:

"Region 1: 2 ms after the gun"

with the interval and the region's **readout position**. The review of the recording shows the measurement with cyan markers.

## Rolling shutter

The camera reads the picture line by line, so the bottom of a frame is captured a few milliseconds after the top. The readout position says where along that order the region lies. To measure the readout time, put two lights at the **left** and **right** edge of the upright picture: the sensor's lines run across it.

## Limitations

- The light must switch fast compared with a frame: an LED, not a bulb.
- The light's own delay (from sound to light) is part of the result. Use one whose delay you know.
- Not yet run with a real light.
