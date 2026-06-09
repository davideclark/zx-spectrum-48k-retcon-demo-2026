; render.asm — pixel plotting, Bresenham, letter rendering, sprite blitting

; ── Sprite context (set before each pre-render call) ─────────────────────────
sprite_mode:    DEFB 0   ; 0=screen, 1=sprite buffer
spr_base:       DEFW 0   ; base address of current sprite buffer
spr_top_y:      DEFB 0   ; screen Y of sprite row 0  (= cy_rest - 20)
spr_left_x:     DEFB 0   ; screen X of sprite col 0  (= blit_byte * 8)

; ── Working buffers / Bresenham state ────────────────────────────────────────
letter_pts:   DEFS 14
bres_x2:      DEFB 0
bres_y2:      DEFB 0
bres_dx:      DEFB 0
bres_dy:      DEFB 0
bres_sx:      DEFB 0
bres_sy:      DEFB 0
bres_err:     DEFB 0

; ── Shared pointer state for draw_all_* routines ─────────────────────────────
dar_shapes:   DEFW 0
dar_pos:      DEFW 0

; ── Animated Y centres ───────────────────────────────────────────────────────
anim_cy1:     DEFB 0
anim_cy2:     DEFB 0

; ── Render target select ─────────────────────────────────────────────────────
; OR'd into the high byte of every computed screen address. 0x00 = live screen
; (0x40xx), 0x80 = shadow buffer (0xC0xx). Scroll/spin render with 0x80 then the
; copy routines move the result to the live screen; orbit leaves it 0x00.
scr_or:       DEFB 0

; ── Sprite storage: 19 × 40 rows × 4 bytes = 3040 bytes ─────────────────────
letter_sprites: DEFS 3040

; ── Shadow row-address table: row_addr with bit 15 set (points into 0xC0xx). ──
; Built once at startup (build_shadow_row_table) so plot_screen_fast needs no
; per-pixel OR to redirect into the shadow buffer.
row_addr_shadow: DEFS 384   ; 192 entries × 2 bytes

; ── Blit working vars ─────────────────────────────────────────────────────────
bos_screen_y:   DEFB 0
bos_blit_col:   DEFB 0

; ── Spin / rotation working vars ─────────────────────────────────────────────
spin_sin:       DEFB 0   ; sin_tab[angle] for current spin frame
spin_cos:       DEFB 0   ; sin_tab[(angle+64)&255] for current spin frame
spin_cx:        DEFB 0   ; cx of current letter (from rest_pos or orbit pos)
spin_cy:        DEFB 0   ; cy of current letter
rot_dx:         DEFB 0   ; raw dx offset (signed) from letter_shapes
rot_dy:         DEFB 0   ; raw dy offset (signed) from letter_shapes
rot_new_dx:     DEFB 0   ; rotated dx result
rot_new_dy:     DEFB 0   ; rotated dy result
drl_shape_ptr:  DEFW 0   ; temp save of HL (shape ptr) across rotate_point call
cos_prod:       DEFS 35  ; (d*spin_cos)>>7 for d=-17..17, index=d+17
sin_prod:       DEFS 35  ; (d*spin_sin)>>7 for d=-17..17, index=d+17

; ── Orbit working vars ───────────────────────────────────────────────────────
orb_base_angle: DEFB 0   ; increments each orbit frame; shared across all 19 letters
orb_radius:     DEFB 0   ; orb_scale[frame] (0..26)
orb_bstart:     DEFB 0   ; dynamic orbit band: first row  (= 34 - radius)
orb_bcount:     DEFB 0   ; dynamic orbit band: row count   (= 109 + 2*radius)
orb_rest_cx:    DEFB 0
orb_rest_cy:    DEFB 0
orb_sin:        DEFB 0   ; sin_tab[orbit_angle] for current letter
orb_cos:        DEFB 0   ; cos for current letter orbit angle
orb_phase_ptr:  DEFW 0   ; walks through orb_phase table (19 bytes)
orb_blt_spr:        DEFW 0   ; sprite ptr for current letter (letter_sprites + L*160)
ocb_prev_col:       DEFB 0   ; current letter's prev blit col (0xFF = off-screen)
ocb_prev_sy:        DEFB 0   ; current letter's prev start screen y
ocb_new_col:        DEFB 0   ; current letter's new blit col (0xFF = off-screen)
ocb_new_sy:         DEFB 0   ; current letter's new start screen y
orb_prev_col_ptr:   DEFW 0   ; walks orb_prev_col array
orb_prev_sy_ptr:    DEFW 0   ; walks orb_prev_sy array
orb_prev_col:       DEFS 19  ; per-letter prev blit col (0xFF = off-screen/skip)
orb_prev_sy:        DEFS 19  ; per-letter prev start screen y (0xFF = off-screen/skip)

; ─────────────────────────────────────────────────────────────────────────────
; plot_pixel — screen OR sprite depending on sprite_mode
; In: D=x, E=y
; ─────────────────────────────────────────────────────────────────────────────
plot_pixel:
    ld   a, (sprite_mode)
    or   a
    jr   nz, plot_sprite_pixel

    ; ── Screen path ──────────────────────────────────────────────────────────
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

    ld   a, d
    srl  a
    srl  a
    srl  a
    add  a, c
    ld   c, a
    jr   nc, pp_nc
    inc  b
pp_nc:
    ld   h, b
    ld   l, c
    ld   a, (scr_or)    ; redirect to shadow buffer when scr_or = 0x80
    or   h
    ld   h, a

    ld   a, d
    and  7
    ld   bc, bit_tab
    add  a, c
    ld   c, a
    jr   nc, pp_nc2
    inc  b
pp_nc2:
    ld   a, (bc)
    or   (hl)
    ld   (hl), a
    ret

; ── Sprite path ───────────────────────────────────────────────────────────────
; In: D=x, E=y  (same calling convention as screen path above)
plot_sprite_pixel:
    ; row = y - spr_top_y  (must be 0..39)
    ld   a, e
    ld   b, a
    ld   a, (spr_top_y)
    ld   c, a
    ld   a, b
    sub  c              ; A = row
    jp   m, psp_done
    cp   40
    jr   nc, psp_done
    ld   c, a           ; C = row (0-39)

    ; col = x - spr_left_x  (must be 0..31)
    ld   a, d
    ld   b, a
    ld   a, (spr_left_x)
    ld   h, a
    ld   a, b
    sub  h              ; A = col
    jp   m, psp_done
    cp   32
    jr   nc, psp_done
    ld   b, a           ; B = col (0-31)

    ; sprite byte address = spr_base + row*4 + col/8
    ; Use HL only — avoids LD DE,(nn) which PASMO may not support
    ld   a, c
    add  a, a
    add  a, a           ; A = row * 4
    ld   hl, (spr_base) ; HL = spr_base
    add  a, l
    ld   l, a
    jr   nc, psp_nc1
    inc  h
psp_nc1:
    ld   a, b
    srl  a
    srl  a
    srl  a              ; A = col / 8  (0-3)
    add  a, l
    ld   l, a
    jr   nc, psp_nc2
    inc  h
