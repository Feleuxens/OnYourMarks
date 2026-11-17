# FAQ

## Starts

### Why doesn't the gun come?

The gun waits until every athlete in the picture holds still. Check that nobody is moving in the picture, including people who are not starting: everyone visible when the hold begins counts as an athlete. After 3 restarts or 10 seconds without everyone still, the start is cancelled.

### Can I use it without the camera?

Yes. With **Detection off** the app plays the sequence with a random hold and nothing else: no false-start detection, no reaction times, no recording.

### Why was the start recalled although nobody moved?

Please save the start and look at it in the review. A recall needs two poses in a row over the threshold, but a pose error that repeats on the next frame can still cause one. That is a known limitation.

### Why does it say "uncertain"?

The reaction's interval overlaps the limit, so the app can't tell whether it was a false start. It only recalls when it is certain. See [Accuracy](accuracy.md).

### Can I see the reaction times of a false start?

Yes. Switch the recall off with **Recall on** below the picture. The start then goes on after a false start, and every athlete gets a time.

## Camera

### Which frame rate should I use?

120 fps if the light is good, 240 fps in bright daylight. 60 fps works in poor light but times a movement only to 16.7 ms.

### The result says the camera delivered fewer frames than asked. Why?

Sometimes the camera stays at its idle rate. The app restarts it once before the gun; if that doesn't help, the start goes on with the frames that arrived and the times get wider. See [False-start detection](features/false-start-detection.md#limitations).

### Does handheld work?

Yes, with a steady hand. It is less precise than a tripod: the pixel analysis is off, so movements are timed from poses only.

## Audio

### Can I use a Bluetooth speaker?

Yes, as best effort. Its delay can change while it plays, so reaction times are less accurate. Calibrate it, and prefer the iPhone speaker or a wired speaker. See [Audio output](features/audio-output.md).

### Why does the iPhone speaker need the microphone?

iOS only lets an app force sound to the built-in speaker in a mode that also records. The app uses the microphone there to check when the gun was heard.

## Recordings

### Where are my recordings?

The film icon at the top left of the start screen. Only the last start is kept automatically; tap **Save** in the review to keep it.

### Is anything uploaded?

No. Recordings stay on the phone until you export them.
