# ABTrackPTPad

[日本語版 README](README.md)

A menu-bar app that turns the Amazon Basics TK053 (a Windows Precision Touchpad–compliant Bluetooth trackpad,
officially not supported on macOS) into a multi-touch gesture trackpad on macOS.

- Tested on: macOS 26.5 / Apple Silicon
- Target device: `amazonbasics_touchpad` (VID `0x248A` / PID `0x8208`)
- Distribution: source only (build it yourself). Not signed or notarized by Apple.

## Features

| Gesture | Action |
|---|---|
| One finger | Move the pointer |
| One-finger tap / physical click | Left click |
| Tap, then touch again and move | Drag |
| Two-finger tap / two-finger physical click | Right click |
| Two-finger swipe | Scroll (with momentum) |
| Two-finger pinch | Zoom |
| Three-finger tap | Middle click |
| Three/four-finger swipe up / down | Mission Control / App Exposé |
| Three/four-finger swipe left / right | Switch Spaces |

All settings live in the app and are **independent from the built-in MacBook trackpad settings**.

## Installation

Requirements: Xcode Command Line Tools (Xcode itself is not needed)

```sh
xcode-select --install                          # if not installed yet
git clone https://github.com/knkz1114/ABTrackPTPad.git
cd ABTrackPTPad
./make-signing-cert.sh                          # create a self-signed code-signing certificate (once, see below)
CODESIGN_IDENTITY=ABTrackPTPad-dev ./install.sh # build → /Applications/ABTrackPTPad.app → launch
```

Plain `./install.sh` also works (ad-hoc signature), but then you have to re-grant the permissions after every rebuild.

### Permissions (first launch)

On launch the app asks for **Accessibility**.
Enable `ABTrackPTPad` in System Settings > Privacy & Security > Accessibility.
The app may not appear under Input Monitoring; the Accessibility grant also covers HID access.

macOS does not apply a newly granted permission to a running process, so the app relaunches itself automatically once it detects the grant.

### Connecting the trackpad

1. Have the app running
2. Turn the trackpad **off and on again** (or disconnect and reconnect it in Bluetooth)
3. Touch the pad right after it connects

The pad only accepts the switch to PTP mode during the first seconds after connecting. The app performs the switch
the moment the device appears and retries up to 10 times every 2 seconds, but if you started the app after the pad
was already connected, power-cycle the pad.

You are done when the menu-bar icon becomes a filled hand and the *Permissions* tab says "running in PTP mode".

### Uninstall

```sh
./install.sh uninstall
```

Remove the Accessibility entry in System Settings manually.

## Usage

Menu-bar hand icon → *Settings…* opens the settings window.

**Gestures tab**

- Tracking speed
- Tap to click / Tap then drag / Two-finger tap for right click
- Natural scrolling (content follows fingers) / Scrolling speed
- Invert left-right and up-down for three-finger swipes
- Launch at login
- Language (System / 日本語 / English) — switches immediately

Changes take effect immediately.

**Permissions tab**

- Accessibility / Input Monitoring status, *Request permissions*, *Open System Settings*
- Trackpad state (not connected / mouse mode / running in PTP mode), report rate, and the error if the HID device cannot be opened
- Diagnostics: turn on *Record raw reports* to keep the last 10 s of raw HID reports in memory, then *Save diagnostics log* writes them to `~/Downloads/ABTrackPTPad-diag-<date>.log` (off by default)

The app log is at `~/Library/Logs/ABTrackPTPad.log`.

## Rebuilding and code signing

macOS ties permissions (TCC) to the app's code signature. Ad-hoc signatures change on every build, so
**after a rebuild macOS treats the app as a new program and the permissions must be granted again**.

`make-signing-cert.sh` creates a self-signed code-signing certificate named `ABTrackPTPad-dev` in your login keychain.
Signing with it keeps the signature stable, so the grants survive rebuilds.

```sh
./make-signing-cert.sh                            # once
CODESIGN_IDENTITY=ABTrackPTPad-dev ./install.sh   # every build / install afterwards
```

The certificate is only valid on this Mac (it is not a distribution signature).

## Troubleshooting

| Symptom | Check |
|---|---|
| Pointer does not move | Accessibility granted in the *Permissions* tab? `IOHIDManagerOpen failed: 0xe00002e2` means not granted |
| Granted but still nothing | Quit and relaunch the app (normally it relaunches by itself) |
| Stopped working after a rebuild | The ad-hoc signature changed. Remove the old entry and grant again, or use `CODESIGN_IDENTITY` |
| Stuck in "mouse mode (waiting for PTP switch)" | See the Q&A below |
| Pad does not even work as a mouse | The pad is still in PTP mode while the app is not running. Start the app or power-cycle the pad |
| Only three-finger swipes fail | A macOS update may have changed the private event format. Please open an issue |

### Q&A: the *Permissions* tab stays at "Connected — mouse mode (waiting for PTP switch)"

**Q. The pointer moves, but two-finger scrolling and gestures do nothing and the tab says "mouse mode".**

A. The pad is running in mouse mode and the switch to PTP mode did not go through. Try, in order:

1. **Power-cycle the pad** (leave the app running).
   The pad only accepts the switch during the first seconds after connecting, so it must connect *after* the app is running.
   Do the same right after re-pairing.
