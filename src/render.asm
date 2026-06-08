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

; ── Sprite storage: 19 × 40 rows × 4 bytes = 3040 bytes ─────────────────────
letter_sprites: DEFS 3040

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

; ── Orbit working vars ───────────────────────────────────────────────────────
orb_base_angle: DEFB 0   ; increments each orbit frame; shared across all 19 letters
orb_radius:     DEFB 0   ; orb_scale[frame] + 12
orb_rest_cx:    DEFB 0
orb_rest_cy:    DEFB 0
orb_sin:        DEFB 0   ; sin_tab[orbit_angle] for current letter
orb_cos:        DEFB 0   ; cos for current letter orbit angle
orb_phase_ptr:  DEFW 0   ; walks through orb_phase table (19 bytes)

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
    call plot_pixel

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
blt_spr:      DEFW 0   ; sprite byte pointer (walks through letter_sprites)
blt_col:      DEFB 0   ; screen byte column for current letter
blt_scy:      DEFB 0   ; current screen_y for each row

blit_all_animated:
    ld   hl, letter_sprites
    ld   (blt_spr), hl
    ld   hl, sprite_blit_byte
    ld   (baa_col_ptr), hl
    ld   b, 19

baa_outer:
    push bc

    ; Starting screen_y = cy - 20  (B>=11 = line1, else line2)
    ld   a, b
    cp   11
    jr   c, baa_line2
    ld   a, (anim_cy1)
    jr   baa_got_cy
baa_line2:
    ld   a, (anim_cy2)
baa_got_cy:
    sub  20
    ld   (blt_scy), a

    ; Blit column for this letter
    ld   hl, (baa_col_ptr)
    ld   a, (hl)
    inc  hl
    ld   (baa_col_ptr), hl
    ld   (blt_col), a

    ; 40 rows
    ld   b, 40
baa_row:
    push bc

    ld   a, (blt_scy)
    cp   192            ; clip (handles negative stored as >191)
    jr   nc, baa_skip

    ; HL = row_addr[screen_y]
    ld   l, a
    ld   h, 0
    add  hl, hl
    ld   bc, row_addr
    add  hl, bc
    ld   c, (hl)
    inc  hl
    ld   b, (hl)        ; BC = screen row base address

    ; BC += blt_col
    ld   a, (blt_col)
    add  a, c
    ld   c, a
    jr   nc, baa_nc
    inc  b
baa_nc:
    ; Load sprite ptr, set HL=screen addr, OR 4 bytes
    ld   hl, (blt_spr)
    ex   de, hl         ; DE = sprite ptr
    ld   h, b
    ld   l, c           ; HL = screen byte address

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

    ; Save advanced sprite ptr (DE=sprite+4) back via swap
    ex   de, hl
    ld   (blt_spr), hl
    jr   baa_next

baa_skip:
    ; Advance sprite ptr past 4 bytes without blitting
    ld   hl, (blt_spr)
    inc  hl
    inc  hl
    inc  hl
    inc  hl
    ld   (blt_spr), hl

baa_next:
    ld   hl, blt_scy
    inc  (hl)           ; advance screen_y

    pop  bc
    djnz baa_row

    ; After 40 rows, blt_spr has advanced by 160 — correct for next letter
    pop  bc
    djnz baa_outer
    ret

baa_col_ptr:  DEFW 0

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
    ; zero 32 bytes via LD(HL),0 + LDIR
    ld   h, d
    ld   l, e
    ld   (hl), 0
    inc  de             ; DE = base + 1
    ld   bc, 31
    ldir
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

    ; Unsigned 8×8: shift C left 8 times; for each 1-bit shifted out, add B to HL
    ld   hl, 0
    ld   d, 8
s16_loop:
    add  hl, hl          ; HL <<= 1
    sla  c               ; C <<= 1; old bit 7 → carry
    jr   nc, s16_skip
    ld   a, l
    add  a, b
    ld   l, a
    jr   nc, s16_nc
    inc  h
