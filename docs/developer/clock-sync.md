# Clock synchronization between phones

Several phones take part in one start: one or two watch the athletes, one plays the gun, later one stands at the finish. Every phone times what it measures on its own host clock (`CACurrentMediaTime`, `MonotonicTimestamp`). To compare a movement seen by one phone with a gun played by another, one phone's times have to be expressed on the other's clock.

This document states what the synchronization guarantees, under which assumptions, and what has to be measured on real phones before the guarantee is worth anything in a start. The code is in `OnYourMarks/Sync/`; the tests are `OnYourMarksTests/ClockSyncTests.swift` and `OnYourMarksTests/NodeTests.swift`.

## The quantity

Let `L` be the local host clock and `R` the remote one. The **offset** at local time ℓ is

    θ(ℓ) = R − L,  both read at the instant when L reads ℓ.

A remote reading `r` was therefore taken at local time `r − θ`. The synchronization does not estimate θ; it keeps an **interval** `[θ⁻, θ⁺]` that contains θ whenever the assumptions below hold, and reports when they don't.

## Assumptions

Causality, which needs no assumption beyond what clocks and networks are:

- **C1 — monotonic clocks.** Each host clock never goes back while the phone is awake. (`mach_absolute_time` is a hardware counter; it is never slewed or set.)
- **C2 — causality.** A message is received after it was sent.
- **C3 — stamp placement.** A send stamp is read before the message is handed to the network, a receive stamp after it was handed up. Both are read from the host clock in the app.

The assumptions that are not causality, each named in the code:

- **A1 — rate bound** (`ClockSyncAssumptions.maximumRelativeRate`, ρ = 200 ppm). The offset changes by at most ρ per second of local time: |dθ/dℓ| ≤ ρ. The host clock counts the SoC's 24 MHz crystal-driven timebase. Phone crystals are specified around ±10 to ±20 ppm at room temperature, ±10 to ±30 ppm more over the temperature range and a few ppm of ageing per year, so about ±50 ppm per phone and 100 ppm between two. Apple publishes no figure, so the bound is twice that. The real rate is measured from the exchanges (theorem 3); a measurement that contradicts ρ is reported as a violation.
- **A2 — resolution** (`resolutionAllowance`, ε = 1 µs). A reading can be off from the ideal clock by one tick (42 ns), and arithmetic on host times in `Double` seconds rounds by under 2 ns per operation below 2²⁴ s (194 days) of uptime. Every bound is widened by ε, which covers a dozen of each.
- **A3 — one run of the clock** (`ClockEpoch`). The host clock starts at zero when the phone boots and stands still while it sleeps. Every message carries the sender's boot session and the time it has slept (the difference of `mach_continuous_time` and `mach_absolute_time`, read in a bracket a few hundred nanoseconds wide). If either side's epoch changes, the synchronization starts over; an exchange during which the local clock stopped is dropped. A pause shorter than the read bracket would go unseen; no sleep is that short, and ε covers it.
- **A4 — honest peers.** A phone reports its own stamps. Nothing protects against a phone that lies (see *Security*).

## Theorem 1 — one exchange

Local stamps `t1` (request sent) and `t4` (reply received), remote stamps `t2` (request received) and `t3` (reply sent):

    t3 − t4  ≤  θ(ℓ′)   for some ℓ′ in [t1, t4]
    θ(ℓ″)  ≤  t2 − t1   for some ℓ″ in [t1, t4]

*Proof.* Let `a1 … a4` be the real instants the stamps were read and `s1, r2, s3, r4` the real instants the messages left and arrived. C3 and C2 give `a1 ≤ s1 ≤ r2 ≤ a2`, and the remote reads `t3` after `t2` in program order, so `a2 ≤ a3 ≤ s3 ≤ r4 ≤ a4`. Write ℓ″ = L(a2). By C1, `t1 = L(a1) ≤ ℓ″ ≤ L(a4) = t4`, and `θ(ℓ″) = R(a2) − L(a2) = t2 − ℓ″ ≤ t2 − t1`. Likewise with ℓ′ = L(a3): `θ(ℓ′) = t3 − ℓ′ ≥ t3 − t4`. ∎

