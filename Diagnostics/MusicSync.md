# Music Sync verification

## Receiver implementation (0.2.1)

Sources: [keylux's OEM packet-capture notes](https://github.com/SibteProf/keylux/blob/main/docs/PROTOCOL.md#wireless-24-ghz--a-different-protocol-on-a-different-device), cross-checked against [wireless-mode.ts](https://github.com/cloudglides/aula-f75-linux-drivers/blob/main/web/src/lib/wireless-mode.ts).

Live colors use output report `0x13`, command `0x88`: groups of RGB, key count, and LED indices. Each message carries at most 84 data bytes in six checksummed fragments. The app splits larger key lists into complete messages, including all tail keys. It explicitly sends black for silence, avoiding the uncertain `0x23` idle frame. Reports are separated by at least 16 ms; whole-board updates are capped at 8 Hz.

The receiver's own configuration is read and validated before streaming. No mode bytes, palettes, keymaps, or saved profiles are changed to enter music mode. Stop invalidates pending sends, reapplies the captured configuration without a save command, and compares all ten fragments. A firmware effect may still repaint over live colors; physical observation is needed. No wired configuration template is ever written over the receiver.

## Checks on September 26, 2026

- Eight release tests pass, including an exact OEM single-key packet, checksums, 80/81-key message boundaries, explicit black, invalid indices/configuration, stereo PCM parsing, and equivalent fade timing across frame rates.
- Connected receiver `3554:FA09`: the read-only check received all ten configuration fragments.
- The initial live test reached cleanup but its final save command was not acknowledged. Since streaming never saves a profile, Stop now only reapplies and reads back the existing configuration.
- The corrected five-second test sent 40 live whole-keyboard cyan frames through the production path, then restored and read back the original configuration byte-for-byte across all ten fragments.
- The user confirmed: "Yes, pulsing and restoration work" on the connected receiver.
- After the user approved replacing the installed app, version 0.2.1 was installed in `/Applications/AULA F75.app`. Reopening showed **AULA F75 · 2.4 GHz · Ready** and an enabled **Start Music Sync** button. No privacy permissions were reset or changed by the agent.
- **Not verified:** typing while streaming and actual Spotify/YouTube audio capture. USB hardware behavior remains unverified.

Opt-in checks (the music check temporarily changes visible lighting):

```sh
swiftc -O -whole-module-optimization -swift-version 6 -D F75_DIAGNOSTICS Sources/AulaF75Mac/F75Device.swift Sources/AulaF75Mac/F75Protocol.swift Diagnostics/TransportCheck.swift -o /private/tmp/aula-wireless-music-check
/private/tmp/aula-wireless-music-check --read-only
/private/tmp/aula-wireless-music-check --music
```
