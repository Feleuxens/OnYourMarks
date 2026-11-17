# Building and Testing

## Requirements

- Xcode 27 with the iOS 27 SDK.
- For device tests: an iPhone with iOS 27, unlocked during the run.

## Build

The scheme is `OnYourMarks`. The project uses file-system-synchronized groups, so new files need no project edits.

```
xcodebuild build -scheme OnYourMarks -destination 'platform=iOS Simulator,name=iPhone 17'
```

List the available destinations with:

```
xcodebuild -scheme OnYourMarks -showdestinations
```

The build is free of compiler warnings. Check the output unfiltered; the only `warning:` lines are Xcode's AppIntents metadata notices.

## Test

```
xcodebuild test -scheme OnYourMarks -destination 'platform=iOS Simulator,name=iPhone 17'
```

Unit tests use Swift Testing, UI tests XCTest. Read the results from the `.xcresult` bundle:

```
# Pass, fail and skip counts, with the failures
xcrun xcresulttool get test-results summary --path <result.xcresult>

# Attachments: device tests record their measurements here
xcrun xcresulttool export attachments --path <result.xcresult> --output-path <folder>
```

On a device, wrap the run in `timeout`: a locked phone makes `xcodebuild` wait.

## Opt-in tests

Tests that need hardware, make sound or read real recordings are skipped unless their variable is set. Variables reach the test process with the `TEST_RUNNER_` prefix:

```
TEST_RUNNER_RUN_CAMERA=1 xcodebuild test -scheme OnYourMarks -destination 'id=<device id>'
```

| Variable | Runs | Needs |
|---|---|---|
| `TEST_RUNNER_RUN_CALIBRATION=1` | Real calibrations, route check, the gun heard against the timing model (about 20 audible gunshots) | Microphone access. In the simulator: `xcrun simctl privacy <simulator id> grant microphone de.feleuxens.OnYourMarks` |
| `TEST_RUNNER_RUN_CANCELLATION_LEAD=1` | Guns stopped around `OutputTiming.cancellationLead`; reports which stops let sound through (about 70 gunshots per output) | Microphone access |
| `TEST_RUNNER_RUN_CAMERA=1` | Real capture: frame rates, the precision window, exposure lock, pose throughput, recording, the probe | A device with camera access |
| `TEST_RUNNER_RUN_SYNC_PEER=1` | `twoPhonesSynchronize`: pairs with another device running the same test, synchronizes 60 s, attaches `sync-peer.txt` | Two devices (or a device and a simulator) on one network, started together; local network access on the device |
| `TEST_RUNNER_SEED_RECORDING=1` | Puts a made-up recorded start into the library, so the review can be looked at in the simulator | Nothing |
| `TEST_RUNNER_FIELD_DATA=<folder>` | Replay and second pass over every recorded start in the folder | Recordings copied from a phone |

> [!NOTE]
> The calibration tests in the simulator use the Mac's speaker and microphone and can fail once on room noise. Run the failing test again on its own before treating it as a regression.

## Recordings from the phone

Copy a recording off the phone with:

```
xcrun devicectl device copy from --device <device id> \
  --domain-type appDataContainer --domain-identifier de.feleuxens.OnYourMarks \
  --source "Library/Application Support/Recordings/<recording id>" \
  --destination FieldData/<recording id>
```

> [!CAUTION]
> Recordings show people. `FieldData/` is not part of the repository; never commit a recording or attach its frames to a test result.

## Writing tests

- Time is never compared against the wall clock. A test about when the engine does something gives it a `ManualClock`, moves time with `advance(by:)` and compares exactly.
- Wait with `waitUntil { }` from `Helper.swift`, not with sleeps or fixed yields. Its timeout counts the test's own turns.
- Hardware tests are gated with `.enabled(if:)` on a `nonisolated static` condition.
- Tests don't compare against user-facing text.
- The simulator's video encoder takes far fewer frames than a loop sends; tests that write video accept skipped frames.
- Vision's body-pose detection does not work in the simulator. Pose tests use synthetic poses; anything about real poses needs a device.
