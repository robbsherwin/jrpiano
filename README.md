PCjr Keyboard Piano in BASIC
The PCjr's built-in Cassette/Disk BASIC makes this pretty straightforward. The SOUND command drives the SN76496 chip directly, and INKEY$ lets you poll the keyboard without blocking.
The program maps keys like a piano keyboard — the bottom row as white keys, the top row as black keys (sharps):
  W E   T Y U        ← sharps (black keys)
 A S D F G H J K L   ← naturals (white keys)


Notes
Duration — SOUND F, 4 plays for ~0.22 seconds (4 of 18.2 ticks/sec). Increase to 9 or 18 for a more sustained feel, or decrease to 2 for a staccato tap.

Octave shift — Z and X halve or double all frequencies, letting you reach bass or high registers. The clamps on lines 496–497 keep you within the chip's valid range (37–32767 Hz).

Sharps — These check the original lowercase K$ before the uppercase conversion, since W/E/T/Y/U are also valid natural key inputs (they fall through harmlessly if uppercase).

Loading it — If you're typing this in, LIST and SAVE "PIANO" to keep it. Run with RUN.