psp_nc2:
    ; HL = sprite byte address

    ; bitmask = 0x80 >> (col & 7)
    ld   a, b
    and  7
    jr   z, psp_no_shift
    ld   b, a
    ld   a, 0x80
psp_shift:
    rrca
    djnz psp_shift
    jr   psp_write
psp_no_shift:
    ld   a, 0x80
psp_write:
    or   (hl)
    ld   (hl), a
psp_done:
    ret

; ─────────────────────────────────────────────────────────────────────────────
; plot_screen_fast — OR one pixel directly into the SHADOW buffer.
; Spin's hot-loop plotter, reached via the self-modified call in draw_line.
; Drops two per-pixel costs of plot_pixel: the sprite-mode branch (only needed by
; the one-time pre-render) and the scr_or redirect (folded into row_addr_shadow,
; whose entries are already row_addr | 0x8000). Preserves D,E (current point).
; In: D=x, E=y.
; ─────────────────────────────────────────────────────────────────────────────
plot_screen_fast:
    ld   a, e
    cp   192
    ret  nc
    ld   h, 0
    ld   l, e
    add  hl, hl
    ld   bc, row_addr_shadow
    add  hl, bc
    ld   c, (hl)
    inc  hl
    ld   b, (hl)         ; BC = shadow row base address
    ld   a, d
    srl  a
    srl  a
    srl  a               ; A = x / 8
    add  a, c
    ld   c, a
    jr   nc, psf_nc
    inc  b
psf_nc:
    ld   h, b
    ld   l, c            ; HL = shadow byte address
    ld   a, d
    and  7
    ld   bc, bit_tab
    add  a, c
    ld   c, a
    jr   nc, psf_nc2
    inc  b
psf_nc2:
    ld   a, (bc)
    or   (hl)
    ld   (hl), a
    ret

; ─────────────────────────────────────────────────────────────────────────────
; draw_line  — Bresenham
; In: D=x1, E=y1, B=x2, C=y2
; ─────────────────────────────────────────────────────────────────────────────
draw_line:
    ld   a, b
    ld   (bres_x2), a
    ld   a, c
    ld   (bres_y2), a

    ld   a, b
    sub  d
    jp   p, dl_sx_pos
    neg
    ld   (bres_dx), a
    ld   a, 0xFF
    ld   (bres_sx), a
    jr   dl_sx_done
dl_sx_pos:
    ld   (bres_dx), a
    ld   a, 1
    ld   (bres_sx), a
dl_sx_done:

    ld   a, (bres_y2)
    sub  e
    jp   p, dl_sy_pos
    neg
    ld   (bres_dy), a
    ld   a, 0xFF
    ld   (bres_sy), a
    jr   dl_sy_done
dl_sy_pos:
    ld   (bres_dy), a
    ld   a, 1
    ld   (bres_sy), a
dl_sy_done:

    ld   a, (bres_dx)
    ld   b, a
    ld   a, (bres_dy)
    ld   c, a
    ld   a, b
    sub  c
    ld   (bres_err), a

dl_loop:
dl_plot_call:
    call plot_pixel        ; operand (dl_plot_call+1) is self-modified: set to
                           ; plot_sprite_pixel for pre-render, plot_screen_fast
                           ; for spin. Avoids a per-pixel sprite-mode branch.

    ld   a, (bres_x2)
    cp   d
    jr   nz, dl_cont
    ld   a, (bres_y2)
    cp   e
    ret  z

dl_cont:
    ld   a, (bres_err)
    add  a, a
    ld   b, a

    ld   a, (bres_dy)
    add  a, b
    jp   m, dl_skip_x
    ld   a, (bres_err)
    ld   c, a
    ld   a, (bres_dy)
    ld   h, a
    ld   a, c
    sub  h
    ld   (bres_err), a
    ld   a, (bres_sx)
    add  a, d
    ld   d, a
dl_skip_x:

    ld   a, (bres_dx)
    sub  b
    jp   m, dl_skip_y
    ld   a, (bres_err)
    ld   c, a
    ld   a, (bres_dx)
    add  a, c
    ld   (bres_err), a
    ld   a, (bres_sy)
    add  a, e
    ld   e, a
dl_skip_y:

    jr   dl_loop

; ─────────────────────────────────────────────────────────────────────────────
; draw_line_fast — Bresenham into the SHADOW buffer with INCREMENTAL addressing.
; Spin-only line drawer. Instead of recomputing the screen address per pixel, it
; maintains HL = current shadow byte pointer and dlf_mask = current bit mask, and
; updates them as the line walks: an X step rotates the mask (advancing the byte
; on wrap); a Y step uses dlf_down_hl / dlf_up_hl (the standard Spectrum
; next-line arithmetic). D=x, E=y are still tracked only for the endpoint test.
; In: D=x1, E=y1, B=x2, C=y2.  Letters stay on-screen (y 39..138, x<256), so no
; per-pixel bounds checks are needed.
; ─────────────────────────────────────────────────────────────────────────────
dlf_x2:    DEFB 0
dlf_y2:    DEFB 0
dlf_dx:    DEFB 0
dlf_dy:    DEFB 0
dlf_err:   DEFB 0       ; signed 8-bit (|dx|,|dy| <= ~40 keeps it in range)
dlf_xleft: DEFB 0       ; 1 = x decreasing (mask rotates left)
dlf_yup:   DEFB 0       ; 1 = y decreasing (use dlf_up_hl)
dlf_mask:  DEFB 0       ; current pixel bit mask (0x80 >> (x&7))

draw_line_fast:
    ld   a, b
    ld   (dlf_x2), a
    ld   a, c
    ld   (dlf_y2), a

    ; dx = |x2-x1|, x direction
    ld   a, b
    sub  d
    jr   nc, dlf_dxpos
    neg
    ld   (dlf_dx), a
    ld   a, 1
    ld   (dlf_xleft), a
    jr   dlf_dxdone
dlf_dxpos:
    ld   (dlf_dx), a
    xor  a
    ld   (dlf_xleft), a
dlf_dxdone:

    ; dy = |y2-y1|, y direction
    ld   a, c
    sub  e
    jr   nc, dlf_dypos
    neg
    ld   (dlf_dy), a
    ld   a, 1
    ld   (dlf_yup), a
    jr   dlf_dydone
dlf_dypos:
    ld   (dlf_dy), a
    xor  a
    ld   (dlf_yup), a
dlf_dydone:

    ; err = dx - dy
    ld   a, (dlf_dx)
    ld   c, a
    ld   a, (dlf_dy)
    ld   b, a
    ld   a, c
    sub  b
    ld   (dlf_err), a

    ; HL = shadow byte address of (x1,y1); dlf_mask = 0x80 >> (x1&7)
    ld   a, e
    ld   l, a
    ld   h, 0
    add  hl, hl
    ld   bc, row_addr_shadow
    add  hl, bc
    ld   a, (hl)
    inc  hl
    ld   h, (hl)
    ld   l, a               ; HL = shadow row base
    ld   a, d
    srl  a
    srl  a
    srl  a                  ; A = x1 / 8
    add  a, l
    ld   l, a
    jr   nc, dlf_p0
    inc  h
