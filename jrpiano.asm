; ============================================================================
; JRPIANO.ASM  ·  PCjr Keyboard Piano
; ============================================================================
; IBM PCjr  ·  Intel 8088  ·  MS-DOS .EXE file
;
; The PCjr contains a Texas Instruments SN76496 3-voice programmable sound
; generator, clocked from the 3.579545 MHz NTSC colour-burst crystal.
; Tone frequency for a channel:
;
;       F  =  3,579,545 / (32 x N)       N = 10-bit counter, range 1-1023
;
; Commands are written as single bytes to I/O port 0C0h.
;
;   LATCH byte  (bit 7 = 1):  1  RR  T  D3 D2 D1 D0
;       RR  = channel select  00=tone0  01=tone1  10=tone2  11=noise
;       T   = 0 -> frequency register   1 -> attenuation register
;       D3..D0 = low 4 bits of 10-bit counter N
;
;   DATA byte   (bit 7 = 0):  0  0  D9 D8 D7 D6 D5 D4
;       Upper 6 bits of the previously latched register's counter N
;
;   Volume: attenuation 0000 = loudest, 1111 = silent
;   Channel 0 full volume:  1 00 1 0000  =  90h
;   Channel 0 silent:       1 00 1 1111  =  9Fh
;
; Startup sets port 61h bits 5:6 to route SN76496 audio to the speaker
; (required on real PCjr hardware; DOSBox ignores this gating).
; do_play writes two frequency bytes plus a volume byte (attenuation=0)
; on every note.  Re-sending the volume byte restores sound after SPACE.
; A push/pop delay before the volume byte guards against rapid consecutive
; writes being dropped by the gate array on real hardware.
;
; Keyboard layout:
;   W E   T Y U       <- black keys  (C#  D#  F#  G#  A#)
;  A S D F G H J K L  <- white keys  (C   D   E   F   G   A   B   c   d)
;
;   SPACE = silence   Z / X = octave down / up   ESC = quit
;
; -------------------------------------------------------------------------
; Assemble:  MASM JRPIANO.ASM;
; Link:      LINK JRPIANO.OBJ;
; Run:       JRPIANO
; ============================================================================

        .8086                       ; Target the 8088 in the PCjr

; ---- Assembler constants (no code generated) --------------------------------
SND_PORT  EQU  0C0h         ; SN76496 write port (PCjr-specific)
N_MIN     EQU  14           ; Frequency ceiling ~7990 Hz  (prevents ultrasonic)
N_MAX     EQU  1023         ; Frequency floor   ~109 Hz   (chip 10-bit max)
OCT_MIN   EQU  -3           ; Lowest octave shift
OCT_MAX   EQU  3            ; Highest octave shift

; ---- Stack segment (required for EXE format; DOS sets up SS:SP from this) ---
STCK    SEGMENT STACK 'STACK'
        db  256 dup (?)     ; 256 bytes is generous for our shallow call depth
STCK    ENDS

; ---- Code + data segment ----------------------------------------------------
; All data lives here alongside the code.  ASSUME DS:CODE is valid after we
; point DS at CS in the start-up code below.
CODE    SEGMENT 'CODE'
        ASSUME CS:CODE, DS:CODE, SS:STCK

; ============================================================
;  ENTRY POINT
; ============================================================
start:
        ; For EXE files DOS sets DS = ES = PSP segment, not our code segment.
        ; We keep data in CODE, so redirect DS to CS before touching any data.
        mov  ax, CS
        mov  ds, ax

        mov  ax, 0003h      ; INT 10h mode 3 = 80x25 colour text; clears screen
        int  10h

        mov  dx, OFFSET msg_banner
        mov  ah, 09h
        int  21h

        ; On the PCjr, port 61h (PPI Port B) bits 6:5 select the speaker audio
        ; source.  After reset they default to 00 (8253 timer = PC-speaker beeper).
        ; The SN76496 will never be heard until we set bits 5 and 6 to 11.
        ; DOSBox does not enforce this gating, which is why the program appeared
        ; to work in the emulator but produced complete silence on real hardware.
        in   al, 61h
        or   al, 60h        ; bits 6 and 5 = 11: route SN76496 to speaker
        out  61h, al

        ; Initialise all four SN76496 channels to silent so we start from a
        ; known state regardless of what the BIOS left behind at power-on.
        ; Attenuation 1111 = silent.
        ;   Channel 0 tone attenuation:  1 00 1 1111 = 9Fh
        ;   Channel 1 tone attenuation:  1 01 1 1111 = 0BFh
        ;   Channel 2 tone attenuation:  1 10 1 1111 = 0DFh
        ;   Noise channel attenuation:   1 11 1 1111 = 0FFh
        mov  al, 9Fh        ; ch0 silent
        out  SND_PORT, al
        nop
        nop
        nop
        nop
        nop
        nop
        mov  al, 0BFh       ; ch1 silent
        out  SND_PORT, al
        nop
        nop
        nop
        nop
        nop
        nop
        mov  al, 0DFh       ; ch2 silent
        out  SND_PORT, al
        nop
        nop
        nop
        nop
        nop
        nop
        mov  al, 0FFh       ; noise silent
        out  SND_PORT, al
        nop
        nop
        nop
        nop
        nop
        nop
        ; Unmute channel 0 so it is ready to play on the first key press.
        ; Attenuation 0000 = loudest:  1 00 1 0000 = 90h
        mov  al, 90h
        out  SND_PORT, al

        call show_octave    ; draw "+0" in the banner's Octave line

; ============================================================
;  MAIN KEYBOARD LOOP
; ============================================================
main_loop:
        xor  ah, ah         ; AH=0 -> BIOS keyboard read (blocks until keypress)
        int  16h            ; Returns: AL = ASCII char,  AH = scan code

        cmp  al, 1Bh        ; ESC?
        je   do_quit

        cmp  al, ' '        ; SPACE = silence current note
        je   do_silence

        ; Fold to uppercase with a single AND (clears bit 5).
        ; 'a'->'A', 'w'->'W', etc.  Safe: SPACE and ESC already handled above.
        and  al, 0DFh

        cmp  al, 'Z'
        je   oct_down
        cmp  al, 'X'
        je   oct_up

        ; Note lookup: BX = SN76496 counter N, or 0 if key not mapped
        call find_note
        test bx, bx
        jz   main_loop      ; unrecognised key - leave current note ringing

        ; Apply octave shift using a CL-count shift (valid on 8088)
        mov  cl, [octave]   ; signed byte, range OCT_MIN...OCT_MAX
        cmp  cl, 0
        je   do_play        ; octave == 0: play note as-is
        jg   shift_up       ; positive -> higher pitch -> N decreases

        ; Negative octave -> lower pitch -> N increases (left shift)
        neg  cl             ; make count positive
        shl  bx, cl         ; shift N left by |octave| positions
        cmp  bx, N_MAX
        jbe  do_play
        mov  bx, N_MAX
        jmp  do_play

shift_up:
        ; Positive octave -> higher pitch -> N decreases (right shift)
        shr  bx, cl         ; shift N right by octave positions
        cmp  bx, N_MIN
        jae  do_play
        mov  bx, N_MIN
        ; fall through to do_play

; ============================================================
;  PLAY NOTE
;  Three bytes to the SN76496:
;    1. LATCH  - selects channel 0 frequency, loads low 4 bits of N
;    2. DATA   - loads high 6 bits of N
;    3. VOLUME - attenuation = 0 (full volume) -- restores after SPACE
;
;  On real PCjr hardware the SN76496 is clocked at 3.58 MHz; consecutive
;  OUT instructions that arrive too close together can be dropped by the
;  gate array.  The extra NOPs between writes 2 and 3 ensure at least
;  ~15 SN76496 clock periods of separation (~4.2 µs at 4.77 MHz 8088),
;  which is well within the gate array's tolerance on real hardware.
; ============================================================
do_play:
        ; LATCH byte: 1 00 0 D3D2D1D0  ->  80h OR (N AND 0Fh)
        mov  al, bl
        and  al, 0Fh
        or   al, 80h
        out  SND_PORT, al

        ; DATA byte:  0 0 D9D8D7D6D5D4  ->  (N SHR 4) AND 3Fh
        ; Shift count must be in CL on the 8088 (no immediate shift count > 1)
        mov  ax, bx
        mov  cl, 4
        shr  ax, cl
        and  al, 3Fh
        out  SND_PORT, al

        ; Delay before the volume write so real hardware reliably processes
        ; the DATA byte before the gate array accepts the next LATCH byte.
        ; push/pop = 15+12 = 27 cycles @ 4.77 MHz ≈ 5.7 µs ≈ 20 chip clocks.
        ; This is more compact than NOPs and provides greater timing margin.
        push ax
        pop  ax

        ; VOLUME byte: channel 0 attenuation = 0 (loudest): 1 00 1 0000 = 90h
        ; Re-sent on every note so pressing SPACE then a note key works correctly.
        mov  al, 90h
        out  SND_PORT, al

        jmp  main_loop      ; note sustains; loop back for next keypress

; ============================================================
;  HANDLERS
; ============================================================
do_silence:
        ; Channel 0 attenuation = 15 (silent): 1 00 1 1111 = 9Fh
        mov  al, 9Fh
        out  SND_PORT, al
        jmp  main_loop

oct_down:
        mov  al, [octave]
        cmp  al, OCT_MIN
        je   main_loop
        dec  al
        mov  [octave], al
        call show_octave
        jmp  main_loop

oct_up:
        mov  al, [octave]
        cmp  al, OCT_MAX
        je   main_loop
        inc  al
        mov  [octave], al
        call show_octave
        jmp  main_loop

do_quit:
        mov  al, 9Fh        ; silence channel 0 before returning to DOS
        out  SND_PORT, al
        mov  ax, 4C00h
        int  21h

; ============================================================
;  SUBROUTINE: find_note
;    In:  AL = uppercase key character (AND 0DFh applied by caller)
;    Out: BX = SN76496 counter N (1-1023), or 0 if not in table
;    Destroys: SI, BX
; ============================================================
find_note:
        push si
        mov  si, OFFSET note_tab
fn_scan:
        mov  bl, [si]
        test bl, bl         ; 00h = end-of-table sentinel
        jz   fn_miss
        cmp  bl, al
        je   fn_hit
        add  si, 3          ; advance: 1-byte key + 2-byte N word
        jmp  fn_scan
fn_hit:
        mov  bx, [si+1]     ; load 16-bit N value (little-endian)
        pop  si
        ret
fn_miss:
        xor  bx, bx         ; return 0 = not found
        pop  si
        ret

; ============================================================
;  SUBROUTINE: show_octave
;    Overwrites the sign+digit at the "Octave: +0" position
;    in the banner.  The +/- character is at row 8, column 10.
;    (Verified: the leading CR/LF in msg_banner puts the title
;     on row 1, counting down to the Octave line at row 8.)
;    Destroys: AX, BX, DX
; ============================================================
show_octave:
        mov  ah, 02h        ; INT 10h: set cursor position
        xor  bh, bh         ; display page 0
        mov  dh, 8          ; row 8 (0-based): the "Octave:" line
        mov  dl, 10         ; col 10 (0-based): the +/- sign
        int  10h

        mov  al, [octave]
        cmp  al, 0
        jl   so_neg         ; negative -> print '-' then absolute value

        push ax             ; positive/zero: save for digit
        mov  al, '+'
        call tty
        pop  ax
        jmp  so_digit

so_neg:
        push ax             ; save negative value
        mov  al, '-'
        call tty
        pop  ax
        neg  al             ; make absolute value

so_digit:
        add  al, '0'        ; convert single digit to ASCII
        call tty
        mov  al, ' '        ; trailing space clears any leftover character
        call tty
        ret

; ============================================================
;  SUBROUTINE: tty
;    Print character in AL via BIOS teletype (INT 10h / AH=0Eh).
;    Advances cursor automatically.  No DL setup needed.
;    Destroys: AX, BX
; ============================================================
tty:
        mov  ah, 0Eh
        xor  bh, bh         ; display page 0
        mov  bl, 07h        ; attribute: light grey on black
        int  10h
        ret

; ============================================================
;  DATA
; ============================================================
octave  db  0               ; signed octave shift (OCT_MIN...OCT_MAX)

; note_tab: packed 3-byte records  [db uppercase_key]  [dw N_counter]
; Terminated by a 00h sentinel byte.
;
; N = round( 3,579,545 / (32 x f_Hz) )  =  round( 111,860.78 / f_Hz )
;
; All keys are uppercase because main_loop applies AND AL, 0DFh before
; calling find_note.  Natural keys (ASDFGHJKL) and sharp keys (WETYU)
; are distinct uppercase letters with no overlap.
;
; N values match piano2.asm (slightly more accurate than jrpiano.bas).
note_tab:
        ; White keys (C major scale)
        db  'A'
        dw  428             ; C4   261.4 Hz  (std 261.63)
        db  'S'
        dw  381             ; D4   293.6 Hz  (std 293.66)
        db  'D'
        dw  339             ; E4   330.0 Hz  (std 329.63)
        db  'F'
        dw  320             ; F4   349.6 Hz  (std 349.23)
        db  'G'
        dw  285             ; G4   392.5 Hz  (std 392.00)
        db  'H'
        dw  254             ; A4   440.5 Hz  (std 440.00)
        db  'J'
        dw  227             ; B4   492.9 Hz  (std 493.88)
        db  'K'
        dw  214             ; C5   522.7 Hz  (std 523.25)
        db  'L'
        dw  190             ; D5   588.7 Hz  (std 587.33)
        ; Black keys (sharps)
        db  'W'
        dw  404             ; C#4  276.9 Hz  (std 277.18)
        db  'E'
        dw  360             ; D#4  310.7 Hz  (std 311.13)
        db  'T'
        dw  302             ; F#4  370.5 Hz  (std 369.99)
        db  'Y'
        dw  269             ; G#4  415.8 Hz  (std 415.30)
        db  'U'
        dw  240             ; A#4  466.1 Hz  (std 466.16)
        db  0               ; end-of-table sentinel

; msg_banner: '$'-terminated string for INT 21h / AH=09h.
; After INT 10h mode set, cursor is at row 0 col 0.  The leading CR/LF
; pushes the title to row 1.  The "Octave: +0" line therefore lands on
; row 8; show_octave repositions to (row=8, col=10) to overwrite "+0".
msg_banner:
        db  0Dh, 0Ah
        db  '  PCjr KEYBOARD PIANO', 0Dh, 0Ah
        db  '  ===================================', 0Dh, 0Ah
        db  0Dh, 0Ah
        db  '   [W][E]       [T][Y][U]   <- sharps', 0Dh, 0Ah
        db  '  [A][S][D][F][G][H][J][K][L]', 0Dh, 0Ah
        db  '   C  D  E  F  G  A  B  c  d', 0Dh, 0Ah
        db  0Dh, 0Ah
        db  '  Octave: +0   (Z/X to shift)', 0Dh, 0Ah
        db  '  SPACE = silence     ESC = quit', 0Dh, 0Ah
        db  '$'

CODE    ENDS
        END    start
