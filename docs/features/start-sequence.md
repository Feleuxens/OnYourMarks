# Start Sequence

OnYourMarks plays the commands and the gun of a sprint start, with a random hold before the gun.

## Overview

| Start type | Sequence |
|---|---|
| **Block** | "On your marks" → "Set" → hold → gun |
| **Standing** | "On your marks" → hold → gun |

Choose the type with **Block** or **Standing** on the start screen. Tap **Start** to begin and **Abort** to stop at any time.

With detection on, the hold only begins once every athlete in the picture holds still, and it counts from that moment, not from the command. See [False-start detection](false-start-detection.md#readiness).

## The recall

When an athlete moves before the gun, or reacts faster than is humanly possible, the app fires three recall shots and the start ends. Every athlete who went early is named.

The **Recall on** button below the picture switches this off. With **Recall off**, a false start is still judged, marked and recorded, but the gun fires and the start goes on. This is useful when you want to see the reaction times even of a start that went wrong.

## Configuration

All times are in **Settings**, separately for block and standing starts.

### Time until "On Your Marks"

From tapping **Start** to the first command. Default 2 s, 0 to 20 s. Use it to walk to the blocks.

### Time until "Set"

Block starts only. From "On your marks" to "Set". Default 12 s, 0 to 30 s.

### Min time until Start, Max time until Start

The hold before the gun is chosen at random between these two. Default 1 to 2 s, each 0 to 10 s. With detection on, the hold counts from the moment every athlete holds still. After a disturbance (an athlete moved and had to settle again) it is at least 1 s, however short you set it.

### Sound

The voice and gun sound. Currently one set: **English 1**.

## Limitations

- The recall shots play on the same output as the gun.
- Commands are English only.
