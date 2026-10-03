# AULA F75 for macOS

**Open-source macOS software for the original AULA F75 mechanical keyboard.** Configure RGB lighting, paint individual keys, change keyboard settings, and make the lights react to Mac audio. The native SwiftUI app talks directly to the keyboard over USB or its 2.4 GHz receiver. No cloud account, kernel extension, or background service is required.

> [!IMPORTANT]
> This project targets the **original AULA F75**, not the F75 Max or other F75 variants. Check the device IDs in [Compatibility](#compatibility) before using it. This is an independent community project, not official AULA software.

## What it can do

| Feature | USB cable | 2.4 GHz receiver |
| --- | --- | --- |
| 18 built-in lighting effects, brightness, speed, and supported custom colors | Yes | Yes |
| Per-key RGB painting | Live direct-mode preview | Saves the color map to the keyboard |
| Music Sync from Mac system audio | Yes | Yes, with slower updates |
| Base and Fn key assignment | Available; hardware behavior needs more testing | No |
| Sleep timer and debounce settings | Available; hardware behavior needs more testing | Available; hardware behavior needs more testing |

The **Macros** tab lets you edit and save profiles locally. Uploading macros to the keyboard is disabled until the firmware's macro format is understood. [Known limitations](#known-limitations) has the current verification status.

## Compatibility

- macOS 13 Ventura or later, with a Swift 6 toolchain to build from source.
- Original AULA F75 wired HID interface: `258A:010C`.
- Original AULA F75 2.4 GHz receiver: `3554:FA09`.
- Bluetooth can type normally, but does not expose the configuration channel this app needs.

Device IDs matter more than the name printed on the case: other revisions may use a different protocol. The F75 Max is a different keyboard and is not supported by this project.

## Install from source

There is no packaged download in this repository yet. On a Mac with Xcode Command Line Tools or Xcode and Swift 6 installed:

```sh
git clone https://github.com/mohithingorani/aula-macos-software.git
cd aula-macos-software
swift test -c release
./build-app.sh
open 'dist/AULA F75.app'
```

`build-app.sh` builds and ad-hoc signs the app in `dist/`; it does not install anything in `/Applications`. If macOS blocks the local build on first launch, Control-click the app and choose **Open**. Rebuilding changes the signed executable and may require granting Input Monitoring again.

## Get started

1. Connect the original F75 using its USB cable in wired mode, or insert its 2.4 GHz receiver. Open the app and click **Refresh** if it does not connect automatically.
2. If prompted, allow this exact app in **System Settings → Privacy & Security → Input Monitoring**, then quit and reopen it. This lets the app access the keyboard's HID configuration interface; it does not store keystrokes.
3. Open **Lighting** to choose an effect and click **Apply Lighting**. The **Per-Key**, **Keys**, and **Settings** tabs expose the other controls. Key assignment requires USB.
4. For audio-reactive lights, open **Music**, choose a color and sensitivity, and click **Start Music Sync**. Grant **Screen & System Audio Recording** permission when macOS asks. On older macOS versions this permission may be called **Screen Recording**.

Music Sync uses Apple's ScreenCaptureKit to read audio levels from Mac apps such as Spotify or a browser. Audio is processed locally; the app does not record audio files or upload audio. Keep the app open while syncing. Some protected audio may not be available. Stop sync before applying another lighting effect.

## Known limitations

- This is an experimental controller, not a complete replacement for the Windows driver. **USB keymaps, USB advanced settings, and USB per-key lighting have not been verified on physical hardware.** Avoid applying an unverified keymap if you need to preserve your current assignments.
- Receiver lighting changes have passed configuration read-back for tested effects, but read-back does not prove every physical LED displays the expected color. Individual effects and firmware revisions still need testing.
- Wireless Music Sync updates more slowly than USB. It reacts to audio volume, not musical tempo. A forced quit or unplugging the keyboard can prevent the app from restoring the previous lighting state; reconnect, click **Refresh**, and apply an effect if needed.
- Macro profiles are saved only on the Mac. Hardware macro upload is intentionally disabled.
- Only the device IDs above are supported. Bluetooth configuration and F75 Max support are outside this project's scope.

If the app detects the keyboard but cannot access it, check **Input Monitoring** for the specific build you opened. If a receiver command times out, stop Music Sync, close other copies of the app, reconnect the receiver, and click **Refresh**. The keyboard's hardware factory reset shortcut is **Fn + Esc** held for about five seconds; use it only if you intend to reset the keyboard.

## Build and contribute

The app is a Swift 6 package. `Sources/AulaF75Mac/AulaF75MacApp.swift` contains the UI, `F75Device.swift` manages HID transport, and `F75Protocol.swift` builds packets. Protocol tests live in `Tests/AulaF75MacTests/`; opt-in hardware checks and research notes live in `Diagnostics/`.

```sh
swift build -c release
swift test -c release
```

Please open an issue with your macOS version, connection mode, device IDs, and the exact error or observed LED behavior. Do not post private HID captures or other sensitive device data. For protocol changes, include tests for packet offsets, checksums, malformed replies, and preservation of unrelated settings. Hardware checks may change keyboard settings; read their source before running them.

## License

Released under the [MIT License](LICENSE).
