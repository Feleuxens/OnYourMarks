# Several Phones [Experimental]

The goal: one phone plays the gun, one or two others watch the athletes, later one stands at the finish. For that, every phone has to know the others' clocks.

> [!NOTE]
> Today the phones only synchronize their clocks. Nothing in a start uses another phone yet.

## Overview

Phones find each other over Wi-Fi, also without an access point (as on a track), and exchange clock readings ten times a second. From these each phone keeps an interval that is guaranteed to contain the other phone's clock offset, as long as two stated assumptions hold. The proof is in [Clock synchronization](../developer/clock-sync.md).

## Pairing

1. Open Settings → **Phones** on every phone.
2. Switch on **Connect to other phones**. iOS asks for local network access the first time.
3. Choose this phone's **Role**: Controller, Camera or Speaker.
4. Under **Nearby phones**, tap **Pair** next to the other phones.

Each phone shows a four-letter **Code**. The other phones show the same code next to its name, so you can tell which is which.

Nothing uses the network until **Connect to other phones** is on.

## What the Phones screen shows

For each paired phone, live:

| | |
|---|---|
| **Offset interval** | How wide the interval holding the other clock's offset is right now. It widens between exchanges and narrows with each. |
| **Round trip** | Last, shortest and median time for a reading to go there and back. |
| **Rate** | How fast the two clocks drift apart, measured, with its limits. |
| **Exchanges (sent, lost)** | |
| **Kernel lead** | How much later the app reads an arriving message than the system received it. |
| **Clock restarts** | The other phone rebooted or slept; synchronization starts over. |
| **Assumptions violated** | The readings contradict an assumption. The phone shows **Clock not trusted** for 10 s. |

Phones with another app version are listed but not synchronized.

## Limitations

- Not yet measured between two real phones.
- Messages are not encrypted or authenticated. Any phone on the same network running the app can pair.