dlf_p0:
    push hl                 ; save byte ptr while we look up the mask
    ld   a, d
    and  7
    ld   hl, bit_tab
    add  a, l
    ld   l, a
    jr   nc, dlf_m0
    inc  h
dlf_m0:
    ld   a, (hl)
    ld   (dlf_mask), a
    pop  hl                 ; HL = shadow byte ptr

dlf_loop:
    ld   a, (dlf_mask)
    or   (hl)
    ld   (hl), a            ; plot

    ld   a, (dlf_x2)
    cp   d
    jr   nz, dlf_cont
    ld   a, (dlf_y2)
    cp   e
    ret  z

dlf_cont:
    ld   a, (dlf_err)
    add  a, a
    ld   b, a               ; B = 2*err (kept across both tests)

    ; X step?  (dy + e2) >= 0
    ld   a, (dlf_dy)
    add  a, b
    jp   m, dlf_skipx
    ld   a, (dlf_dy)        ; err -= dy
    ld   c, a
    ld   a, (dlf_err)
    sub  c
    ld   (dlf_err), a
    ld   a, (dlf_xleft)
    or   a
    jr   nz, dlf_xleftstep
    inc  d                  ; x += 1, mask >>= 1
    ld   a, (dlf_mask)
    rrca
    ld   (dlf_mask), a
    jr   nc, dlf_skipx
    inc  hl                 ; mask wrapped 0x01->0x80: next byte
    jr   dlf_skipx
dlf_xleftstep:
    dec  d                  ; x -= 1, mask <<= 1
    ld   a, (dlf_mask)
    rlca
    ld   (dlf_mask), a
    jr   nc, dlf_skipx
    dec  hl                 ; mask wrapped 0x80->0x01: prev byte
dlf_skipx:

    ; Y step?  (dx - e2) >= 0   (B still = e2)
    ld   a, (dlf_dx)
    sub  b
    jp   m, dlf_skipy
    ld   a, (dlf_dx)        ; err += dx
    ld   c, a
    ld   a, (dlf_err)
    add  a, c
    ld   (dlf_err), a
    ld   a, (dlf_yup)
    or   a
    jr   nz, dlf_yupstep
    inc  e                  ; y += 1
    call dlf_down_hl
    jr   dlf_skipy
dlf_yupstep:
    dec  e                  ; y -= 1
    call dlf_up_hl
dlf_skipy:
    jp   dlf_loop

; dlf_down_hl — move HL down one pixel line (standard Spectrum next-line).
dlf_down_hl:
    inc  h
    ld   a, h
    and  7
    ret  nz
    ld   a, l
    add  a, 0x20
    ld   l, a
    ret  c
    ld   a, h
    sub  8
    ld   h, a
    ret

; dlf_up_hl — move HL up one pixel line (reverse of dlf_down_hl).
dlf_up_hl:
    ld   a, h
    dec  h
    and  7
    ret  nz
    ld   a, l
    sub  0x20
    ld   l, a
    ret  c
    ld   a, h
    add  a, 8
    ld   h, a
    ret

; ─────────────────────────────────────────────────────────────────────────────
; draw_letter_kernel
; In: D=cx, E=cy; uses/advances dar_shapes
; ─────────────────────────────────────────────────────────────────────────────
draw_letter_kernel:
    ld   hl, (dar_shapes)
    ld   bc, letter_pts
    push de
    ld   a, 7
dlk_pts:
    push af
    push de
    ld   a, (hl)
    inc  hl
    add  a, d
    ld   (bc), a
    inc  bc
    ld   a, (hl)
    inc  hl
    add  a, e
    ld   (bc), a
    inc  bc
    pop  de
    pop  af
    dec  a
    jr   nz, dlk_pts
    pop  de
    ld   (dar_shapes), hl

    ld   hl, letter_pts
    ld   b, 6
dlk_segs:
    push bc
    push hl
    ld   d, (hl)
    inc  hl
    ld   e, (hl)
    inc  hl
    ld   b, (hl)
    inc  hl
    ld   c, (hl)
    call draw_line
    pop  hl
    inc  hl
    inc  hl
    pop  bc
    djnz dlk_segs
    ret

; ─────────────────────────────────────────────────────────────────────────────
; pre_render_all_sprites — render all 19 letters into letter_sprites once
; ─────────────────────────────────────────────────────────────────────────────
pre_render_all_sprites:
    ld   hl, plot_sprite_pixel  ; draw_line plots into sprite buffers here
    ld   (dl_plot_call+1), hl
    ld   hl, letter_shapes
    ld   (dar_shapes), hl
    ld   hl, rest_pos
    ld   (dar_pos), hl
    ld   hl, letter_sprites
    ld   (spr_base), hl
    ld   hl, sprite_blit_byte
    ld   (pras_col_ptr), hl

    ld   a, 1
    ld   (sprite_mode), a

    ld   b, 19
pras_loop:
    push bc

    ; cx, cy from rest_pos
    ld   hl, (dar_pos)
    ld   d, (hl)
    inc  hl
    ld   e, (hl)
    inc  hl
    ld   (dar_pos), hl

    ; spr_top_y = cy - 20
    ld   a, e
    sub  20
    ld   (spr_top_y), a

    ; spr_left_x = blit_byte * 8
    ld   hl, (pras_col_ptr)
    ld   a, (hl)
    inc  hl
    ld   (pras_col_ptr), hl
    add  a, a
    add  a, a
    add  a, a
    ld   (spr_left_x), a

    ; Zero the 160-byte sprite buffer
    ; push/pop DE preserves D=cx, E=cy across the LDIR which needs DE as dst ptr
    push de
    ld   hl, (spr_base)
    ld   d, h
    ld   e, l
    inc  de             ; DE = spr_base + 1
    ld   bc, 159
    ld   (hl), 0
    ldir                ; fill 160 bytes with 0
    pop  de             ; restore D=cx, E=cy

    ; Render letter into sprite buffer via plot_sprite_pixel
    call draw_letter_kernel

    ; Advance spr_base by 160 bytes
    ld   hl, (spr_base)
    ld   de, 160
    add  hl, de
    ld   (spr_base), hl

    pop  bc
    djnz pras_loop

    xor  a
    ld   (sprite_mode), a
    ret

pras_col_ptr: DEFW 0

; ─────────────────────────────────────────────────────────────────────────────
; blit_all_animated — OR-blit all 19 sprites at animated Y positions
; All persistent state lives in memory vars; no push/pop DE confusion.
; ─────────────────────────────────────────────────────────────────────────────
; ── Stripe-blit working vars ─────────────────────────────────────────────────
sba_y1:   DEFB 0   ; screen_y for line1 at current outer row
sba_y2:   DEFB 0   ; screen_y for line2 at current outer row
sba_scr1: DEFW 0   ; row_addr[sba_y1], 0 if off-screen
sba_scr2: DEFW 0   ; row_addr[sba_y2], 0 if off-screen
sba_colp: DEFW 0   ; walks sprite_blit_byte (reset each outer row)
sba_spr:  DEFW 0   ; sprite row ptr: letter_sprites + outer_row*4

