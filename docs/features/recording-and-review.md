# Recording and Review

Every start with detection on is filmed, so you can watch it again frame by frame with the gun and each athlete's movement marked.

## Overview

The recording runs from the beginning of the hold until 3 s after the gun, at the precision frame rate, without sound. A false start ends it at the recall.

After a start, tap **Review start** under the picture. The film icon at the top left of the start screen opens **Recorded starts**: the last start and every start you saved.

## The last start and saved starts

Only the last start is kept automatically. "The next start replaces it unless you save it." Tap **Save** in the review to keep it. Saved starts stay until you delete them.

Starts that were aborted or failed are not kept.

## The review

- **Frame by frame**: previous and next frame, play and pause, and a playback speed button.
- **Go to the gun**: the flag button jumps to the frame of the gun.
- **Timeline**: the gun and each athlete's first movement, drawn as wide as their measured interval. A movement only one frame showed, which the next frame didn't confirm, is drawn in grey.
- **Skeletons**: the poses the app found, with the athlete numbers. An athlete who false-started is red.
- **Reaction times**: one chip per athlete, for example `60 ms ± 7 ms`. Tap one to highlight that athlete and jump to the beginning of their movement.

The header shows the frame number and its time from the gun: "Frame 80 of 117", "50 ms after the gun".

### From the video

After a recorded start the app analyses the whole video again in the background: a pose on every frame, not only those it had time for during the start, and the athlete's rest learned from the whole hold. The result is shown under the live time:

"From the video: 148 ms ± 5 ms"

It never changes the live decision. While it runs, "Analysing the video…" is shown; the next start stops it.

## Export

The share button exports the start's folder:

| File | Contents |
|---|---|
| `video.mov` | The frames the analysis saw, without overlays |
| `start.json` | The start's full record: every command, the gun, movements, reactions, decisions, and each frame's capture time |
| `tracking.json` | Every pose found during the start |
| `motion.json` | The pixel samples the timing was measured from |
| `analysis.json` | The second analysis from the video, if it has run |

The overlays are drawn from the data when you review a start; there is no video with them burned in.

## Configuration

Settings → **Camera**.

### Record starts

On by default. Off: nothing is filmed and there is no review.

### Recording after the start

How long the recording goes on after the gun, so athletes can see their first steps. Default 3 s, 0 to 6 s.

## Limitations

- The analysis of the video has not run on a real phone yet. Its duration on the phone is unknown.
- When the encoder can't keep up, a frame is left out of the video but not out of the analysis. The video then has a gap, never a wrong time.
