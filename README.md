PCjr Keyboard Piano

This repo contains two versions of a keyboard piano for the IBM PCjr:

- A BASIC program using Cassette/Disk BASIC
- An 8086 assembly program (`jrpiano.asm`) for MS-DOS

## Basic

The PCjr's built-in Cassette/Disk BASIC makes this straightforward. The `SOUND`
command drives the SN76496 chip directly, and `INKEY$` polls the keyboard
without blocking.

Keyboard layout:

```
  W E   T Y U        <- sharps (black keys)
 A S D F G H J K L   <- naturals (white keys)
```

Notes:

- Duration: `SOUND F, 4` plays for about 0.22 seconds (4 of 18.2 ticks/sec).
  Increase to 9 or 18 for more sustain, or decrease to 2 for staccato.
- Octave shift: `Z` and `X` halve/double all frequencies. Clamps in the BASIC
  code keep values within the chip's valid range (37-32767 Hz).
- Sharps: these check the original lowercase `K$` before uppercase conversion,
  since `W/E/T/Y/U` are also valid natural-key inputs after folding.

If you're typing it in manually, use `LIST` and `SAVE "PIANO"` to keep it, then
run with `RUN`.

## Assembly

`jrpiano.asm` is an IBM PCjr 8088 MS-DOS `.EXE` version that talks to the
SN76496 at I/O port `0C0h`.

What it does:

- Uses BIOS keyboard input (`INT 16h`) for interactive play.
- Maps the same key pattern as the BASIC version:
  - `A S D F G H J K L` for white keys
  - `W E T Y U` for black keys (`C# D# F# G# A#`)
- `Z`/`X` shift octave down/up (range `-3` to `+3`), `SPACE` silences, `ESC`
  exits.
- Programs channel 0 by writing SN76496 latch/data bytes plus a volume byte.

PCjr-specific behavior:

- On real hardware, audio from the SN76496 must be routed to the speaker by
  setting bits 5 and 6 of port `61h`.
- The program initializes all tone/noise channels to silent, then unmutes
  channel 0.
- A short delay before the volume write improves reliability on real PCjr
  hardware for back-to-back chip writes.

Build and run (MASM/LINK):

```bat
MASM JRPIANO.ASM;
LINK JRPIANO.OBJ;
JRPIANO
```


