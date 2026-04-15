; ============================================================
;  piano2.ASM  --  PCjr Keyboard Piano
; ============================================================
;  Assemble on a modern machine, then transfer the .COM file:
;    nasm -f bin -o PIANO.COM PIANO.ASM
;
;  Or use MASM 2.0+ directly on the PCjr (see notes below)
;
;  Key layout:
;    [ W ][ E ]         [ T ][ Y ][ U ]    <- sharps
;   [ A ][ S ][ D ][ F ][ G ][ H ][ J ][ K ][ L ]
;     C4   D4   E4   F4   G4   A4   B4   C5   D5
;
;  Notes sustain until the next note key or SPACE is pressed.
;  SPACE = silence    Z / X = octave down / up    ESC = quit
;
;  Sound: TI SN76496 at I/O port 0xC0  (PCjr hardware direct)
; ============================================================

        CPU     8086
        ORG     100h

SPORT   EQU     0C0h        ; SN76496 data port on PCjr

; ============================================================
;  PROGRAM START
; ============================================================
start:
        ; Set 80x25 color text mode -- also clears screen
        mov     ax, 0003h
        int     10h

        ; Print keyboard map
        mov     ah, 09h
        mov     dx, msg_banner
        int     21h

        ; Set channel 0 to maximum volume.
        ; SN76496 latch byte:  1 RR T AAAA
        ;   1    = this is a latch/command byte
        ;   RR   = 00  (channel 0)
        ;   T    = 1   (attenuation register)
        ;   AAAA = 0000 (attenuation 0 = loudest)
        ;   => 0x90
        mov     al, 090h
        out     SPORT, al

        mov     byte [oct], 0

; ============================================================
;  MAIN LOOP
; ============================================================
key_loop:
        mov     ah, 000h        ; BIOS: block until keypress
        int     16h             ; AL = ASCII, AH = scan code

        cmp     al, 01Bh        ; ESC?
        je      do_exit

        cmp     al, ' '         ; Space = silence?
        je      do_silence

        ; Force uppercase for all remaining comparisons
        and     al, 0DFh

        cmp     al, 'Z'
        je      do_oct_dn
        cmp     al, 'X'
        je      do_oct_up

        ; Look up note in table
        call    lookup          ; -> BX = SN76496 divisor, 0 if not a note key
        or      bx, bx
        jz      key_loop        ; unknown key: leave current note ringing

        ; Apply octave shift.
        ; Octave UP   halves  the divisor (higher frequency).
        ; Octave DOWN doubles the divisor (lower  frequency).
        mov     cl, [oct]
        cmp     cl, 0
        je      do_play
        jg      oct_higher

oct_lower:
        neg     cl
        shl     bx, cl
        cmp     bx, 1023        ; SN76496 divisor is 10 bits max
        jbe     do_play
        mov     bx, 1023
        jmp     do_play

oct_higher:
        shr     bx, cl
        cmp     bx, 14          ; floor keeps us below ultrasonic range
        jae     do_play
        mov     bx, 14

; ============================================================
;  PLAY NOTE: write divisor in BX to SN76496 channel 0
;
;  The chip takes two bytes:
;    Latch: 1_00_0_LLLL  (ch 0, frequency, divisor bits 3:0)
;    Data:  0_0_HHHHHH   (divisor bits 9:4)
; ============================================================
do_play:
        mov     al, bl
        and     al, 00Fh        ; lower nibble of divisor
        or      al, 080h        ; latch bit + channel 0 + frequency type
        out     SPORT, al

        mov     ax, bx
        mov     cl, 4
        shr     ax, cl          ; shift divisor right 4 -> upper bits in AL
        and     al, 03Fh        ; keep 6 bits for data byte
        out     SPORT, al

        jmp     key_loop        ; note sustains; loop for next keypress

; ============================================================
;  HANDLERS
; ============================================================
do_silence:
        ; Volume latch, attenuation = 15 (silent): 1_00_1_1111 = 0x9F
        mov     al, 09Fh
        out     SPORT, al
        jmp     key_loop

do_oct_dn:
        cmp     byte [oct], -3
        jle     key_loop
        dec     byte [oct]
        call    show_oct
        jmp     key_loop

