; ============================================================================
; JRPIANO.ASM  ·  PCjr Keyboard Piano (chords)
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
;       Upper 6 bits of the previously latched register's counter N.
;       The data byte has no channel field; it updates whichever register
;       the previous LATCH selected.
;
;   Volume: attenuation 0000 = loudest, 1111 = silent
;   Channel 0 full volume / silent:  90h / 9Fh
;   Channel 1 full volume / silent:  0B0h / 0BFh
;   Channel 2 full volume / silent:  0D0h / 0DFh
;
; Version 3 plays chords by using all three tone generators.  The first
; note key takes voice 0 and sustains (same feel as the original single-voice version).  A
; second and third distinct note take voices 1 and 2.  A fourth new note
; steals voice 0, then 1, then 2 (round-robin).  Pressing a key that is
; already assigned to a voice retriggers that voice only.  SPACE silences
; all three tone channels and resets the allocator.  Key release does not
; stop a note; notes ring until SPACE or they are stolen.
;
; BIOS INT 16h only delivers one character at a time, and typematic
; repeats would look like extra presses.  We therefore hook INT 09h
; (IRQ1), record make/break in kbd[], chain to the original handler so
; PCjr/Tandy/clone BIOS keyboard handling still runs, then empty the
; BIOS key buffer.  The main loop polls kbd[] for rising edges.
; (Same approach as KEY_INT\KEYB_OBJ.PAS.)
;
; Startup sets port 61h bits 5:6 to route SN76496 audio to the speaker
; (required on real PCjr hardware; DOSBox ignores this gating).
; play_voice writes two frequency bytes plus a volume byte (attenuation=0)
; on the chosen channel.  Re-sending the volume byte restores sound after
; SPACE.  No software delay is required between SN76496 writes: the chip's
; READY pin inserts ~42 wait states (~8.9 µs) per OUT on real PCjr hardware.
;
; Keyboard layout (XT / PCjr 83-key scan codes in note_tab):
;   W E   T Y U       <- black keys  (C#  D#  F#  G#  A#)
;  A S D F G H J K L  <- white keys  (C   D   E   F   G   A   B   c   d)
;
;   SPACE = silence all voices   Z / X = octave down / up   ESC = quit
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
SC_ESC    EQU  01h          ; XT/PCjr scan: Esc
SC_SPACE  EQU  39h          ; XT/PCjr scan: Spacebar
SC_Z      EQU  2Ch          ; XT/PCjr scan: Z  (octave down)
SC_X      EQU  2Dh          ; XT/PCjr scan: X  (octave up)

; ---- Stack segment (required for EXE format; DOS sets up SS:SP from this) ---
STCK    SEGMENT STACK 'STACK'
        db  512 dup (?)     ; INT 09h + BIOS handler needs more than a leaf call
STCK    ENDS

; ---- Code + data segment ----------------------------------------------------
; All data lives here alongside the code.  ASSUME DS:CODE is valid after we
; point DS at CS in the start-up code below.  The INT 09h ISR also forces
; DS=CS because hardware interrupts do not arrive with our DS.
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
        ; Leave them muted until the first note: unmuting here would play
        ; whatever leftover frequency is still in the chip's period register.
        ; Attenuation 1111 = silent.
        ;   Channel 0 tone attenuation:  1 00 1 1111 = 9Fh
        ;   Channel 1 tone attenuation:  1 01 1 1111 = 0BFh
        ;   Channel 2 tone attenuation:  1 10 1 1111 = 0DFh
        ;   Noise channel attenuation:   1 11 1 1111 = 0FFh
        mov  al, 9Fh        ; ch0 silent
        out  SND_PORT, al
        mov  al, 0BFh       ; ch1 silent
        out  SND_PORT, al
        mov  al, 0DFh       ; ch2 silent
        out  SND_PORT, al
        mov  al, 0FFh       ; noise silent
        out  SND_PORT, al

        call show_octave    ; draw "+0" in the banner's Octave line
        call hook_int9      ; take over make/break; BIOS INT 16h is no longer used

; ============================================================
;  MAIN KEYBOARD LOOP
;  Poll kbd[] (updated by INT 09h) for rising edges.  Level on ESC
;  is enough to quit; SPACE silences on the make edge and, while held,
;  blocks new notes so a chord cannot restart under the spacebar.
; ============================================================
main_loop:
        ; 8088 conditional jumps are SHORT only (±127 bytes).  do_quit
        ; lives well past that, so invert and use a near JMP.
        cmp  byte ptr [kbd+SC_ESC], 0
        je   ml_no_esc
        jmp  do_quit
ml_no_esc:

        ; SPACE: rising edge -> silence all voices.  prev[] makes typematic
        ; repeats (extra makes with no break) a no-op.
        mov  bx, SC_SPACE
        mov  al, [kbd+bx]
        mov  ah, [prev+bx]
        mov  [prev+bx], al
        cmp  al, 1
        jne  ml_not_space
        cmp  ah, 0
        jne  ml_not_space
        call silence_all
ml_not_space:

        ; Octave keys: rising edge only, so holding Z/X does not race.
        mov  bx, SC_Z
        mov  al, [kbd+bx]
        mov  ah, [prev+bx]
        mov  [prev+bx], al
        cmp  al, 1
        jne  ml_not_z
        cmp  ah, 0
        jne  ml_not_z
        call oct_down
ml_not_z:
        mov  bx, SC_X
        mov  al, [kbd+bx]
        mov  ah, [prev+bx]
        mov  [prev+bx], al
        cmp  al, 1
        jne  ml_not_x
        cmp  ah, 0
        jne  ml_not_x
        call oct_up
ml_not_x:

        ; While SPACE is down, do not start notes.
        cmp  byte ptr [kbd+SC_SPACE], 0
        jne  main_loop

        ; Walk note_tab.  Each record is [db scan][dw N].  Sentinel scan=0.
        mov  si, OFFSET note_tab
ml_notes:
        mov  bl, [si]
        test bl, bl
        jz   main_loop      ; end of table -> next poll pass
        xor  bh, bh         ; BX = scan code 0-127
        mov  al, [kbd+bx]
        mov  ah, [prev+bx]
        mov  [prev+bx], al
        cmp  al, 1
        jne  ml_note_next
        cmp  ah, 0
        jne  ml_note_next   ; not a rising edge (held, typematic, or release)

        ; New note press: AL is 1, BL is scan code, [si+1] is base N.
        push si
        mov  al, bl         ; find_note / alloc_play want scan in AL
        call find_note      ; BX = N (always hits: we came from note_tab)
        call apply_octave   ; BX adjusted; AL (scan) preserved
        call alloc_play     ; AL = scan, BX = N
        pop  si
ml_note_next:
        add  si, 3
        jmp  ml_notes

; ============================================================
;  PLAY NOTE ON ONE SN76496 VOICE
;    In:  AL = voice 0..2,  BX = counter N (already octave-adjusted)
;  Three bytes to the chip:
;    1. LATCH  - selects that channel's frequency, loads low 4 bits of N
;    2. DATA   - loads high 6 bits of N (no channel field)
;    3. VOLUME - attenuation = 0 (full volume) for that channel
;
;  Channel bits live in latch bit 6:5 (RR).  voice<<5 yields:
;    0 -> 00h,  1 -> 20h,  2 -> 40h
;  OR those into 80h (freq latch) or 90h (volume latch).
;
;  Back-to-back OUTs are safe on real hardware: SN76496 READY inserts
;  ~42 wait states (~8.9 µs) per write, which is the chip's own load time.
;  Destroys: AX, CX, DX
; ============================================================
play_voice:
        mov  cl, 5
        shl  al, cl         ; AL = RR << 5  (8088: shift count must be in CL)
        mov  dh, al         ; DH = channel select bits for both latches

        ; LATCH: 1 RR 0 D3D2D1D0  ->  80h OR (RR<<5) OR (N AND 0Fh)
        mov  al, bl
        and  al, 0Fh
        or   al, 80h
        or   al, dh
        out  SND_PORT, al

        ; DATA:  0 0 D9D8D7D6D5D4  ->  (N SHR 4) AND 3Fh
        mov  ax, bx
        mov  cl, 4
        shr  ax, cl
        and  al, 3Fh
        out  SND_PORT, al

        ; VOLUME: 1 RR 1 0000  ->  90h OR (RR<<5)
        ; Re-sent every time so SPACE then a note key works correctly.
        mov  al, 90h
        or   al, dh
        out  SND_PORT, al
        ret

; ============================================================
;  ALLOCATE A VOICE AND PLAY
;    In:  AL = keyboard scan code,  BX = N
;  If this scan code already owns a voice, retrigger that voice.
;  Otherwise take voice_next (0,1,2,0,...) and steal if occupied.
;  Destroys: AX, CX, DX, SI
; ============================================================
alloc_play:
        mov  dh, al         ; DH = scan code (play_voice will trash AL)
        mov  si, OFFSET voice_sc
        xor  cx, cx         ; CL = candidate voice 0..2
ap_find:
        cmp  cl, 3
        jae  ap_new         ; not already assigned -> steal/allocate next
        cmp  dh, [si]
        je   ap_use         ; same key still owns voice CL
        inc  si
        inc  cl
        jmp  ap_find

ap_new:
        mov  cl, [voice_next]
        mov  si, OFFSET voice_sc
        xor  ch, ch
        add  si, cx         ; SI -> voice_sc[voice_next]
        mov  [si], dh       ; this scan code now owns that voice
        mov  al, cl
        inc  al
        cmp  al, 3
        jb   ap_wrap
        xor  al, al         ; 2+1 -> 0
ap_wrap:
        mov  [voice_next], al
        ; fall through with CL = allocated voice

ap_use:
        mov  al, cl         ; AL = voice 0..2, BX still = N
        jmp  play_voice     ; tail call (ret from play_voice)

; ============================================================
;  HANDLERS
; ============================================================
silence_all:
        ; Mute all three tone generators.  Noise stays silent from startup.
        mov  al, 9Fh
        out  SND_PORT, al
        mov  al, 0BFh
        out  SND_PORT, al
        mov  al, 0DFh
        out  SND_PORT, al
        xor  al, al
        mov  [voice_next], al
        mov  [voice_sc], al
        mov  [voice_sc+1], al
        mov  [voice_sc+2], al
        ret

oct_down:
        mov  al, [octave]
        cmp  al, OCT_MIN
        je   od_done
        dec  al
        mov  [octave], al
        call show_octave
od_done:
        ret

oct_up:
        mov  al, [octave]
        cmp  al, OCT_MAX
        je   ou_done
        inc  al
        mov  [octave], al
        call show_octave
ou_done:
        ret

do_quit:
        call silence_all    ; don't leave a chord ringing in DOS
        call unhook_int9    ; restore BIOS INT 09h before we vanish
        mov  ax, 4C00h
        int  21h

; ============================================================
;  SUBROUTINE: apply_octave
;    In/Out: BX = SN76496 counter N
;    Preserves: AL (callers keep the scan code there)
;    Destroys: CX
;  Positive octave -> higher pitch -> smaller N (right shift).
;  Negative octave -> lower pitch -> larger N (left shift).
;  Shift count must be in CL on the 8088.
; ============================================================
apply_octave:
        push ax
        mov  cl, [octave]
        cmp  cl, 0
        je   ao_done
        jg   ao_up
        neg  cl
        shl  bx, cl
        cmp  bx, N_MAX
        jbe  ao_done
        mov  bx, N_MAX
        jmp  ao_done
ao_up:
        shr  bx, cl
        cmp  bx, N_MIN
        jae  ao_done
        mov  bx, N_MIN
ao_done:
        pop  ax
        ret

; ============================================================
;  SUBROUTINE: find_note
;    In:  AL = XT/PCjr scan code
;    Out: BX = SN76496 counter N (1-1023), or 0 if not in table
;    Destroys: SI, BX
;    Preserves: AL
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
        add  si, 3          ; advance: 1-byte scan + 2-byte N word
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
;  SUBROUTINE: hook_int9 / unhook_int9
;  DOS INT 21h AH=35h gets the current vector (ES:BX);
;  AH=25h installs DS:DX.  Our DS is already CS.
; ============================================================
hook_int9:
        mov  ax, 3509h      ; AH=35h get vector, AL=09h
        int  21h
        mov  word ptr [old_int9], bx
        mov  word ptr [old_int9+2], es
        mov  dx, OFFSET new_int9
        mov  ax, 2509h      ; AH=25h set vector, AL=09h
        int  21h
        ret

unhook_int9:
        push ds
        lds  dx, [old_int9] ; DS:DX = original INT 09h
        mov  ax, 2509h
        int  21h
        pop  ds
        ret

; ============================================================
;  HARDWARE INTERRUPT: new_int9  (replaces INT 09h / IRQ1)
;
;  1. Read port 60h.  Bit 7 clear = make (key down), set = break (up).
;     Bits 6:0 are the scan code.  Store 1 or 0 in kbd[scan].
;  2. pushf + far CALL the original handler so the system's own
;     keyboard processing still runs (PCjr IR path, Tandy, clones).
;     That pair mimics INT; the old handler's IRET pops flags.
;     AL must still hold the raw scan byte at this point: the PCjr
;     BIOS INT 09h is entered from INT 48h with the scan code in AL
;     and uses that register rather than re-reading port 60h.
;  3. Clear the BIOS keyboard buffer (0040:001A = 0040:001C) so
;     INT 16h / DOS do not also consume these keys.
;
;  DS is unknown on entry: every data reference uses DS=CS.
;  Do not touch the SN76496 here; the main loop owns audio.
; ============================================================
new_int9:
        push ax
        push bx
        push ds
        push cs
        pop  ds             ; DS = CODE (kbd[] and old_int9)

        in   al, 60h        ; raw scan byte; keep AL intact for the chain
        mov  bl, al
        and  bl, 7Fh        ; BL = scan 0-127
        xor  bh, bh         ; BX indexes kbd[]
        mov  byte ptr [kbd+bx], 1   ; assume make -> 1
        test al, 80h
        jz   ni9_chain
        mov  byte ptr [kbd+bx], 0   ; break -> 0
ni9_chain:
        pushf
        call dword ptr [old_int9]   ; AL = raw scan byte, as the BIOS expects

        ; 0040:001A = buffer head, 0040:001C = buffer tail.  Equal = empty.
        cli
        mov  ax, 40h
        mov  ds, ax
        mov  ax, ds:[1Ch]
        mov  ds:[1Ah], ax
        sti

        pop  ds
        pop  bx
        pop  ax
        iret

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
octave      db  0           ; signed octave shift (OCT_MIN...OCT_MAX)
voice_next  db  0           ; next SN76496 tone channel to steal (0,1,2)
voice_sc    db  0, 0, 0     ; scan code occupying voices 0..2 (0 = free)
old_int9    dd  0           ; original INT 09h far pointer (offset, segment)

; kbd[] is written by new_int9: 1 = key down, 0 = up, index = scan & 7Fh.
; prev[] is the previous main-loop snapshot, used only for rising edges.
kbd         db  128 dup (0)
prev        db  128 dup (0)

; note_tab: packed 3-byte records  [db XT_scan_code]  [dw N_counter]
; Terminated by a 00h sentinel byte (scan code 0 is not a real make).
;
; N = round( 3,579,545 / (32 x f_Hz) )  =  round( 111,860.78 / f_Hz )
;
; Indexed by hardware scan code, not ASCII, because INT 09h never gives
; us characters.  XT/PCjr 83-key codes (KEY_INT targets the same set):
;   A=1Eh S=1Fh D=20h F=21h G=22h H=23h J=24h K=25h L=26h
;   W=11h E=12h T=14h Y=15h U=16h
;
; N values match piano2.asm (slightly more accurate than jrpiano.bas).
note_tab:
        ; White keys (C major scale)
        db  1Eh             ; A
        dw  428             ; C4   261.4 Hz  (std 261.63)
        db  1Fh             ; S
        dw  381             ; D4   293.6 Hz  (std 293.66)
        db  20h             ; D
        dw  339             ; E4   330.0 Hz  (std 329.63)
        db  21h             ; F
        dw  320             ; F4   349.6 Hz  (std 349.23)
        db  22h             ; G
        dw  285             ; G4   392.5 Hz  (std 392.00)
        db  23h             ; H
        dw  254             ; A4   440.5 Hz  (std 440.00)
        db  24h             ; J
        dw  227             ; B4   492.9 Hz  (std 493.88)
        db  25h             ; K
        dw  214             ; C5   522.7 Hz  (std 523.25)
        db  26h             ; L
        dw  190             ; D5   588.7 Hz  (std 587.33)
        ; Black keys (sharps)
        db  11h             ; W
        dw  404             ; C#4  276.9 Hz  (std 277.18)
        db  12h             ; E
        dw  360             ; D#4  310.7 Hz  (std 311.13)
        db  14h             ; T
        dw  302             ; F#4  370.5 Hz  (std 369.99)
        db  15h             ; Y
        dw  269             ; G#4  415.8 Hz  (std 415.30)
        db  16h             ; U
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
        db  '  SPACE = silence all     ESC = quit', 0Dh, 0Ah
        db  '  Hold up to 3 keys for chords', 0Dh, 0Ah
        db  '$'

CODE    ENDS
        END    start