; ─────────────────────────────────────────────────────────────────────────────
; blit_all_animated — row-major (stripe) OR-blit of all 19 sprites.
; Outer: 40 rows. Inner: 9 line1 letters, then 10 line2 letters.
; row_addr looked up once per row per line (80 total vs 760); flicker changes
; from "letters appearing left-to-right" to a top-down horizontal scan wipe.
; ─────────────────────────────────────────────────────────────────────────────
blit_all_animated:
    ld   a, (anim_cy1)
    sub  20
    ld   (sba_y1), a
    ld   a, (anim_cy2)
    sub  20
    ld   (sba_y2), a
    ld   hl, letter_sprites
    ld   (sba_spr), hl

    ld   b, 40
baa_outer:
    push bc

    ; Row address for line1
    ld   a, (sba_y1)
    cp   192
    jr   nc, baa_l1_row_off
    ld   l, a
    ld   h, 0
    add  hl, hl
    ld   bc, row_addr
    add  hl, bc
    ld   c, (hl)
    inc  hl
    ld   b, (hl)
    ld   h, b
    ld   l, c
    ld   (sba_scr1), hl
    jr   baa_l1_row_done
baa_l1_row_off:
    ld   hl, 0
    ld   (sba_scr1), hl
baa_l1_row_done:

    ; Row address for line2
    ld   a, (sba_y2)
    cp   192
    jr   nc, baa_l2_row_off
    ld   l, a
    ld   h, 0
    add  hl, hl
    ld   bc, row_addr
    add  hl, bc
    ld   c, (hl)
    inc  hl
    ld   b, (hl)
    ld   h, b
    ld   l, c
    ld   (sba_scr2), hl
    jr   baa_l2_row_done
baa_l2_row_off:
    ld   hl, 0
    ld   (sba_scr2), hl
baa_l2_row_done:

    ; Reset col ptr and load sprite ptr for this row into DE
    ld   hl, sprite_blit_byte
    ld   (sba_colp), hl
    ld   hl, (sba_spr)
    ex   de, hl             ; DE = sprite ptr for letter 0 at this row

    ; Line1: letters 0-8 (9 letters, anim_cy1)
    ld   hl, (sba_scr1)
    ld   a, h
    or   l
    jr   z, baa_skip_l1

    ld   b, 9
baa_l1_ltr:
    ld   hl, (sba_colp)
    ld   a, (hl)
    inc  hl
    ld   (sba_colp), hl
    ld   hl, (sba_scr1)
    add  a, l
    ld   l, a
    jr   nc, baa_nc1
    inc  h
baa_nc1:
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    inc  hl
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    inc  hl
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    inc  hl
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    ld   hl, 156
    add  hl, de
    ex   de, hl
    djnz baa_l1_ltr
    jr   baa_after_l1

baa_skip_l1:
    ld   hl, (sba_colp)     ; advance col ptr past 9 line1 entries
    ld   bc, 9
    add  hl, bc
    ld   (sba_colp), hl
    ld   hl, 1440           ; 9 * 160 — advance DE to letter 9
    add  hl, de
    ex   de, hl

baa_after_l1:

    ; Line2: letters 9-18 (10 letters, anim_cy2)
    ld   hl, (sba_scr2)
    ld   a, h
    or   l
    jr   z, baa_skip_l2

    ld   b, 10
baa_l2_ltr:
    ld   hl, (sba_colp)
    ld   a, (hl)
    inc  hl
    ld   (sba_colp), hl
    ld   hl, (sba_scr2)
    add  a, l
    ld   l, a
    jr   nc, baa_nc2
    inc  h
baa_nc2:
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    inc  hl
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    inc  hl
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    inc  hl
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    ld   hl, 156
    add  hl, de
    ex   de, hl
    djnz baa_l2_ltr
    jr   baa_row_next

baa_skip_l2:
    ld   hl, 1600           ; 10 * 160
    add  hl, de
    ex   de, hl

baa_row_next:
    ; Advance sprite ptr by 4 (next row of all letters)
    ld   hl, (sba_spr)
    inc  hl
    inc  hl
    inc  hl
    inc  hl
    ld   (sba_spr), hl
    ld   hl, sba_y1
    inc  (hl)
    ld   hl, sba_y2
    inc  (hl)

    pop  bc
    dec  b
    jp   nz, baa_outer
    ret

; ─────────────────────────────────────────────────────────────────────────────
; scroll_clear_blit — combined clear+blit for scroll phase (single pass per row)
; For each of 40 rows: zero the screen row, then OR all 19 letters into it.
; Replaces separate clear_bands + blit_all_animated calls in do_scroll.
; The ULA never sees a blank frame; each row transitions directly old→new.
; ─────────────────────────────────────────────────────────────────────────────
scb_y1:   DEFB 0
scb_y2:   DEFB 0
scb_scr1: DEFW 0
scb_scr2: DEFW 0
scb_colp: DEFW 0
scb_spr:  DEFW 0   ; sprite row ptr = letter_sprites + outer_row*4

scroll_clear_blit:
    ; Clear 5 extra rows above each band to catch trailing pixels from previous frame.
    ; scroll_y2 has max step 4 px/frame; those rows slip above the normal cy-20 band.
    ld   a, (anim_cy1)
    sub  25             ; start row = cy1 - 25  (5 rows above normal band top)
    ld   b, 5
    call clr_fixed_band
    ld   a, (anim_cy2)
    sub  25
    ld   b, 5
    call clr_fixed_band

    ld   a, (anim_cy1)
    sub  20
    ld   (scb_y1), a
    ld   a, (anim_cy2)
    sub  20
    ld   (scb_y2), a
    ld   hl, letter_sprites
    ld   (scb_spr), hl

    ld   b, 40
scb_outer:
    push bc

    ; === LINE1: zero row then blit 9 letters ===
    ld   a, (scb_y1)
    cp   192
    jr   nc, scb_l1_skip

    ld   l, a
    ld   h, 0
    add  hl, hl
    ld   bc, row_addr
    add  hl, bc
    ld   c, (hl)
    inc  hl
    ld   b, (hl)
    ld   h, b
    ld   l, c
    ld   a, (scr_or)    ; redirect to shadow buffer when scr_or = 0x80
    or   h
    ld   h, a
    ld   (scb_scr1), hl

    ld   d, h           ; zero 32 bytes via LDIR
    ld   e, l
    inc  de
    ld   bc, 31
    ld   (hl), 0
    ldir

    ld   hl, sprite_blit_byte
    ld   (scb_colp), hl
    ld   hl, (scb_spr)
    ex   de, hl

    ld   b, 9
scb_l1_ltr:
    ld   hl, (scb_colp)
    ld   a, (hl)
    inc  hl
    ld   (scb_colp), hl
    ld   hl, (scb_scr1)
    add  a, l
    ld   l, a
    jr   nc, scb_nc1
    inc  h
scb_nc1:
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    inc  hl
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    inc  hl
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    inc  hl
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    ld   hl, 156
    add  hl, de
    ex   de, hl
    djnz scb_l1_ltr
    jr   scb_after_l1