s16_nc:
s16_skip:
    dec  d
    jr   nz, s16_loop

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
    ; new_dx = (dx*cos - dy*sin) >> 7
    ld   a, (rot_dx)
    ld   b, a
    ld   a, (spin_cos)
    call smul16          ; HL = dx * cos
    push hl

    ld   a, (rot_dy)
    ld   b, a
    ld   a, (spin_sin)
    call smul16          ; HL = dy * sin

    pop  de              ; DE = dx*cos
    ld   a, e
    sub  l
    ld   l, a
    ld   a, d
    sbc  a, h
    ld   h, a            ; HL = dx*cos - dy*sin (signed 16-bit)

    ; HL >> 7 → A  (arithmetic: result = (H<<1) | (L>>7))
    ld   a, l
    and  0x80
    rlca                 ; A = 1 if bit 7 of L was set, else 0
    ld   c, a
    ld   a, h
    add  a, a            ; A = H<<1 (8-bit, wraps correctly for our range)
    or   c
    ld   (rot_new_dx), a

    ; new_dy = (dx*sin + dy*cos) >> 7
    ld   a, (rot_dx)
    ld   b, a
    ld   a, (spin_sin)
    call smul16          ; HL = dx * sin
    push hl

    ld   a, (rot_dy)
    ld   b, a
    ld   a, (spin_cos)
    call smul16          ; HL = dy * cos

    pop  de              ; DE = dx*sin
    ld   a, l
    add  a, e
    ld   l, a
    ld   a, h
    adc  a, d
    ld   h, a            ; HL = dx*sin + dy*cos (signed 16-bit)

    ld   a, l
    and  0x80
    rlca
    ld   c, a
    ld   a, h
    add  a, a
    or   c
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
    call draw_line
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
    ld   h, d
    ld   l, e
    ld   (hl), 0
    inc  de
    ld   bc, 31
    ldir
cfb_skip:
    pop  bc
    pop  af
    inc  a
    djnz cfb_loop
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
; draw_orbit_frame — draw all 19 letters orbiting their rest centres
; Each letter uses: orbit_angle = (orb_base_angle + orb_phase[letter]) & 255
;   orbit_cx = rest_cx + (radius * cos(orbit_angle)) >> 7
;   orbit_cy = rest_cy + (radius * sin(orbit_angle)) >> 7
; Letters drawn with identity rotation (spin_sin=0, spin_cos=127 ≈ 1.0).
; orb_base_angle increments by 2 each frame for ~1.2 orbits over 150 frames.
; ─────────────────────────────────────────────────────────────────────────────
draw_orbit_frame:
    ; radius = orb_scale[anim_frame] + 12
    ld   a, (anim_frame)
    ld   l, a
    ld   h, 0
    ld   de, orb_scale
    add  hl, de
    ld   a, (hl)
    ld   (orb_radius), a     ; orb_scale starts at 0, ramps to 26 — no jump on entry

    ; Identity rotation for letter shape (no spin during orbit)
    xor  a
    ld   (spin_sin), a
    ld   a, 127
    ld   (spin_cos), a

    xor  a
    ld   (sprite_mode), a

    ld   hl, letter_shapes
    ld   (dar_shapes), hl
    ld   hl, rest_pos
    ld   (dar_pos), hl
    ld   hl, orb_phase
    ld   (orb_phase_ptr), hl

    ld   b, 19
dof_loop:
    push bc

    ; Load this letter's rest position
    ld   hl, (dar_pos)
    ld   a, (hl)
    ld   (orb_rest_cx), a
    inc  hl
    ld   a, (hl)
    ld   (orb_rest_cy), a
    inc  hl
    ld   (dar_pos), hl

    ; orbit_angle = (orb_base_angle + orb_phase[letter]) & 255
    ld   hl, (orb_phase_ptr)
    ld   a, (hl)
    inc  hl
    ld   (orb_phase_ptr), hl
    ld   c, a                ; C = orb_phase[letter]
    ld   a, (orb_base_angle)
    add  a, c                ; 8-bit add wraps naturally to &255
    ld   c, a                ; C = orbit_angle

    ; orb_sin = sin_tab[orbit_angle]
    ld   l, a
    ld   h, 0
    ld   de, sin_tab
    add  hl, de
    ld   a, (hl)
    ld   (orb_sin), a

    ; orb_cos = sin_tab[(orbit_angle + 64) & 255]
    ld   a, c
    add  a, 64
    ld   l, a
    ld   h, 0
    ld   de, sin_tab
    add  hl, de
    ld   a, (hl)
    ld   (orb_cos), a

    ; orbit_cx = rest_cx + (radius * orb_cos) >> 7
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
    or   c               ; A = orbit_delta_x (signed, now in unsigned byte)
    ld   d, a
    ld   a, (orb_rest_cx)
    add  a, d
    ld   (spin_cx), a

    ; orbit_cy = rest_cy + (radius * orb_sin) >> 7
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
    or   c               ; A = orbit_delta_y
    ld   d, a
    ld   a, (orb_rest_cy)
    add  a, d
    ld   (spin_cy), a

    call draw_rot_letter

    pop  bc
    djnz dof_loop

    ; Advance base angle by 2 per display frame (~1.2 full orbits in 150 frames)
    ld   a, (orb_base_angle)
    add  a, 2
    ld   (orb_base_angle), a

    ret