Nothing is assumed about how the delay splits between the two directions; an asymmetric network makes the interval wide, never wrong. A symmetric estimate (the midpoint, as NTP uses it) would be off by half the asymmetry without saying so (`asymmetryOnlyWidensTheInterval`).

**Stamping in user space.** The theorem only needs `a1 ≤ s1` and `r2 ≤ a2` (and the same for the reply). A stamp read in the app, before the call that hands the datagram to the network, is read before the radio sends it; a stamp read after the datagram arrived in the app is read after the radio received it. Time spent in the network stack, in scheduling or in a debugger stop moves `a1` earlier or `a2` later, which only makes `t2 − t1` larger and `t3 − t4` smaller: the interval widens, its validity is untouched. The remote's hold (`t3 − t2`) is not in the width at all: width = `(t4 − t1) − (t3 − t2) + 2ε`, the round trip minus the hold.

The kernel's receive timestamp (`IP.receiveTimeCalculated`, read as `ReceivedDatagram.kernelReceivedAt`) would be a later-but-earlier-than-the-app stamp and so a tighter valid `t4`. It is recorded, not used: its clock (`CLOCK_MONOTONIC_RAW`, which runs through sleep) has to be converted, and a conversion error could make it *too early*, which would break the theorem. The instrument screen shows how much later the app's stamp is (the "kernel lead"); if that is large on real phones, using it is worth the extra assumption.

With the rate bound, the interval holds at the exchange's midpoint `m = (t1 + t4)/2`: ℓ′ and ℓ″ are at most `(t4 − t1)/2` away from it, so

    θ(m) ∈ [t3 − t4 − ρ(t4 − t1)/2 − ε,  t2 − t1 + ρ(t4 − t1)/2 + ε]      (`ClockSyncEstimator.bound(for:)`)

## Theorem 2 — ageing and intersection

If `θ(mₖ) ∈ [loₖ, hiₖ]` for exchanges k = 1 … n, then at any local instant ℓ

    θ(ℓ) ∈ ⋂ₖ [loₖ − ρ|ℓ − mₖ|,  hiₖ + ρ|ℓ − mₖ|].

*Proof.* By A1, `|θ(ℓ) − θ(mₖ)| ≤ ρ|ℓ − mₖ|` for each k; θ(ℓ) lies in each widened interval, hence in their intersection. ∎

This is `ClockMapping.offset(at:)`. The best lower and the best upper limit can come from different exchanges, so the intersection is narrower than the narrowest single exchange (`intersectingNarrowsTheInterval`). Exchanges are kept for 120 s; dropping one only loosens the result. At 10 exchanges a second an interval ages by 2ρ × 0.1 s = 40 µs between two of them.

## Theorem 3 — the rate, measured without the rate bound

For two exchanges i before j that don't overlap (`t1ⱼ > t4ᵢ`), with the causal limits of theorem 1:

- the offset rose by at least `loⱼ − hiᵢ` over a stretch inside `[t1ᵢ, t4ⱼ]`, at least `t1ⱼ − t4ᵢ` long, so the mean rate over that stretch is at least `(loⱼ − hiᵢ)/(t4ⱼ − t1ᵢ)` if that is positive, `(loⱼ − hiᵢ)/(t1ⱼ − t4ᵢ)` otherwise;
- symmetrically, at most `(hiⱼ − loᵢ)/(t1ⱼ − t4ᵢ)` if positive, `(hiⱼ − loᵢ)/(t4ⱼ − t1ᵢ)` otherwise.

Both limits use only C1 to C3 (and ε). Each holds for the mean over *some* stretch, whatever the rate does; a mean beyond ρ means the rate was beyond ρ somewhere, so a lower limit above ρ or an upper limit below −ρ proves A1 wrong. If the rate is steady, both concern the same quantity and `best` estimates it. The estimator takes the narrowest exchange of the first 10 s as one end and the narrowest of the last 10 s as the other (`RateEstimate`, `ClockSyncEstimator.rate`).

## Theorem 4 — detecting a broken assumption

The exchanges are consistent with A1 exactly when some trajectory θ with |dθ/dℓ| ≤ ρ passes through every interval. Sorted by midpoint, the set of values such a trajectory can have at `mₖ` given the exchanges up to k is

    F₁ = I₁,   Fₖ = (Fₖ₋₁ widened by ρ(mₖ − mₖ₋₁)) ∩ Iₖ,

