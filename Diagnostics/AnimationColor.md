# Animated-effect custom colors

The previous packet builder always wrote palette data offset 21 (Fixed on), regardless of the active effect. A palette fragment has 14 data bytes after its length byte; fragment 1 payload bytes 8–10 refer only to this first effect.

Inspection of the downloaded OEM `OemDrv.exe` (May 9, 2024) shows seven RGB triplets per effect: the palette serialization loop at `0x489300` writes triplets at base + 21 through base + 39, then advances 21 data bytes and 36 bytes of internal effect state (`0x489495`). The second serialization path at `0x48e040` has the same layout. The patch selects data offset `21 * effectID` (wired report offset `8 + 21 * effectID`) instead of always selecting 21.

`KB.ini`'s `LedOpt` color column disables custom color for effects 3, 15, 16 and 17 (Rainbow, Rotating windmill, Colorful waterfall, Blossoming). These are now labeled multicolor-only in the UI.

Regression check: `swift test -c release` checks every color-capable effect's wired and wireless RGB location and all wireless checksums. `aula-color-check --green-respire` applies effect 2, brightness 9, speed 2, flags 0, RGB 0/255/0 through the production apply method; hardware acknowledgment/configuration read-back passed. Physical color verification requires the user to observe the LEDs; it is not implied by read-back.

On September 25, 2026, the user confirmed the repeated green Respire test worked perfectly on the connected 2.4 GHz F75. Other effects and the wired color path have packet regression coverage, but have not individually been visually verified.
