; stars.asm — static + twinkle starfield background
;
; Stars are single pixels. They are drawn once on the live screen at startup, and
; "stamped" into the shadow band every frame during each phase's render so the
; letters compositing on top don't permanently erase them. A few stars are toggled
; per frame for a twinkle. The scrolling rainbow attributes recolour them for free.

NSTARS         EQU 80
TWINKLE_COUNT  EQU 2      ; stars toggled per frame
TWINKLE_STRIDE EQU 7      ; index step between toggles (spreads them out)

star_seed:   DEFW 0xACE1
twinkle_idx: DEFB 0
star_data:   DEFS NSTARS*3   ; per star: x, y, on(1/0)

; ─────────────────────────────────────────────────────────────────────────────
; rnd8 — 16-bit LCG (seed = seed*5 + odd const, full 65536 period). A = scrambled
; byte. Preserves IX; clobbers HL, DE, A, F.
; ─────────────────────────────────────────────────────────────────────────────
rnd8:
    ld   hl, (star_seed)
    ld   d, h
    ld   e, l
    add  hl, hl          ; *2
    add  hl, hl          ; *4
    add  hl, de          ; *5
    ld   de, 0x3B19      ; odd increment
    add  hl, de
    ld   (star_seed), hl
    ld   a, h
    xor  l
    ret

; ─────────────────────────────────────────────────────────────────────────────
; init_starfield — scatter NSTARS stars, mark on, plot on the live screen.
; Call once at startup.
; ─────────────────────────────────────────────────────────────────────────────
init_starfield:
    xor  a
    ld   (scr_or), a
    ld   (sprite_mode), a
    ld   ix, star_data
    ld   b, NSTARS
isf_loop:
    push bc
    call rnd8
    ld   (ix+0), a       ; x = 0..255
isf_y:
    call rnd8
    cp   192
    jr   c, isf_y_ok
    sub  64              ; fold 192..255 down into 128..191
isf_y_ok:
    ld   (ix+1), a       ; y = 0..191
    ld   a, 1
    ld   (ix+2), a       ; on
    ld   d, (ix+0)
    ld   e, (ix+1)
    call plot_pixel      ; OR pixel onto live screen (scr_or = 0)
    inc  ix
    inc  ix
    inc  ix
    pop  bc
    djnz isf_loop
    ret

; ─────────────────────────────────────────────────────────────────────────────
; stamp_stars — OR every "on" star into the current target. scr_or selects screen
; vs shadow, so calling this with scr_or = 0x80 (mid-render) puts the stars under
; the letters in the shadow band.
; ─────────────────────────────────────────────────────────────────────────────
stamp_stars:
    ld   ix, star_data
    ld   b, NSTARS
ss_loop:
    ld   a, (ix+2)
    or   a
    jr   z, ss_next
    ld   d, (ix+0)
    ld   e, (ix+1)
    push bc
    call plot_pixel
    pop  bc
ss_next:
    inc  ix
    inc  ix
    inc  ix
    djnz ss_loop
    ret

; ─────────────────────────────────────────────────────────────────────────────
; twinkle_step — toggle TWINKLE_COUNT stars (rotating index) and reflect each
; change on the live screen. Runs in main_loop before the phase render, so the
; updated on/off state is what stamp_stars uses this frame.
; ─────────────────────────────────────────────────────────────────────────────
twinkle_step:
    xor  a
    ld   (scr_or), a     ; live screen
    ld   a, (twinkle_idx)
    ld   c, a            ; C = current index
    ld   b, TWINKLE_COUNT
tw_loop:
    ld   a, c            ; HL = star_data + C*3
    ld   l, a
    ld   h, 0
    ld   d, h
    ld   e, l
    add  hl, hl
    add  hl, de          ; HL = C*3
    ld   de, star_data
    add  hl, de
    push hl
    pop  ix              ; IX = &star[C]
    ld   a, (ix+2)
    xor  1               ; toggle on/off
    ld   (ix+2), a
    ld   d, (ix+0)
    ld   e, (ix+1)
    or   a               ; Z set if now off
    push bc
    jr   z, tw_off
    call plot_pixel      ; now on  -> set pixel
    jr   tw_after
tw_off:
    call clr_pixel_screen ; now off -> clear pixel
tw_after:
    pop  bc
    ld   a, c            ; advance index by stride (mod NSTARS)
    add  a, TWINKLE_STRIDE
    cp   NSTARS
    jr   c, tw_idx_ok
    sub  NSTARS
tw_idx_ok:
    ld   c, a
    djnz tw_loop
    ld   a, c
    ld   (twinkle_idx), a
    ret

; ─────────────────────────────────────────────────────────────────────────────
; clr_pixel_screen — clear one pixel on the LIVE screen. In: D=x, E=y.
; ─────────────────────────────────────────────────────────────────────────────
clr_pixel_screen:
    ld   a, e
    cp   192
    ret  nc
    ld   h, 0
    ld   l, e
    add  hl, hl
    ld   bc, row_addr
    add  hl, bc
    ld   c, (hl)
    inc  hl
    ld   b, (hl)
    ld   h, b
    ld   l, c
    ld   a, d
    srl  a
    srl  a
    srl  a
    add  a, l
    ld   l, a
    jr   nc, cps_nc1
    inc  h
cps_nc1:
    ld   a, d
    and  7
    ld   bc, bit_tab
    add  a, c
    ld   c, a
    jr   nc, cps_nc2
    inc  b
cps_nc2:
    ld   a, (bc)
    cpl
    and  (hl)
    ld   (hl), a
    ret