and a trajectory exists if and only if no Fₖ is empty (the reachable set at each step is an interval, and a Lipschitz trajectory can be continued from any point of it). This forward pass runs after every exchange; an empty set is reported as `SyncViolation.boundsDisagree`. Single exchanges are checked too: `t4 < t1` (`localClockWentBack`), `t3 < t2` (`remoteClockWentBack`), and an exchange whose own interval is empty (`holdLongerThanRoundTrip`). The rate check of theorem 3 is the fourth.

After a violation the estimator gives out no offset until it is reset; `NodeSession` resets it, counts the violation, shows it, and gives out no mapping for another 10 s of agreeing exchanges (`NodeSession.quarantine`).

**What cannot be detected.** A violation that the exchanges don't contradict: a clock running slightly beyond ρ for a short while, or a jump smaller than the intervals. Until the data contradict it, the reported interval may miss the truth by up to the violation's effect (for a rate excess δ over a time T, by about δT). In the simulation a drift of 1.5 × ρ is caught within 120 s, 3 × and 10 × ρ much sooner, and a 20 ms jump within 5 s (`aDriftBeyondTheBoundIsDetected`, `aClockThatJumpsIsDetected`).

## Converting times

`ClockMapping.localTime(forRemote:)`: the remote read `r` at local ℓ* = r − θ(ℓ*), but θ is wanted at ℓ*, which is the unknown. With a guess ℓg and `Θ(ℓg) = [θ⁻, θ⁺]`, theorem 2 gives `Θ(ℓ*) ⊆ Θ(ℓg)` widened by `ρ|ℓ* − ℓg|`, and `|ℓ* − ℓg| ≤ D = max(|r − θ⁺ − ℓg|, |r − θ⁻ − ℓg|)/(1 − ρ)`. So

    ℓ* ∈ [r − θ⁺ − ρD − ε,  r − θ⁻ + ρD + ε].

`localEstimate(forRemote:)` applies this to a remote `TimeEstimate`'s earliest and latest end, so the result carries the remote's own uncertainty plus the synchronization's. Everything downstream (the decision, which only calls a false start when the whole reaction interval is below the threshold; the review) handles it as any other interval, without knowing where the width came from. `remoteTime(forLocal:)` goes the other way, `localDuration(forRemote:)` converts a duration measured on the remote clock (±ρ of it, plus 2ε).

## Proven, assumed, measured

| | |
|---|---|
| Proven by construction (C1 to C3) | Theorem 1 for every exchange, whatever the delays, losses, duplicates or reordering (a reply is paired with its request by a random nonce, once; a duplicate is ignored, a late one dropped). Theorem 3. That user-space stamps only widen. |
| Proven given A1 to A3 | Theorem 2 and the conversions: the true offset and the true local time of a remote event lie inside the reported intervals. Detection of every violation the exchanges contradict. |
| Assumed | ρ = 200 ppm (A1), ε = 1 µs (A2), that sleep is the only thing that stops the host clock (A3), honest peers (A4). |
| Tested in the simulator | Seeded property tests (`ClockSyncTests`): typical, asymmetric, flipping-asymmetric and spiky delays, 10 % loss, 5 % duplicates, reordering, stamps up to 0.3 s late, rates up to ρ with a wandering part; the truth inside every interval and conversion at every check, no false alarms; drift beyond ρ and clock jumps detected. A loopback test with two transports in one process (one clock, so the offset is exactly 0): 0 must lie inside. In one run it did, with an interval 0.15 ms wide after 30 exchanges; round trips 0.18 to 769 ms (the slow ones at the beginning and under load from other simulators), and the app stamped replies 29 µs to 185 ms after the kernel. |
| Must be measured on two phones | See *Measurements* below. Nothing here has run between two real phones yet. |

## Transport