scb_l1_skip:
    ; col ptr to line2 start; DE to letter 9's row data
    ld   hl, sprite_blit_byte
    ld   bc, 9
    add  hl, bc
    ld   (scb_colp), hl
    ld   hl, (scb_spr)
    ex   de, hl
    ld   hl, 1440
    add  hl, de
    ex   de, hl

scb_after_l1:

    ; === LINE2: zero row then blit 10 letters ===
    ld   a, (scb_y2)
    cp   192
    jr   nc, scb_l2_skip

    ld   l, a
    ld   h, 0
    add  hl, hl
    ld   bc, row_addr
    add  hl, bc
    ld   c, (hl)
    inc  hl
    ld   b, (hl)
    ld   h, b
    ld   l, c
    ld   a, (scr_or)    ; redirect to shadow buffer when scr_or = 0x80
    or   h
    ld   h, a
    ld   (scb_scr2), hl

    push de             ; save sprite ptr across LDIR (DE will be clobbered)
    ld   d, h
    ld   e, l
    inc  de
    ld   bc, 31
    ld   (hl), 0
    ldir
    pop  de             ; restore sprite ptr (now at letter 9's row data)

    ld   b, 10
scb_l2_ltr:
    ld   hl, (scb_colp)
    ld   a, (hl)
    inc  hl
    ld   (scb_colp), hl
    ld   hl, (scb_scr2)
    add  a, l
    ld   l, a
    jr   nc, scb_nc2
    inc  h
scb_nc2:
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    inc  hl
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    inc  hl
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    inc  hl
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    ld   hl, 156
    add  hl, de
    ex   de, hl
    djnz scb_l2_ltr

scb_l2_skip:
    ld   hl, (scb_spr)
    inc  hl
    inc  hl
    inc  hl
    inc  hl
    ld   (scb_spr), hl
    ld   hl, scb_y1
    inc  (hl)
    ld   hl, scb_y2
    inc  (hl)

    pop  bc
    dec  b
    jp   nz, scb_outer
    ret

; ─────────────────────────────────────────────────────────────────────────────
; clear_bands — zero only the 40 pixel rows occupied by each sprite line
; Much faster than clearing the full 6144-byte screen.
; Uses anim_cy1 and anim_cy2.
; ─────────────────────────────────────────────────────────────────────────────
clear_bands:
    ld   a, (anim_cy1)
    call clr_band_40
    ld   a, (anim_cy2)
    ; fall through

; clr_band_40 — zero 40 full-width (32 byte) pixel rows centred on A
clr_band_40:
    sub  20             ; first row = cy - 20
    ld   b, 40
clrb_loop:
    push af             ; AF: A = current row
    push bc             ; BC: B = remaining rows
    cp   192            ; off-screen? (handles negative rows stored as >191)
    jr   nc, clrb_skip
    ; row_addr lookup
    ld   l, a
    ld   h, 0
    add  hl, hl         ; hl = 2 * row
    ld   bc, row_addr
    add  hl, bc
    ld   e, (hl)
    inc  hl
    ld   d, (hl)        ; DE = screen row base address
    ld   a, (scr_or)    ; redirect to shadow buffer when scr_or = 0x80
    or   d
    ld   d, a
    ; zero 32 bytes (unrolled — see zero_row_32)
    ld   h, d
    ld   l, e
    call zero_row_32
clrb_skip:
    pop  bc
    pop  af
    inc  a              ; next row
    djnz clrb_loop
    ret

; ─────────────────────────────────────────────────────────────────────────────
; smul16 — signed 8×8 multiply
; In:  A = signed operand 1, B = signed operand 2
; Out: HL = signed 16-bit product
; Uses: A, B, C, D, HL, F
; ─────────────────────────────────────────────────────────────────────────────
smul16:
    ld   c, a
    xor  b               ; bit 7 = result sign (XOR of input signs)
    push af              ; save result sign in A bit 7

    ld   a, c
    bit  7, a
    jr   z, s16_a_ok
    neg
s16_a_ok:
    ld   c, a            ; C = |operand1| (0..127)

    bit  7, b
    jr   z, s16_b_ok
    ld   a, b
    neg
    ld   b, a            ; B = |operand2| (0..127)
s16_b_ok:

    ; Unsigned 8×8 multiply, unrolled 8 iterations.
    ; add hl,de (11T) replaces manual ld a,l/add/ld l,a/inc h (~25T+loop overhead).
    ld   hl, 0
    ld   d, 0
    ld   e, b            ; DE = B (addend)

    add  hl, hl
    sla  c
    jr   nc, s16_7
    add  hl, de
s16_7:
    add  hl, hl
    sla  c
    jr   nc, s16_6
    add  hl, de
s16_6:
    add  hl, hl
    sla  c
    jr   nc, s16_5
    add  hl, de
s16_5:
    add  hl, hl
    sla  c
    jr   nc, s16_4
    add  hl, de
s16_4:
    add  hl, hl
    sla  c
    jr   nc, s16_3
    add  hl, de
s16_3:
    add  hl, hl
    sla  c
    jr   nc, s16_2
    add  hl, de
s16_2:
    add  hl, hl
    sla  c
    jr   nc, s16_1
    add  hl, de
s16_1:
    add  hl, hl
    sla  c
    jr   nc, s16_0
    add  hl, de
s16_0:

    ; Apply sign
    pop  af
    bit  7, a
    ret  z               ; positive — done
    ld   a, h
    cpl
    ld   h, a
    ld   a, l
    cpl
    ld   l, a
    inc  hl              ; negate HL
    ret

; ─────────────────────────────────────────────────────────────────────────────
; rotate_point — apply 2D rotation to (rot_dx, rot_dy)
; Uses spin_sin and spin_cos (set once per frame by draw_spin_frame).
; Out: rot_new_dx = (dx*cos - dy*sin) >> 7
;      rot_new_dy = (dx*sin + dy*cos) >> 7
; Uses: A, B, C, D, HL, DE, F, stack
; ─────────────────────────────────────────────────────────────────────────────
rotate_point:
    ; new_dx = cos_prod[dx+17] - sin_prod[dy+17]
    ld   a, (rot_dx)
    add  a, 17
    ld   hl, cos_prod
    add  a, l
    ld   l, a
    jr   nc, rp1_nc
    inc  h
rp1_nc:
    ld   d, (hl)

    ld   a, (rot_dy)
    add  a, 17
    ld   hl, sin_prod
    add  a, l
    ld   l, a
    jr   nc, rp2_nc
    inc  h
rp2_nc:
    ld   a, d
    sub  (hl)
    ld   (rot_new_dx), a

    ; new_dy = sin_prod[dx+17] + cos_prod[dy+17]
    ld   a, (rot_dx)
    add  a, 17
    ld   hl, sin_prod
    add  a, l
    ld   l, a
    jr   nc, rp3_nc
    inc  h
rp3_nc:
    ld   d, (hl)

    ld   a, (rot_dy)
    add  a, 17
    ld   hl, cos_prod
    add  a, l
    ld   l, a
    jr   nc, rp4_nc
    inc  h
rp4_nc:
    ld   a, d
    add  a, (hl)
    ld   (rot_new_dy), a
    ret

; ─────────────────────────────────────────────────────────────────────────────
; draw_rot_letter — draw one letter with rotation applied
; Reads 7 shape points from (dar_shapes), advances dar_shapes by 14.
; Uses spin_cx, spin_cy, spin_sin, spin_cos.
; ─────────────────────────────────────────────────────────────────────────────
draw_rot_letter:
    ld   hl, (dar_shapes)
    ld   bc, letter_pts
    ld   a, 7
drl_pts:
    push af                      ; save iteration count
    push bc                      ; save letter_pts pointer

    ld   a, (hl)
    ld   (rot_dx), a
    inc  hl
    ld   a, (hl)
    ld   (rot_dy), a
    inc  hl
    ld   (drl_shape_ptr), hl     ; save shape pointer across rotate_point

    call rotate_point            ; → rot_new_dx, rot_new_dy (clobbers A,B,C,D,HL)

    ld   hl, (drl_shape_ptr)     ; restore shape pointer
    pop  bc                      ; restore letter_pts pointer

    ; point_x = cx + new_dx
    ld   a, (spin_cx)
    ld   d, a
    ld   a, (rot_new_dx)
    add  a, d
    ld   (bc), a
    inc  bc

    ; point_y = cy + new_dy
    ld   a, (spin_cy)
    ld   d, a
    ld   a, (rot_new_dy)
    add  a, d
    ld   (bc), a
    inc  bc

    pop  af
    dec  a
    jr   nz, drl_pts

    ld   (dar_shapes), hl        ; save advanced shape pointer (14 bytes past letter start)

    ; Draw 6 line segments between consecutive points in letter_pts
    ld   hl, letter_pts
    ld   b, 6
drl_segs:
    push bc
    push hl
    ld   d, (hl)
    inc  hl
    ld   e, (hl)
    inc  hl
    ld   b, (hl)
    inc  hl
    ld   c, (hl)
    call draw_line_fast          ; incremental-addressing line drawer (shadow)
    pop  hl
    inc  hl
    inc  hl
    pop  bc
    djnz drl_segs
    ret

; ─────────────────────────────────────────────────────────────────────────────
; draw_spin_frame — clear and redraw all 19 letters with rotation for current frame
; Uses anim_frame to index spin_ang; writes directly to screen (sprite_mode=0).
; ─────────────────────────────────────────────────────────────────────────────
draw_spin_frame:
    ld   hl, plot_screen_fast    ; draw_line plots into the shadow buffer here
    ld   (dl_plot_call+1), hl
    ; Compute angle = spin_ang[anim_frame]
    ld   a, (anim_frame)
    ld   l, a
    ld   h, 0
    ld   de, spin_ang
    add  hl, de
    ld   a, (hl)             ; A = angle (sin_tab index)
    ld   c, a                ; C = angle (save for cos lookup)

    ; spin_sin = sin_tab[angle]
    ld   l, a
    ld   h, 0
    ld   de, sin_tab
    add  hl, de
    ld   a, (hl)
    ld   (spin_sin), a

    ; spin_cos = sin_tab[(angle+64) & 255]
    ld   a, c
    add  a, 64               ; wraps naturally in 8-bit arithmetic
    ld   l, a
    ld   h, 0
    ld   de, sin_tab
    add  hl, de
    ld   a, (hl)
    ld   (spin_cos), a

    ; Ensure screen drawing mode
    xor  a
    ld   (sprite_mode), a

    ; Build cos_prod[35]: cos_prod[i] = (i-17)*spin_cos >> 7, for i=0..34 (d=-17..17)
    ld   hl, cos_prod
    ld   c, 239          ; start value: -17 as unsigned byte (0xEF)
    ld   b, 35
dsf_cos_tab:
    push bc
    push hl
    ld   a, (spin_cos)
    ld   b, c            ; A=cos, B=d
    call smul16          ; HL = cos * d
    ld   a, l
    and  0x80
    rlca
    ld   c, a
    ld   a, h
    add  a, a
    or   c               ; A = result >> 7
    pop  hl
    ld   (hl), a
    inc  hl
    pop  bc
    inc  c
    djnz dsf_cos_tab

    ; Build sin_prod[35]: sin_prod[i] = (i-17)*spin_sin >> 7
    ld   hl, sin_prod
    ld   c, 239
    ld   b, 35
dsf_sin_tab:
    push bc
    push hl
    ld   a, (spin_sin)
    ld   b, c
    call smul16
    ld   a, l
    and  0x80
    rlca
    ld   c, a
    ld   a, h
    add  a, a
    or   c
    pop  hl
    ld   (hl), a
    inc  hl
    pop  bc
    inc  c
    djnz dsf_sin_tab

    ; Reset iterators to start of shape/position tables
    ld   hl, letter_shapes
    ld   (dar_shapes), hl
    ld   hl, rest_pos
    ld   (dar_pos), hl

    ld   b, 19
dsf_loop:
    push bc

    ; Load this letter's rest position
    ld   hl, (dar_pos)
    ld   a, (hl)
    ld   (spin_cx), a
    inc  hl
    ld   a, (hl)
    ld   (spin_cy), a
    inc  hl
    ld   (dar_pos), hl

    call draw_rot_letter

    pop  bc
    djnz dsf_loop
    ret

; ─────────────────────────────────────────────────────────────────────────────
; clr_spin_letter_band — zero 6 bytes × 40 rows around spin_cx / spin_cy.
; Covers ±20px vertically and ±24px horizontally (enough for any rotation).
; Column capped at 26 so 6 bytes always fit within the 32-byte screen row.
; ─────────────────────────────────────────────────────────────────────────────
clr_spin_letter_band:
    ld   a, (spin_cx)
    srl  a
    srl  a
    srl  a               ; A = cx / 8
    sub  2               ; A = cx/8 - 2  (start column)
    jp   m, cslb_neg
    cp   26
    jr   c, cslb_col_ok
    ld   a, 26           ; cap: bytes 26..31 fit in a 32-byte row
    jr   cslb_col_ok
cslb_neg:
    xor  a
cslb_col_ok:
    ld   (cslb_col), a

    ld   a, (spin_cy)
    sub  20              ; first row = cy - 20
    ld   b, 40
cslb_loop:
    push bc
    push af
    cp   192             ; unsigned: skips negative rows (stored as >191)
    jr   nc, cslb_skip

    ld   l, a
    ld   h, 0
    add  hl, hl
    ld   bc, row_addr
    add  hl, bc
    ld   c, (hl)
    inc  hl
    ld   b, (hl)
    ld   h, b
    ld   l, c

    ld   a, (cslb_col)
    add  a, l
    ld   l, a
    jr   nc, cslb_nc
    inc  h
cslb_nc:
    xor  a
    ld   (hl), a
    inc  hl
    ld   (hl), a
    inc  hl
    ld   (hl), a
    inc  hl
    ld   (hl), a
    inc  hl
    ld   (hl), a
    inc  hl
    ld   (hl), a

cslb_skip:
    pop  af
    inc  a
    pop  bc
    djnz cslb_loop
    ret

cslb_col: DEFB 0

; ─────────────────────────────────────────────────────────────────────────────
; clr_fixed_band — zero B screen rows starting at row A
; Handles off-screen rows (cp 192 unsigned check, same as clr_band_40).
; ─────────────────────────────────────────────────────────────────────────────
clr_fixed_band:
cfb_loop:
    push af
    push bc
    cp   192
    jr   nc, cfb_skip
    ld   l, a
    ld   h, 0
    add  hl, hl
    ld   bc, row_addr
    add  hl, bc
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ld   a, (scr_or)    ; redirect to shadow buffer when scr_or = 0x80
    or   d
    ld   d, a
    ld   h, d
    ld   l, e
    call zero_row_32    ; fast unrolled 32-byte zero
cfb_skip:
    pop  bc
    pop  af
    inc  a
    djnz cfb_loop
    ret

; ─────────────────────────────────────────────────────────────────────────────
; copy_band — copy B screen rows starting at row A from the shadow buffer to the
; live screen. Source = row_addr[y] | 0x8000 (shadow), dest = row_addr[y].
; This is the ONLY write the ULA sees during scroll/spin: each row goes straight
; from old frame to new frame (no blank intermediate), so no flicker — at worst a
; single tear line where the beam meets the copy.
; In: A = start row, B = row count. Off-screen rows (>=192) are skipped.
; ─────────────────────────────────────────────────────────────────────────────
copy_band:
cpb_loop:
    push af
    push bc
    cp   192
    jr   nc, cpb_skip
    ld   l, a
    ld   h, 0
    add  hl, hl
    ld   bc, row_addr
    add  hl, bc
    ld   e, (hl)
    inc  hl
    ld   d, (hl)        ; DE = live screen address (dest)
    ld   h, d
    ld   l, e
    ld   a, h
    or   0x80
    ld   h, a           ; HL = shadow address (source)
    call copy_row_32    ; copy 32 bytes shadow -> screen (unrolled)
cpb_skip:
    pop  bc
    pop  af
    inc  a
    djnz cpb_loop
    ret

; copy_row_32 — copy 32 bytes HL -> DE, fully unrolled (16T/byte vs LDIR's 21T).
; Clobbers A?no; uses BC (LDI decrements it) — callers don't rely on BC across it.
copy_row_32:
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ldi
    ret

; zero_row_32 — zero 32 bytes from HL, unrolled. HL must be 32-byte aligned within
; its page (screen/shadow row bases are), so inc l never carries. Clobbers A, HL.
zero_row_32:
    xor  a
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    inc  l
    ld   (hl), a
    ret

; copy_scroll_bands — refresh both scroll lines. Window = cy-25 .. cy+19 (45 rows)
; matches scroll_clear_blit's cleared+rendered extent (incl. the 5-row ghost pre-
; clear), so the previous frame's letters are always fully overwritten.
copy_scroll_bands:
    ld   a, (anim_cy1)
    sub  25
    ld   b, 45
    call copy_band
    ld   a, (anim_cy2)
    sub  25
    ld   b, 45
    jp   copy_band

; copy_spin_bands — refresh both spin lines (40-row bands, cy-20 .. cy+19).
copy_spin_bands:
    ld   a, (anim_cy1)
    sub  20
    ld   b, 40
    call copy_band
    ld   a, (anim_cy2)
    sub  20
    ld   b, 40
    jp   copy_band

; copy_orbit_bands — copy the dynamic orbit band shadow -> screen (matches the
; band that draw_orbit_frame cleared and blitted this frame).
copy_orbit_bands:
    ld   a, (orb_bcount)
    ld   b, a
    ld   a, (orb_bstart)
    jp   copy_band

; build_shadow_row_table — fill row_addr_shadow with row_addr | 0x8000 (one-time).
; Lets plot_screen_fast index a table that already points into the shadow buffer.
build_shadow_row_table:
    ld   hl, row_addr
    ld   de, row_addr_shadow
    ld   b, 192
brt_loop:
    ld   a, (hl)        ; low byte (copied unchanged)
    ld   (de), a
    inc  hl
    inc  de
    ld   a, (hl)        ; high byte | 0x80 -> 0xC0xx
    or   0x80
    ld   (de), a
    inc  hl
    inc  de
    djnz brt_loop
    ret

; ─────────────────────────────────────────────────────────────────────────────
; clear_orbit_bands — clear the full orbit extent for both letter lines.
; Covers anim_cy1 ± 58 rows and anim_cy2 ± 58 rows (116 rows each).
; Handles negative start row via unsigned cp 192 skip in clr_fixed_band.
; ─────────────────────────────────────────────────────────────────────────────
clear_orbit_bands:
    ld   a, (anim_cy1)
    sub  58             ; start row = cy1 - 58 (may wrap; off-screen rows skipped)
    ld   b, 116
    call clr_fixed_band
    ld   a, (anim_cy2)
    sub  58
    ld   b, 116
    jp   clr_fixed_band ; tail call — clr_fixed_band's ret returns to our caller

; ─────────────────────────────────────────────────────────────────────────────
; orbit_clear_blit_letter — combined clear-prev + blit-new for one orbit letter.
; For each of 40 rows: zero 4 bytes at prev position, OR 4 bytes at new position.
; Eliminates the blank-screen gap that a separate clear pass would cause.
; In:  ocb_prev_col/sy = prev position (0xFF col = skip clear)
;      ocb_new_col/sy  = new position  (0xFF col = skip blit, still advance DE)
;      orb_blt_spr     = sprite ptr for this letter
; Out: DE = orb_blt_spr + 160
; ─────────────────────────────────────────────────────────────────────────────
; orbit_clear_prev_letter — zero the 4-byte column at prev position (pass 1 of 2).
; All 19 letters are cleared before any blitting so adjacent letter data is safe.
; In: ocb_prev_col (0-28 valid, 0xFF = skip), ocb_prev_sy (incremented each row)
orbit_clear_prev_letter:
    ld   b, 40
ocl_outer:
    push bc
    ld   a, (ocb_prev_col)
    cp   29                 ; 0xFF >= 29 → skip
    jr   nc, ocl_skip
    ld   a, (ocb_prev_sy)
    cp   192
    jr   nc, ocl_skip

    ld   l, a
    ld   h, 0
    add  hl, hl
    ld   bc, row_addr
    add  hl, bc
    ld   c, (hl)
    inc  hl
    ld   b, (hl)
    ld   h, b
    ld   l, c
    ld   a, (scr_or)    ; 0x00 during orbit (live screen); kept uniform
    or   h
    ld   h, a

    ld   a, (ocb_prev_col)
    add  a, l
    ld   l, a
    jr   nc, ocl_nc
    inc  h
ocl_nc:
    xor  a
    ld   (hl), a
    inc  hl
    ld   (hl), a
    inc  hl
    ld   (hl), a
    inc  hl
    ld   (hl), a

ocl_skip:
    ld   hl, ocb_prev_sy
    inc  (hl)
    pop  bc
    djnz ocl_outer
    ret

; orbit_blit_new_letter — OR a letter's 40x4 sprite into the SHADOW buffer at its
; new position, with INCREMENTAL addressing: look up the first row's address once,
; then step down one pixel line per row via dlf_down_hl rather than a per-row
; row_addr lookup. The column is constant for all 40 rows so it's range-checked
; once up front; rows are always on-screen during orbit (sy in 11..165) so there's
; no per-row sy check. Orbit always renders to shadow, so row_addr_shadow is used.
; In: ocb_new_col (0-28 valid, 0xFF = skip), ocb_new_sy, orb_blt_spr
; Out: DE = orb_blt_spr + 160
orbit_blit_new_letter:
    ld   hl, (orb_blt_spr)
    ex   de, hl             ; DE = sprite ptr

    ld   a, (ocb_new_col)
    cp   29                 ; 0xFF (or any >=29) = off-screen: skip whole letter
    jr   nc, obn_whole_skip
    ld   c, a               ; C = col (constant for all rows)

    ld   a, (ocb_new_sy)    ; HL = shadow byte address of the first sprite row
    ld   l, a
    ld   h, 0
    add  hl, hl
    push de                 ; protect sprite ptr (need DE for the table base)
    ld   de, row_addr_shadow
    add  hl, de
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ld   h, d
    ld   l, e               ; HL = shadow row base
    pop  de                 ; DE = sprite ptr
    ld   a, c
    add  a, l
    ld   l, a
    jr   nc, obn_col_nc
    inc  h
obn_col_nc:

    ld   b, 40
obn_outer:
    push hl                 ; save row-start address
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    inc  hl
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    inc  hl
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    inc  hl
    ld   a, (de)
    inc  de
    or   (hl)
    ld   (hl), a
    pop  hl                 ; HL = row start
    call dlf_down_hl        ; HL -> same column, next pixel row (preserves DE, B)
    djnz obn_outer
    ret

obn_whole_skip:
    ld   hl, 160            ; advance DE past this letter's 160 sprite bytes
    add  hl, de
    ex   de, hl
    ret

; ─────────────────────────────────────────────────────────────────────────────
; draw_orbit_frame — draw all 19 letters orbiting their rest centres
; Each letter uses: orbit_angle = (orb_base_angle + orb_phase[letter]) & 255
;   orbit_cx = rest_cx + (radius * cos(orbit_angle)) >> 7
;   orbit_cy = rest_cy + (radius * sin(orbit_angle)) >> 7
; Letters drawn with identity rotation (spin_sin=0, spin_cos=127 ≈ 1.0).
; orb_base_angle increments by 2 each frame for ~1.2 orbits over 150 frames.
; ─────────────────────────────────────────────────────────────────────────────
draw_orbit_frame:
    ld   a, (anim_frame)
    ld   l, a
    ld   h, 0
    ld   de, orb_scale
    add  hl, de
    ld   a, (hl)
    ld   (orb_radius), a

    ; orb_base_angle = anim_frame * 2 (mod 256). Deriving it from anim_frame rather
    ; than incrementing keeps the orbit's revolutions fixed no matter how fast
    ; anim_frame advances (ORB_STEP), and auto-resets when anim_frame returns to 0.
    ld   a, (anim_frame)
    add  a, a
    ld   (orb_base_angle), a

    ; Size the band to THIS frame's radius so small-radius frames (most of the
    ; sequence) clear+copy far fewer rows. 3 rows of margin each side also covers
    ; the previous frame: anim_frame can advance up to ~3 indices/frame and
    ; orb_scale changes by at most 1 per index, so radius moves <=3 per frame.
    ;   start = 33 - radius ; count = 111 + 2*radius
    ld   a, (orb_radius)
    ld   b, a
    ld   a, 33
    sub  b
    ld   (orb_bstart), a
    ld   a, b
    add  a, a            ; 2*radius
    add  a, 111          ; 111 + 2*radius  (max 163 at radius 26)
    ld   (orb_bcount), a

    ; Clear the orbit band in the SHADOW buffer (scr_or = 0x80 set by the caller).
    ; One full-width unrolled clear is cheaper than 19 per-letter column clears and
    ; removes the adjacency problem, so no prev-position tracking is needed.
    ld   a, (orb_bcount)
    ld   b, a
    ld   a, (orb_bstart)
    call clr_fixed_band

    ; Blit all 19 letters at their orbit positions into the shadow buffer.
    ld   hl, rest_pos
    ld   (dar_pos), hl
    ld   hl, orb_phase
    ld   (orb_phase_ptr), hl
    ld   hl, letter_sprites
    ld   (orb_blt_spr), hl
    ld   hl, orb_prev_col
    ld   (orb_prev_col_ptr), hl
    ld   hl, orb_prev_sy
    ld   (orb_prev_sy_ptr), hl

    ld   b, 19
