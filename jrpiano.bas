10  KEY OFF
20  CLS
30  PRINT "=============================="
40  PRINT "     PCjr KEYBOARD PIANO"
50  PRINT "=============================="
60  PRINT ""
70  PRINT "  W E   T Y U    (sharps)"
80  PRINT " A S D F G H J K L"
90  PRINT " C D E F G A B c d"
100 PRINT ""
110 PRINT " Z/X = octave down/up"
120 PRINT " ESC = quit"
130 PRINT ""
140 OC = 0
150 PRINT "Octave shift: 0"
160 '
170 ' ---- MAIN LOOP ----
180 K$ = INKEY$
190 IF K$ = "" THEN 180
200 IF K$ = CHR$(27) THEN END
210 '
220 ' Octave shift keys
230 IF K$ = "z" OR K$ = "Z" THEN OC = OC - 1 : GOSUB 500 : GOTO 180
240 IF K$ = "x" OR K$ = "X" THEN OC = OC + 1 : GOSUB 500 : GOTO 180
250 '
260 ' Convert to uppercase for natural keys
270 KC = ASC(K$) AND 223
280 F = 0
290 '
300 ' Natural keys (white keys) - C major scale
310 IF KC = ASC("A") THEN F = 262  ' C4
320 IF KC = ASC("S") THEN F = 294  ' D4
330 IF KC = ASC("D") THEN F = 330  ' E4
340 IF KC = ASC("F") THEN F = 349  ' F4
350 IF KC = ASC("G") THEN F = 392  ' G4
360 IF KC = ASC("H") THEN F = 440  ' A4
370 IF KC = ASC("J") THEN F = 494  ' B4
380 IF KC = ASC("K") THEN F = 523  ' C5
390 IF KC = ASC("L") THEN F = 587  ' D5
400 '
410 ' Sharp keys (black keys) - use lowercase to distinguish
420 IF K$ = "w" THEN F = 277  ' C#4
430 IF K$ = "e" THEN F = 311  ' D#4
440 IF K$ = "t" THEN F = 370  ' F#4
450 IF K$ = "y" THEN F = 415  ' G#4
460 IF K$ = "u" THEN F = 466  ' A#4
470 '
480 ' Apply octave shift and play
490 IF F = 0 THEN 180
495 F = F * (2 ^ OC)
496 IF F < 37 THEN F = 37
497 IF F > 32767 THEN F = 32767
498 SOUND F, 4
499 GOTO 180
500 '
510 ' Subroutine: display octave
520 LOCATE 15, 1
530 PRINT "Octave shift: "; OC; "  "
540 RETURN