Chosen: **UDP datagrams over Bonjour with peer-to-peer** (`NetworkNodeTransport`, the Network framework's Swift `NetworkListener`, `NetworkBrowser` and `NetworkConnection<UDP>` of iOS 26).

- The bound is as tight as the fastest round trips (and the asymmetry of the fastest ones), so what matters is that each message goes out at once and on its own. A lost datagram costs one exchange out of ten a second. On a stream (TCP, QUIC streams) a lost segment holds back everything behind it (head-of-line blocking) and retransmission adds hundreds of milliseconds to some exchanges; QUIC datagrams would need TLS identities for nothing.
- `peerToPeerIncluded(true)` lets two phones talk over Apple Wireless Direct Link when there is no access point, as on a track, and over infrastructure Wi-Fi when there is one. No entitlement, no pairing dialog, and it works in the simulator, so the plumbing can be tested there.
- **Wi-Fi Aware** (`WiFiAware` framework, iOS 26) is the standard for phone-to-phone links without an access point and would also reach non-Apple devices (a laser gate). It needs the `com.apple.developer.wifi-aware` entitlement, a declared service in Info.plist and pairing through the system's DeviceDiscoveryUI; it is not available in the simulator. It can take the place of the Bonjour transport behind `DatagramTransport` without touching anything above.
- **MultipeerConnectivity** is older, adds its own session layer and gives no control over datagram timing.

Info.plist: `NSLocalNetworkUsageDescription` comes from the build setting `INFOPLIST_KEY_NSLocalNetworkUsageDescription` (translated in `InfoPlist.xcstrings`). `NSBonjourServices` is an array, for which there is no `INFOPLIST_KEY_` build setting; it lives in `OnYourMarks/Info.plist`, which Xcode merges into the generated Info.plist (`INFOPLIST_FILE`), and which is excluded from the app target's resources in the synchronized group.

Stamps are taken next to the network, not on the main actor: `NodeLink` runs on the transport's threads, answers a clock request on the spot and pairs replies there. The main actor only gets finished exchanges.

## Nodes

- `NodeID`: a UUID kept across launches, shown as a four-character code (`K7QX`) on the phone itself and next to it in the other phones' lists: that is how a user tells which is which.
- `NodeRole`: controller, camera, speaker. Chosen on each phone.
- Messages (`NodeMessage`, in a `NodeEnvelope` with protocol version, sender and clock epoch): `hello`, `syncRequest`, `syncReply` now. Detector events and "play the gun at this time" become further cases. A phone with another protocol version is listed as incompatible and not talked to.
- Pairing: phones advertise themselves (Bonjour record with ID, name, role, version); the user pairs the ones to work with, by name and code. Only paired phones are synchronized. Pairing is not authentication (see *Security*).
- The **Phones** screen in the settings is the instrument: for each paired phone, live, the width of the offset interval now, the round trips (last, minimum, median), the measured rate with its limits, exchanges, losses, the kernel lead, violations and clock restarts.

## The remote speaker (design)

A phone that plays the gun while another watches. Designed against `SignalPlayer`, so the engine stays as it is:

1. **Preflight.** The controller's `RemoteSignalPlayer.prepareForStart()` sends `prepare`; the speaker runs its own `AudioController.prepareForStart()` and answers with its `AudioPreflight`. The preflight fails if the speaker doesn't answer within the wait, or if the clock of the speaker isn't known (no mapping, or one wider than a limit that a start accepts).
2. **Schedule.** `schedule(.go, at: T)` is synchronous in the protocol. The controller sends `scheduleGun(T, nonce)` with T on its own clock and returns at once a `ScheduledSignal` built from what it knows: render start T, audible onset T + the speaker's latency and onset offset, widened by the speaker's uncertainty **and** the synchronization's width. The message is repeated every few milliseconds until acknowledged (idempotent by nonce).
3. **On the speaker.** It converts T into its own clock with its own mapping of the controller (`localTime(forRemote:)`), schedules at the best value on its audio clock as `AudioController` does, and reports back the render start it scheduled, on its own clock, with its timing basis.
4. **Heard time.** The controller converts the speaker's reported audible onset with *its* mapping of the speaker (`localEstimate(forRemote:)`). Only that one synchronization bound enters the gun's time: the speaker's conversion error decides *when* it plays, not how well the controller knows when it played. After the gun the speaker reads its render timeline back (`measuredPlayback`) and reports it; the engine's existing `gunTimeRevised` path widens the gun's time if the measurement and the schedule differ.
5. **Taking the gun back.** Locally a stop before `cancellableUntil` silences the gun. Remotely there is no upper bound on how long a `cancel` takes to arrive (C2 gives only a lower bound). So the controller's `cancellableUntil` is T minus the speaker's cancellation lead minus a cancellation budget (for example 100 ms), and a cancel counts only once the speaker has acknowledged it, with a stop that happened before its own `cancellableUntil`. Without that acknowledgement the gun counts as possibly out, and the engine must treat it as fired for the decision (and recall if needed). This is the one change the engine would need: a cancellation that can be unconfirmed.
6. **Session record.** The gun's events get `MeasurementSource.remoteSignal(nodeID)`; the mapping's width at the gun is recorded with them, so a review can tell how much of the interval came from the synchronization.

Not implemented yet; single-phone starts are untouched.

## The audio path: a second synchronization

Sound gives relations between the clocks that don't go through the network.

- **Two-way acoustic exchange.** Phone A plays a click at a known render time; both phones' microphones hear it. Then B plays one; both hear it. Each arrival is a "receive after send" (C2 with the speed of sound, 343 m/s), so theorem 1 holds with the click as the message: the offset lies in an interval whose width is twice the travel time over the distance between the phones plus the output and input latency uncertainties. The distance cancels out of the midpoint but not out of the width: 10 m apart is 58 ms wide, far wider than the network, but independent of the network, its stamping and its drivers. With the distance known to ±d, the travel time can be taken out and the width shrinks to 2d/343 plus the latencies.
- **A camera that hears the gun itself would need no synchronization**, but it is not used to time the gun. The reaction would be `movement − heard at the camera + (d(speaker, camera) − d(speaker, athlete))/c`, and on a track neither distance is known; a noisy track can also put a shout or a clap where the gun is searched. The gun's time comes from the speaker's own timing model; a microphone only checks it where it sits next to the output (the iPhone speaker).
- **Cross-checks.** The network predicts when the camera phone should hear the gun: the speaker's heard time, converted, plus d(speaker, camera)/c. The camera's microphone measures it. If the two intervals (each widened by its own terms, the distance by its bound) don't overlap, one of them is wrong: a synchronization violation the network data alone couldn't see (say, a constant asymmetry in stamping), or a microphone onset that is wrong. Conversely the acoustic result checks the network's rate over a long session.
- **What each can prove.** The network bound is proven from causality and A1 to A3, with no knowledge of distances, and gets as tight as the radio's round trips. The acoustic bound is proven from causality, the speed of sound (which depends on temperature: 331 + 0.6 × °C m/s, so ±2 % over a season) and the latency bounds of speaker and microphone, and needs distances or their bounds. Neither can check A4.

## Security

Nothing is authenticated. A phone on the same network that speaks the protocol can pair, and a paired phone that lies about its stamps moves the interval wherever it likes (A4). For training among friends that is acceptable; for anything more the datagrams need DTLS with a key exchanged at pairing (the Network framework's `DTLS` protocol in the same stack).

## Measurements to make on two phones

The test `twoPhonesSynchronize` (`TEST_RUNNER_RUN_SYNC_PEER=1`) runs on two devices, or a device and a simulator, at the same time. Each finds the other, synchronizes for 60 s and attaches its numbers (`sync-peer.txt`): round trips (minimum, median, 95th percentile), the interval's width (median, largest), the measured rate with its limits, losses, the kernel lead, violations and restarts. What it answers:

1. How wide the interval gets over AWDL without an access point, and over an access point. The decision needs the width well below the 100 ms threshold; a few milliseconds would be good.
2. The real relative rate between two phones, against the assumed 200 ppm, at rest and warm (camera running, in the sun).
3. How much later the app stamps than the kernel (if large, the kernel stamp is worth its assumption).
4. Whether violations or restarts ever happen in practice, and why.
5. Ground truth, later: a click played by one phone and recorded by both microphones next to each other gives an independent interval (see *The audio path*); the network interval must overlap it in every trial.

A simulator and the iPhone on the same Wi-Fi network can serve as the second node for a first measurement: the simulator runs on the Mac's host clock and network stack, so the round trips are Mac-to-phone over Wi-Fi (probably wider than phone-to-phone over AWDL), and the rate is the Mac's crystal against the phone's. It cannot replace two phones for the AWDL numbers.