dof_blit_loop:
    push bc

    ld   hl, (dar_pos)
    ld   a, (hl)
    ld   (orb_rest_cx), a
    inc  hl
    ld   a, (hl)
    ld   (orb_rest_cy), a
    inc  hl
    ld   (dar_pos), hl

    ld   hl, (orb_phase_ptr)
    ld   a, (hl)
    inc  hl
    ld   (orb_phase_ptr), hl
    ld   c, a
    ld   a, (orb_base_angle)
    add  a, c
    ld   c, a

    ld   l, a
    ld   h, 0
    ld   de, sin_tab
    add  hl, de
    ld   a, (hl)
    ld   (orb_sin), a

    ld   a, c
    add  a, 64
    ld   l, a
    ld   h, 0
    ld   de, sin_tab
    add  hl, de
    ld   a, (hl)
    ld   (orb_cos), a

    ld   a, (orb_radius)
    ld   b, a
    ld   a, (orb_cos)
    call smul16
    ld   a, l
    and  0x80
    rlca
    ld   c, a
    ld   a, h
    add  a, a
    or   c
    ld   d, a
    ld   a, (orb_rest_cx)
    add  a, d
    ld   (spin_cx), a

    ld   a, (orb_radius)
    ld   b, a
    ld   a, (orb_sin)
    call smul16
    ld   a, l
    and  0x80
    rlca
    ld   c, a
    ld   a, h
    add  a, a
    or   c
    ld   d, a
    ld   a, (orb_rest_cy)
    add  a, d
    ld   (spin_cy), a

    ; Compute new col (0xFF = off-screen)
    ld   a, (spin_cx)
    srl  a
    srl  a
    srl  a
    sub  2
    jp   m, dof2_col_off
    cp   29
    jr   nc, dof2_col_off
    ld   (ocb_new_col), a
    jr   dof2_col_done
dof2_col_off:
    ld   a, 0xFF
    ld   (ocb_new_col), a
dof2_col_done:
    ld   a, (spin_cy)
    sub  20
    ld   (ocb_new_sy), a

    call orbit_blit_new_letter
    ex   de, hl
    ld   (orb_blt_spr), hl

    pop  bc
    dec  b
    jp   nz, dof_blit_loop
    ret                     ; orb_base_angle is derived from anim_frame at the top