do_oct_up:
        cmp     byte [oct], 3
        jge     key_loop
        inc     byte [oct]
        call    show_oct
        jmp     key_loop

do_exit:
        mov     al, 09Fh        ; silence chip before returning to DOS
        out     SPORT, al
        mov     ax, 4C00h
        int     21h

; ============================================================
;  SUBROUTINE: lookup
;    In:  AL = uppercase key character
;    Out: BX = 10-bit SN76496 divisor, or 0 if not a note key
;    Destroys: AX, SI
; ============================================================
lookup:
        push    si
        mov     bl, al          ; stash key char in BL
        mov     si, note_tab
.scan:
        mov     al, [si]
        cmp     al, 0           ; end-of-table sentinel?
        je      .miss
        cmp     bl, al
        je      .hit
        add     si, 3           ; stride: 1 byte key + 2 bytes divisor
        jmp     .scan
.hit:
        mov     bx, [si+1]      ; load 16-bit divisor (little-endian)
        pop     si
        ret
.miss:
        xor     bx, bx
        pop     si
        ret

; ============================================================
;  SUBROUTINE: show_oct
;    Overwrites the octave indicator on row 7, col 10
;    (the "+0" immediately after "  Octave: " in the banner)
; ============================================================
show_oct:
        mov     ah, 02h
        xor     bh, bh
        mov     dh, 7
        mov     dl, 10
        int     10h             ; set cursor position

        mov     al, [oct]
        cmp     al, 0
        jl      .neg
        push    ax
        mov     al, '+'
        call    tty
        pop     ax
        jmp     .digit
.neg:
        push    ax
        mov     al, '-'
        call    tty
        pop     ax
        neg     al
.digit:
        add     al, '0'
        call    tty
        mov     al, ' '         ; erase any leftover character
        call    tty
        ret

; ------ tty: print AL to screen via BIOS teletype ------
tty:
        mov     ah, 0Eh
        xor     bh, bh
        mov     bl, 07h
        int     10h
        ret

; ============================================================
;  DATA
; ============================================================
oct     db  0

; Note table: key (1 byte, uppercase), divisor (2 bytes, little-endian)
; Formula: N = round( 3,579,545 / (32 * Hz) )
; Sharps (W E T Y U) and naturals (A S D F G H J K L) use
; different letters entirely, so upper-casing all keys is safe.
note_tab:
        db  'A', 172, 1     ;  428  -> C4   261.4 Hz
        db  'W', 148, 1     ;  404  -> C#4  276.9 Hz
        db  'S', 125, 1     ;  381  -> D4   293.6 Hz
        db  'E', 104, 1     ;  360  -> D#4  310.7 Hz
        db  'D',  83, 1     ;  339  -> E4   330.0 Hz
        db  'F',  64, 1     ;  320  -> F4   349.6 Hz
        db  'T',  46, 1     ;  302  -> F#4  370.5 Hz
        db  'G',  29, 1     ;  285  -> G4   392.5 Hz
        db  'Y',  13, 1     ;  269  -> G#4  415.8 Hz
        db  'H', 254,  0    ;  254  -> A4   440.5 Hz
        db  'U', 240,  0    ;  240  -> A#4  466.4 Hz
        db  'J', 227,  0    ;  227  -> B4   492.9 Hz
        db  'K', 214,  0    ;  214  -> C5   522.7 Hz
        db  'L', 190,  0    ;  190  -> D5   588.7 Hz
        db  0               ; end sentinel

msg_banner:
        db  '  PCjr Keyboard Piano (Assembly)', 0Dh, 0Ah
        db  '  =================================', 0Dh, 0Ah
        db  0Dh, 0Ah
        db  '   [W][E]      [T][Y][U]   <- sharps', 0Dh, 0Ah
        db  '  [A][S][D][F][G][H][J][K][L]', 0Dh, 0Ah
        db  '   C  D  E  F  G  A  B  c  d', 0Dh, 0Ah
        db  0Dh, 0Ah
        db  '  Octave: +0   (Z / X to shift)', 0Dh, 0Ah
        db  '  SPACE = silence     ESC = quit', 0Dh, 0Ah
        db  '$'