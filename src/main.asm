; RetCon 2026 — ZX Spectrum 48K Demo
; Stage 5+: scroll (Part 1) + spin (Part 2)

        ORG     0x8000

anim_frame:   DEFB 0
phase:        DEFB 0   ; 0=scroll, 1=spin, 2=orbit

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

        ; Pre-render all 19 letter sprites (one-time startup cost)
        call    pre_render_all_sprites

        xor     a
        ld      (anim_frame), a

main_loop:
        halt
        ld      a, (phase)
        or      a
        jp      z, do_scroll
        cp      1
        jp      z, do_spin
        jp      do_orbit

do_scroll:
        call    clear_bands
        call    lookup_scroll_y
        call    blit_all_animated
        ld      a, (anim_frame)
        cp      69
        jr      z, scroll_done
        inc     a
        ld      (anim_frame), a
        jr      main_loop
scroll_done:
        xor     a
        ld      (anim_frame), a
        ld      a, 1
        ld      (phase), a
        jr      main_loop

do_spin:
        call    clear_bands
        call    draw_spin_frame
        ld      a, (anim_frame)
        cp      99
        jr      z, spin_done
        inc     a
        ld      (anim_frame), a
        jr      main_loop
spin_done:
        xor     a
        ld      (anim_frame), a
        ld      a, 2
        ld      (phase), a
        jr      main_loop

do_orbit:
        call    clear_orbit_bands
        call    draw_orbit_frame
        ld      a, (anim_frame)
        cp      149
        jr      z, orbit_done
        inc     a
        ld      (anim_frame), a
        jr      main_loop
orbit_done:
        xor     a
        ld      (anim_frame), a     ; reset frame counter
        ld      (phase), a          ; phase = 0 (scroll)
        ld      (orb_base_angle), a ; reset orbit angle for next loop
        call    clear_orbit_bands   ; wipe orbit pixels before scroll starts
        jr      main_loop

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
