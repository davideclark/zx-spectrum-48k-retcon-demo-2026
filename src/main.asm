; RetCon 2026 — ZX Spectrum 48K Demo
; Stage 5+: scroll (Part 1) + spin (Part 2)

        ORG     0x8000

; Spin angular speed. spin_acc is an 8.8 fixed-point index into spin_ang; the
; integer (high) byte selects the frame. SPIN_STEP is how far the angle advances
; per displayed frame: 256 = 1.0x (original), 384 = 1.5x, 512 = 2.0x. Tune here.
SPIN_STEP     EQU 512

; Orbit speed. orb_acc is an 8.8 fixed-point frame index (0..149); the integer
; (high) byte feeds orb_scale (radius) and, doubled, orb_base_angle. ORB_STEP is
; frames advanced per displayed frame: 256 = 1.0x, 512 = 2.0x, 768 = 3.0x. The
; band margin (3 rows) supports up to ~3.0x; go higher only with a wider margin.
ORB_STEP      EQU 640

anim_frame:   DEFB 0
phase:        DEFB 0   ; 0=scroll, 1=spin, 2=orbit
spin_acc:     DEFW 0   ; 8.8 fixed-point position within spin_ang (spin phase)
orb_acc:      DEFW 0   ; 8.8 fixed-point frame index for the orbit phase

start:
        ld      sp, 0xFF00

        ; Border black
        xor     a
        out     (0xFE), a

        ; Attributes: BRIGHT=1, PAPER=0, INK=7 (white on black)
        ld      hl, 0x5800
        ld      de, 0x5801
        ld      bc, 0x02FF
        ld      (hl), 0x47
        ldir

        ; Clear the visible screen pixels (0x4000) and the shadow buffer (0xC000).
        ; Scroll/spin render into the shadow then copy bands to the screen, so both
        ; must start blank to avoid showing load garbage outside the copied rows.
        ld      hl, 0x4000
        ld      de, 0x4001
        ld      bc, 6143
        ld      (hl), 0
        ldir
        ld      hl, 0xC000
        ld      de, 0xC001
        ld      bc, 6143
        ld      (hl), 0
        ldir

        ; Build the shadow row-address table used by plot_screen_fast.
        call    build_shadow_row_table

        ; Pre-render all 19 letter sprites (one-time startup cost)
        call    pre_render_all_sprites

        xor     a
        ld      (anim_frame), a

main_loop:
        halt
        call    draw_rainbow        ; scroll the colour bands (attribute RAM only)
        ld      a, (phase)
        or      a
        jp      z, do_scroll
        cp      1
        jp      z, do_spin
        jp      do_orbit

do_scroll:
        call    lookup_scroll_y
        ld      a, 0x80             ; render into shadow buffer (off-screen)
        ld      (scr_or), a
        call    scroll_clear_blit
        xor     a                   ; back to screen addressing for the copy
        ld      (scr_or), a
        call    copy_scroll_bands   ; shadow -> screen (only write the ULA sees)
        ld      a, (anim_frame)
        cp      69
        jr      z, scroll_done
        inc     a
        ld      (anim_frame), a
        jp      main_loop
scroll_done:
        xor     a
        ld      (anim_frame), a
        ld      h, a                ; spin_acc = 0 (start of rotation)
        ld      l, a
        ld      (spin_acc), hl
        ld      a, 1
        ld      (phase), a
        jp      main_loop

do_spin:
        ld      a, 0x80             ; render into shadow buffer (off-screen)
        ld      (scr_or), a
        call    clear_bands
        call    draw_spin_frame
        xor     a                   ; back to screen addressing
        ld      (scr_or), a
        call    copy_spin_bands     ; shadow -> screen
        ; Advance the rotation by SPIN_STEP (8.8 fixed point); frame = high byte.
        ld      hl, (spin_acc)
        ld      de, SPIN_STEP
        add     hl, de
        ld      (spin_acc), hl
        ld      a, h                ; integer part = new spin_ang index
        cp      100                 ; spin_ang has 100 entries (0..99)
        jr      nc, spin_done
        ld      (anim_frame), a
        jp      main_loop
spin_done:
        xor     a
        ld      (anim_frame), a
        ld      a, 2
        ld      (phase), a
        ld      hl, 0               ; orb_acc = 0 (start of orbit)
        ld      (orb_acc), hl
        ; No clear needed: draw_orbit_frame clears the shadow band every frame, and
        ; the first orbit copy overwrites the spin letters on screen.
        jp      main_loop

do_orbit:
        ld      a, 0x80             ; render orbit frame into shadow (off-screen)
        ld      (scr_or), a
        call    draw_orbit_frame
        xor     a                   ; back to screen addressing
        ld      (scr_or), a
        call    copy_orbit_bands    ; shadow -> screen (only write the ULA sees)
        ; Advance the orbit by ORB_STEP (8.8 fixed point); frame index = high byte.
        ld      hl, (orb_acc)
        ld      de, ORB_STEP
        add     hl, de
        ld      (orb_acc), hl
        ld      a, h                ; integer part = new orbit frame index
        cp      150                 ; orb_scale has 150 entries (0..149)
        jr      nc, orbit_done
        ld      (anim_frame), a
        jp      main_loop
orbit_done:
        xor     a
        ld      (anim_frame), a     ; reset frame counter
        ld      (phase), a          ; phase = 0 (scroll)
        ld      hl, 0               ; orb_acc = 0 for next loop
        ld      (orb_acc), hl
        call    clear_orbit_bands   ; wipe orbit pixels before scroll starts
        jp      main_loop

lookup_scroll_y:
        ld      a, (anim_frame)
        ld      l, a
        ld      h, 0
        ld      de, scroll_y1
        push    hl
        add     hl, de
        ld      a, (hl)
        ld      (anim_cy1), a
        pop     hl
        ld      de, scroll_y2
        add     hl, de
        ld      a, (hl)
        ld      (anim_cy2), a
        ret

        INCLUDE "src/render.asm"
        INCLUDE "src/font.asm"
        INCLUDE "src/tables.asm"

        END     start
