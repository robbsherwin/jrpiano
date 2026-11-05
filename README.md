PCjr Keyboard Piano

A keyboard piano for the IBM PCjr that drives the SN76496 sound chip directly.
The main program is `jrpiano.asm`, which plays chords on all three tone
voices. Two earlier single-voice versions are kept in the repo for reference.

- `jrpiano.asm`: the chord version (main). 8088 assembly, MS-DOS `.EXE`,
  built with MASM/LINK.
- `piano2.asm`: a NASM-syntax `.COM` variant of the original single-voice
  program.
- `jrpiano.bas`: a Cassette/Disk BASIC version.
- `jrpiano.zip` holds the original single-voice `jrpiano.asm` and its
  `JRPIANO.EXE`.

## Chord version (`jrpiano.asm`)

Same key layout as the other versions, but up to three notes ring at once:

```
  W E   T Y U        <- sharps (black keys)
 A S D F G H J K L   <- naturals (white keys)
```

- The first note key takes voice 0, the next two distinct keys take voices 1
  and 2. A fourth new note steals voice 0, then 1, then 2 (round-robin).
  Pressing a key already assigned to a voice retriggers that voice only.
- `SPACE` silences all three voices and resets the allocator. While `SPACE`
  is held no new notes start. `Z`/`X` shift the octave (`-3` to `+3`),
  `ESC` quits.
- Key release does not stop a note; notes ring until `SPACE` or until they
  are stolen.

How it reads the keyboard: BIOS `INT 16h` only delivers one character at a
time and typematic repeats look like extra presses, so the program hooks
`INT 09h`, records make/break for every scan code in a table, chains to the
original BIOS handler (with the raw scan byte still in `AL`, which the PCjr
BIOS expects), then empties the BIOS key buffer. The main loop polls that
table for rising edges. `KEY_INT/` holds the Turbo Pascal keyboard unit and
test program the same approach was taken from.

Build and run (MASM/LINK):

```bat
MASM JRPIANO.ASM;
LINK JRPIANO.OBJ;
JRPIANO
```

## Single-voice versions


### Basic (`jrpiano.bas`)

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
- Octave shift: `Z` and `X` halve/double all frequencies, within a shift range
  of `-3` to `+3`. Clamps in the BASIC code keep values within the `SOUND`
  statement's valid range (37-32767 Hz).
- Sharps: `W/E/T/Y/U` and the natural keys are distinct letters, so both
  versions fold input to uppercase and accept either case for every key.

If you're typing it in manually, use `LIST` and `SAVE "PIANO"` to keep it, then
run with `RUN`.

### Assembly (`piano2.asm`)

`piano2.asm` is the original single-voice program in NASM syntax, assembled on
a modern machine as a flat `.COM` file. It talks to the SN76496 at I/O port
`0C0h` on channel 0 only.

- Uses BIOS keyboard input (`INT 16h`), so one note at a time.
- Same key layout as the chord version; `Z`/`X` shift octave (`-3` to `+3`),
  `SPACE` silences, `ESC` exits.
- Routes SN76496 audio to the speaker via port `61h` bits 5 and 6, mutes all
  channels at startup, and re-sends the volume byte with every note so a note
  after `SPACE` is audible.
- Back-to-back SN76496 writes need no software delay: the chip's READY
  pin inserts wait states on real PCjr hardware.

```bash
nasm -f bin -o PIANO2.COM piano2.asm
```


