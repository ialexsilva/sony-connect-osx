# SonyConnect macOS

A macOS menu-bar app that controls Sony headphones using the first-generation proprietary protocol used by the WH-1000XM3/XM4 — toggle the touch panel, switch between Noise Cancelling / Ambient Sound / Off, adjust the Ambient Sound level and Focus on Voice, turn Speak-to-Chat on or off, and power the headphones off on demand or automatically after an idle window, all from the menu bar.

<img width="265" height="305" alt="image" src="https://github.com/user-attachments/assets/16ec2f0d-85c1-4ef6-abfa-af35522f731b" />



## Features

- Watches for a paired Sony WH-1000XM3/XM4/XM5/XM6 and opens a known Sony control channel on demand when audio starts or the menu is opened
- Menu-bar UI:
  - **Touch Sensor** (enable / disable the right-earcup swipe panel)
  - **Noise Cancelling** — On / Ambient Sound / Off, with Ambient level (1–20) and Focus on Voice controls
  - **Speak-to-Chat** — On / Off
  - **Equalizer** — preset submenu (names pulled live from the device's capability table) plus a 6-band graphic EQ (5 frequency bands + Clear Bass) with sliders
  - **Volume** — full-width slider over the headphones' output level
  - **Power Off Headphones** on demand, or automatically after 30 min with no audio playing
  - Currently playing media is paused before sending the power-off command, so audio doesn't briefly blast through the internal speakers when A2DP drops
  - Connection status, reconnect, log access
- Picks up state changes coming from the headphones themselves (e.g. pressing the physical NC button) via Sony's NOTIFY packets
- Auto-discovers the firmware-specific "general settings" slot that holds the touch panel control — works across firmware revisions that hard-coded reverse-engineering does not
- Idle detection uses CoreAudio's `kAudioDevicePropertyDeviceIsRunningSomewhere` on the headphones' audio device — accurate, no polling of media keys or fragile private APIs

## Supported headphones

Built and tested on **Sony WH-1000XM4**. The WH-1000XM3 uses the same V1 protocol family and is detected, but is not hardware-verified here.

The transport recognizes both Sony RFCOMM endpoints and negotiates V1 versus V2 from the initialization reply. Only `SonyProtocolV1` is implemented today. A V2 device such as XM5/XM6 is detected explicitly and placed in an unsupported state without receiving V1 feature commands; full XM5/XM6 support still requires the V2 adapter and hardware traces. Device detection alone does not imply feature support.

## Requirements

- macOS 12 Monterey or newer
- Xcode Command Line Tools (`xcode-select --install`) — for `swift build`
- The headphones already paired in System Settings → Bluetooth

## Build & Run

```sh
make run
```

That:

1. Builds a release binary via `swift build -c release`
2. Wraps it in `SonyConnect.app` with `Info.plist` (the bundle and its `NSBluetoothAlwaysUsageDescription` are needed for the Bluetooth permission prompt)
3. Ad-hoc codesigns it
4. Kills any previously running instance and opens the new build

On first launch macOS will ask for Bluetooth permission — approve it once.

Run the framing, protocol-session, and V1 adapter contract tests with `make test`. `make clean` removes build artefacts.

## Usage

A headphones icon remains available in the menu bar while SonyConnect is running. It appears dimmed when the headphones are off or out of range. Click it (left or right) to open the menu:

- **Touch Sensor: ON / OFF** — click to toggle
- **Noise Cancelling ▸** — submenu with three radio-style options (NC, Ambient, Off) plus Ambient Sound level and Focus on Voice settings
- **Speak-to-Chat: ON / OFF** — click to toggle
- **Power Off after 30 min idle** — checkbox; when on, the app sends the power-off command if no audio plays on the headphones' audio device for 30 minutes. Setting is persisted in `UserDefaults` and survives relaunch.
- **Power Off Headphones** — sends the power-off command immediately. The headphones shut down and Bluetooth disconnects.
- **Reconnect** — re-runs the discovery sequence (useful after the headphones suspend or get re-paired)
- **Open Log…** — reveals `~/Library/Logs/SonyConnect.log` in Finder

## How it works

Sony headphones expose proprietary RFCOMM services on top of classic Bluetooth:

- V1: `96CC203E-5068-46AD-B32D-E316F5E069BA` (advertised as "Serial HPC")
- V2: `956C7B26-D49A-4BA8-B03F-B17D393CB6E2`

Frames look like this:

```
0x3E  data_type  seq  len(BE32)  payload  checksum  0x3C
```

`0x3C` / `0x3D` / `0x3E` bytes inside the body are escape-encoded: prefixed with `0x3D` and XOR-ed with `0xEF`. The checksum is the sum of all body bytes mod 256.

After RFCOMM opens, the protocol session:

1. Tries the known service endpoints in a compatibility-safe order and sends `INIT_REQUEST` (`00 00`).
2. Uses the canonical reply length (four bytes for V1, eight for V2) when available, with service context and a legacy V1 state-push fallback.
3. Serializes requests so only one command waits for an ACK at a time, retries a timed-out frame, and fails closed after the configured attempt limit.
4. Acknowledges every non-ACK packet with the opposite sequence number (Sony's "expected next seq" convention).
5. For V1, discovers general-setting capabilities, queries NCASM, Smart Talking Mode, battery and equalizer state, and listens for NOTIFY packets to keep the UI synchronized.
6. For V2, reports that the protocol was detected but does not send feature commands until `SonyProtocolV2` is implemented.

V1 SET commands:

| Feature             | Payload                                                                   |
| ------------------- | ------------------------------------------------------------------------- |
| Touch panel         | `D8 <slot> <type> <value>` (slot/type from capability discovery)          |
| Noise Cancelling    | `68 02 11 <ncType> 02 <asmType> 00 00` (DUAL NC)                          |
| Ambient Sound       | `68 02 11 <ncType> 00 <asmType> <asmId> <asmLevel>` (level 1…20)           |
| NC Off              | `68 02 00 <ncType> 00 <asmType> 00 00`                                    |
| Speak-to-Chat       | `F8 05 01 <0\|1>`                                                          |
| EQ preset           | `58 01 <presetId> 00` (`EQEBB_SET_PARAM` + `PRESET_EQ`)                   |
| EQ custom bands     | `58 01 FF <nBands> <b0…bN>` (preset `UNSPECIFIED`, values 0…20, 10 = flat) |
| Power Off           | `22 00 01` (`COMMON_SET_POWER_OFF` + `USER_POWER_OFF`)                    |

`ncType` and `asmType` come from the device's GET response — different firmware uses different setting-type bytes (`LEVEL_ADJUSTMENT = 0x01` vs `DUAL_SINGLE_OFF = 0x02`), so they're read live rather than hardcoded.

## Architecture

Bluetooth and macOS lifecycle code stay in the app target. Framing, negotiation, ACK/retry behavior, protocol-neutral intents/events, and every V1 opcode live in `SonyConnectCore`:

```
BluetoothClient → HeadphonesController → SonyProtocolSession
                                            │
                                            ├── framing / ACK / queue / retries
                                            └── SonyProtocolAdapter
                                                      └── SonyProtocolV1
```

`HeadphonesController` submits operations such as `getBattery` or `setNoiseControl`; the session owns wire reliability and the selected adapter owns protocol payloads and converts replies into typed events. This is the seam where `SonyProtocolV2` will be added. Unknown frame types retain their raw value instead of being silently decoded as V1.

The invariants and next V2 implementation slice are documented in [`docs/PROTOCOL_ARCHITECTURE.md`](docs/PROTOCOL_ARCHITECTURE.md).

## Project layout

```
Sources/SonyConnectCore/
  SonyPacket.swift           — shared frame encoding / incremental stream parser
  SonyProtocol.swift         — protocol-neutral intents, requests, events, adapter contract
  SonyProtocolSession.swift  — negotiation, ACK correlation, queueing, timeout and retries
  SonyProtocolV1.swift       — complete V1 payload encoder/decoder used by the app
Sources/SonyConnect/
  main.swift               — NSApplication bootstrap (.accessory mode, no Dock icon)
  AppDelegate.swift        — Owns the menu bar controller
  MenuBarController.swift  — NSStatusItem, menu, click routing
  HeadphonesController.swift — transport/protocol coordination + UI-facing state
  BluetoothClient.swift    — IOBluetooth RFCOMM wrapper, SDP query, ACL reachability
  ConnectionPolicy.swift   — lazy connect + idle disconnect (battery saving)
  AudioActivityMonitor.swift — CoreAudio "is the device playing" probe
  AutoPowerOff.swift       — idle-based power-off timer
  MediaController.swift    — Pauses Now-Playing media via MediaRemote.framework
  VolumeController.swift   — CoreAudio output-volume get/set
  EqualizerView.swift      — graphic-EQ band sliders (custom menu-item view)
  ScrollableSlider.swift   — stepped sliders with coalesced scroll-wheel support
  SupportedDevices.swift   — device name hints
  FileLogger.swift         — Plain-text log to ~/Library/Logs/SonyConnect.log
Tests/SonyConnectCoreTests/ — framing, session, and V1 adapter contract tests
Resources/Info.plist       — LSUIElement + NSBluetoothAlwaysUsageDescription
Makefile                   — build, test, app, run, clean
Package.swift              — Swift Package Manager manifest
```

## Limitations

- Ad-hoc codesigned only — not notarized, not signed for distribution. Re-sign before sharing the `.app` with anyone else.
- Connects to the first matching paired device. Multi-device routing not implemented.
- V2 transport detection is implemented, but V2 feature commands are intentionally disabled until the V2 adapter is complete and hardware-verified.
- Only the features above are wired up. Multipoint, firmware controls, configurable auto-power-off duration, voice guidance, wear detection, etc. are protocol-supported but unimplemented.
- The Sony protocol is reverse-engineered — a firmware update can change opcodes. If the touch toggle stops doing anything physical, check `~/Library/Logs/SonyConnect.log` for the device's capability response and adapt.

## Credits

Protocol details built on prior reverse-engineering work:

- [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) — Android open-source companion app, source for the V1 opcode tables and `GsInquiredType` / capability negotiation logic
- [SonyHeadphonesClient](https://github.com/Plutoberth/SonyHeadphonesClient) — C++ client, source for the framing and NCASM payload structure

The auto-discovery of the touch panel general-settings slot via `GENERAL_SETTING_GET_CAPABILITY` was derived from the Sony Headphones Connect Android app via `jadx` decompilation when the hard-coded `D8 D2 01 xx` from the open-source clients turned out to be the wrong slot on the WH-1000XM4 firmware tested.