2. If that does not help, look at `~/Library/Logs/ABTrackPTPad.log`. On a healthy connection these three lines appear:
   ```
   read feature 4 (THQA): 0x0 len=257
   set feature 3 = 0 then 3 (PTP mode): 0x0 / 0x0
   digitizer reports active (21 bytes)
   ```
   - `read feature 4` or `set feature 3` shows something other than `0x0` (e.g. `0xe00002e2`) → a permission problem; check Accessibility.
   - Repeated `PTP check N: … no digitizer reports yet` followed by `first report id=1` → the pad ignored the switch. Go back to step 1.
   - No `first report id` line at all → you did not touch the pad, or it is connected to another device (channel). Select this Mac's channel with the Bluetooth button.
3. Remove the pad in Bluetooth settings, pair it again, and power-cycle it once more after pairing.
4. If it still fails, enable *Record raw reports* in the *Permissions* tab, reproduce, save the log and open an issue with it and the app log.

## How it works

- The pad's HID descriptor contains Report 1 (mouse) and Report 2 (digitizer, absolute coordinates for up to 4 fingers)
- Connected to macOS, the pad only sends Report 1 (mouse mode)
- There is no standard PTP Input Mode feature (usage 0x52), but **reading Feature Report 4 (the Windows THQA certification blob)
  and then writing 0x03 to Feature Report 3 switches the pad into PTP mode and Report 2 starts streaming**
  (the firmware treats the THQA read as "a PTP-capable host" and uses feature 3 as its input-mode register.
  The mode resets on reconnect, so the app repeats this on every attach and retries up to 10 times every 2 s)
- macOS does not interpret HID digitizer touchpads natively, so the app seizes the device with `IOHIDManager`, parses the reports
  itself and synthesizes CGEvents for pointer movement, clicks, scrolling, pinch and DockSwipe
- For three/four-finger swipes (DockSwipe), macOS 26.5 ignores the plain CGEvent fields; like
  [joshuarli/iss](https://github.com/joshuarli/iss), the app embeds a raw IOHID payload in field 4205 of the serialized CGEvent
- The firmware's confidence bit is unreliable (0 for real fingers) and is ignored. Reports carry 4 slots (21 bytes)

## Layout

```
Sources/Engine/
  Settings.swift        settings (backed by UserDefaults)
  Synth.swift           CGEvent synthesis (pointer / clicks / scroll / pinch / DockSwipe)
  GestureEngine.swift   PTP report parsing, gesture classification, momentum scrolling
  HIDDevice.swift       IOHIDManager: seize, PTP mode switch, report input, retry while waiting for permission
  Diagnostics.swift     raw report recording and export
  Log.swift             ~/Library/Logs/ABTrackPTPad.log
Sources/App/
  ABTrackPTPadApp.swift menu-bar UI (SwiftUI MenuBarExtra) and settings window
  StatusModel.swift     permission / device monitoring, auto-relaunch, launch at login
  SettingsView.swift    Gestures tab
  StatusView.swift      Permissions tab
  Localization.swift    UI string lookup (L("…"))
Resources/Info.plist
Resources/en.lproj, ja.lproj   UI strings (English keys; to add a language, add <lang>.lproj/Localizable.strings and register it in L10n.available)
Tests/                  GestureEngine unit tests (./Tests/run.sh, no XCTest needed)
build.sh                assembles the .app with swiftc only
install.sh              build → /Applications → launch / uninstall
make-signing-cert.sh    creates the self-signed certificate
```

## Development

```sh
./Tests/run.sh                                  # engine tests
CODESIGN_IDENTITY=ABTrackPTPad-dev ./build.sh   # build/ABTrackPTPad.app
```

`GestureEngine` emits events through the `EventSink` protocol, so the tests substitute a recording implementation.

## Supported devices

**Verified**: Amazon Basics TK053 (Bluetooth, firmware 1.0.0.1)

Other units of the same product work: the app depends on firmware-specific behaviour
(VID/PID, HID descriptor, the feature-4-read → feature-3-write mode switch, report layout), not on the individual unit.

Check the firmware version with:

```sh
system_profiler SPBluetoothDataType | grep -A4 amazonbasics
```

**If the pad is not recognized** (the *Permissions* tab stays at "not connected"), the VID/PID may differ:

```sh
ioreg -l -r -c IOHIDDevice | grep -B2 -A6 amazonbasics | grep -E "VendorID|ProductID"
```

If the values (decimal) are not `9354` / `33288` (= `0x248A` / `0x8208`), change `vendorID` / `productID` in
`Sources/Engine/HIDDevice.swift` and rebuild. If it works with different IDs, please open an issue with the model name and firmware version.

**Untested**: the wired TK054 (USB-C) and other Telink-based PTP pads (Seenda, Jelly Comb, …).
Matching the VID/PID may be enough, but how feature reports 3/4 are used depends on the firmware.

## Notes

- While the app is not running, the pad does not move the pointer if it is still in PTP mode (reconnecting returns it to mouse mode)
- Event synthesis relies on undocumented CGEvent fields and may break with a macOS update

## Disclaimer

This is unofficial software with no affiliation to Amazon, Telink or Apple. Product names are used for identification only.
The software is provided without warranty (see LICENSE).

## License

MIT License. The DockSwipe event construction is based on [joshuarli/iss](https://github.com/joshuarli/iss) (ISC License).
See `THIRD_PARTY_LICENSES.md` for details.
