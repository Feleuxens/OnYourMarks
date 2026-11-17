# False-Start Detection

OnYourMarks watches every athlete with the camera and tells you who moved before the gun, or reacted too fast to have reacted to it.

> [!IMPORTANT]
> This app is for training. A wrong recall is worse than a missed false start, so when in doubt the athletes run. A false start is only called when the whole measured interval is under the limit; anything else is shown as uncertain.

## Overview

Turn detection on with **Detection on** below the picture. The camera then runs at 15 frames per second while you set up, and at the precision rate (120 by default) from the moment the hold begins.

Each athlete gets a number, counted from the left as the camera sees them. The preview shows the numbers; an athlete who false-started is marked red and named in a banner: "False start: athlete 2 from the left".

## Placing the camera

- Beside the track, never on it, slightly in front of the start line, so the athletes are seen at an angle.
- Every athlete in the picture from head to foot, in the set position too.
- On a tripod. A camera that moves makes every pixel move; see [Handheld](#handheld).
- In good light. A higher frame rate needs more light.

## How it works

### Who is in the start

When the hold begins, the app fixes the list of athletes it can see. Only they are judged, each once. Someone who walks into the picture later is ignored.

### Readiness

The gun is only scheduled once every athlete holds still for 0.4 s. Getting into the blocks is never a movement; only an athlete who has been still can start or false-start.

An athlete who moves without starting (shifting weight, adjusting a foot) is **unsteady**, not a false start. Before the gun the app takes the gun back, waits until the athlete is still again and holds again. After 3 such restarts, or 10 s without everyone still, the start is cancelled. After the gun, unsteadiness is ignored.

The camera has to deliver its full frame rate before the gun as well. If it doesn't, the app restarts it once; see [Limitations](#limitations).

### When is it a movement

The app finds each athlete's pose (joints) on as many frames as it can analyse, about 90 of 120 per second. Movement is measured in the athlete's own size, in torso lengths, so a near and a far athlete count the same. A start is a movement of more than 0.3 torso lengths, weighted by body region for block and standing starts.

A single frame is not enough: the athlete's next analysed pose has to agree. One wrong pose cannot recall a start.

### When did it begin

Poses say *who* moved. The pixels say *when*: the app samples every frame of each athlete's region and walks back from the confirmed movement to the last frame that still looked like rest. The movement's time is the interval between that frame and the next one, usually two neighbouring frames (8.3 ms apart at 120 fps).

### The decision

The reaction time is the interval from the gun to the movement. It is a false start when the **whole** interval is under the limit:

| Start type | Limit |
|---|---|
| Block | 100 ms after the gun |
| Standing | the gun itself (only a movement certainly before the gun) |

An interval that overlaps the limit is **uncertain**: shown, never recalled. A standing start begins too gradually to judge faster reactions.

### Several athletes

Several athletes can false-start in one run. The first one triggers the recall; the app then keeps watching for 0.35 s. Before the gun, only movements within 0.1 s of the first count, because later ones may be a reaction to the first athlete. With the recall off, every movement before the gun counts.

## Handheld

With **Camera mount** set to **Handheld**, the app measures how the picture shifts from frame to frame and removes that shift from the athletes' joints. Frames whose shift can't be measured are not judged. If the camera can't be followed for 0.1 s, every athlete has to hold still again.

Handheld starts are timed from poses only, without the pixel analysis, so their intervals are wider.

## Configuration

Settings → **Camera**.

### Camera mount

**Tripod** (default) or **Handheld**. A tripod is more precise.

### Frame rate

The precision rate: **60**, **120** (default) or **240 fps**. A higher rate times a movement more finely but needs more light. A camera that doesn't reach the rate uses its fastest.

## Limitations

- **The precision rate does not always arrive.** On the iPhone 17 Pro the camera sometimes stays at its idle rate when asked for 60 or 120 fps; the 240 fps format has not shown this. The app restarts the camera once. If the rate still doesn't arrive, the start goes on, the times are less precise, and the result says so: "The camera delivered 15 of 120 frames per second".
- If the camera stops during a start, a start before the gun is cancelled. After the gun, athletes without a time are not judged.
- A wrong pose that repeats on the next frame (left and right swapped, a neighbour's arm taken in) can still recall a start.
- All thresholds are reasoned, not tuned on recorded starts yet. See [Accuracy](../accuracy.md).
