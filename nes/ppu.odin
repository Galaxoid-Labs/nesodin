package nes

import "mappers"

PPU :: struct {
	// Registers (directly mapped to $2000-$2007)
	ctrl:     u8,  // $2000 PPUCTRL
	mask:     u8,  // $2001 PPUMASK
	status:   u8,  // $2002 PPUSTATUS
	oam_addr: u8,  // $2003 OAMADDR

	// Internal state
	v:      u16,  // Current VRAM address (15 bits)
	t:      u16,  // Temporary VRAM address (15 bits)
	x_fine: u8,   // Fine X scroll (3 bits)
	w:      bool, // Write toggle (first/second write)

	// Memory
	vram:          [2048]u8,  // 2KB nametable RAM
	palette:       [32]u8,   // Palette RAM
	oam:           [256]u8,  // Primary OAM (64 sprites x 4 bytes)
	secondary_oam: [32]u8,   // Secondary OAM (8 sprites for current scanline)

	// Rendering
	scanline:    i16,            // Current scanline (-1 to 260)
	cycle:       u16,            // Current cycle within scanline (0 to 340)
	frame:       u64,            // Frame counter
	frame_ready: bool,           // Set when a frame is complete
	framebuffer: [256 * 240]u32, // RGBA output

	// Shift registers & latches for background rendering
	bg_shift_pattern_lo: u16,
	bg_shift_pattern_hi: u16,
	bg_shift_attrib_lo:  u16,
	bg_shift_attrib_hi:  u16,
	bg_next_tile_id:     u8,
	bg_next_tile_attrib: u8,
	bg_next_tile_lo:     u8,
	bg_next_tile_hi:     u8,

	// Sprite rendering state
	sprite_count:        u8,     // Sprites found for current scanline
	sprite_patterns_lo:  [8]u8,  // Pattern data for up to 8 sprites
	sprite_patterns_hi:  [8]u8,
	sprite_positions:    [8]u8,  // X positions
	sprite_palettes:     [8]u8,  // Palette indices (4-7)
	sprite_priorities:   [8]u8,  // Priority bits
	sprite_indices:      [8]u8,  // Original OAM indices (for sprite 0 detection)

	nmi_occurred: bool,
	nmi_output:   bool,
	suppress_vbl: bool,

	// Data read buffer for $2007
	data_buffer: u8,

	// Reference to cartridge for pattern table reads
	cartridge: ^Cartridge,

	// NMI line signal to CPU
	nmi_pending: bool,

	// Previous NMI line state for edge detection
	nmi_previous: bool,
}

ppu_init :: proc(ppu: ^PPU, cart: ^Cartridge) {
	ppu.cartridge = cart
	ppu.scanline = -1
	ppu.cycle = 0
}

// Helper: is rendering enabled?
ppu_rendering_enabled :: proc(ppu: ^PPU) -> bool {
	return (ppu.mask & 0x18) != 0 // Show BG or sprites
}

ppu_show_bg :: proc(ppu: ^PPU) -> bool {
	return (ppu.mask & 0x08) != 0
}

ppu_show_sprites :: proc(ppu: ^PPU) -> bool {
	return (ppu.mask & 0x10) != 0
}

ppu_show_bg_left :: proc(ppu: ^PPU) -> bool {
	return (ppu.mask & 0x02) != 0
}

ppu_show_sprites_left :: proc(ppu: ^PPU) -> bool {
	return (ppu.mask & 0x04) != 0
}

ppu_sprite_height :: proc(ppu: ^PPU) -> u16 {
	return 16 if (ppu.ctrl & 0x20) != 0 else 8
}

// CPU reads from PPU registers ($2000-$2007)
ppu_cpu_read :: proc(ppu: ^PPU, addr: u16) -> u8 {
	switch addr {
	case 0x2002: // PPUSTATUS
		result := (ppu.status & 0xE0) | (ppu.data_buffer & 0x1F)
		ppu.status &= 0x7F // Clear vblank flag
		ppu.nmi_occurred = false
		ppu_nmi_change(ppu)
		ppu.w = false       // Reset write toggle
		return result

	case 0x2004: // OAMDATA
		return ppu.oam[ppu.oam_addr]

	case 0x2007: // PPUDATA
		data := ppu_bus_read(ppu, ppu.v)
		if ppu.v & 0x3FFF < 0x3F00 {
			buffered := ppu.data_buffer
			ppu.data_buffer = data
			data = buffered
		} else {
			ppu.data_buffer = ppu_bus_read(ppu, ppu.v - 0x1000)
		}
		ppu.v += 1 if (ppu.ctrl & 0x04) == 0 else 32
		return data
	}
	return 0
}

// CPU writes to PPU registers ($2000-$2007)
ppu_cpu_write :: proc(ppu: ^PPU, addr: u16, val: u8) {
	switch addr {
	case 0x2000: // PPUCTRL
		ppu.ctrl = val
		ppu.nmi_output = (val & 0x80) != 0
		ppu.t = (ppu.t & 0xF3FF) | (u16(val & 0x03) << 10)
		ppu_nmi_change(ppu)

	case 0x2001: // PPUMASK
		ppu.mask = val

	case 0x2003: // OAMADDR
		ppu.oam_addr = val

	case 0x2004: // OAMDATA
		ppu.oam[ppu.oam_addr] = val
		ppu.oam_addr += 1

	case 0x2005: // PPUSCROLL
		if !ppu.w {
			ppu.t = (ppu.t & 0xFFE0) | (u16(val) >> 3)
			ppu.x_fine = val & 0x07
			ppu.w = true
		} else {
			ppu.t = (ppu.t & 0x8C1F) |
				(u16(val & 0x07) << 12) |
				(u16(val & 0xF8) << 2)
			ppu.w = false
		}

	case 0x2006: // PPUADDR
		if !ppu.w {
			ppu.t = (ppu.t & 0x00FF) | (u16(val & 0x3F) << 8)
			ppu.w = true
		} else {
			ppu.t = (ppu.t & 0xFF00) | u16(val)
			ppu.v = ppu.t
			ppu.w = false
		}

	case 0x2007: // PPUDATA
		ppu_bus_write(ppu, ppu.v, val)
		ppu.v += 1 if (ppu.ctrl & 0x04) == 0 else 32
	}
}

// OAM DMA: copy 256 bytes from CPU memory page to OAM
ppu_oam_dma :: proc(ppu: ^PPU, bus: ^Bus, page: u8) {
	base := u16(page) << 8
	for i in u16(0)..<256 {
		ppu.oam[ppu.oam_addr] = bus_read(bus, base + i)
		ppu.oam_addr += 1
	}
}

// NMI edge detection
ppu_nmi_change :: proc(ppu: ^PPU) {
	nmi := ppu.nmi_output && ppu.nmi_occurred
	if nmi && !ppu.nmi_previous {
		ppu.nmi_pending = true
	}
	ppu.nmi_previous = nmi
}

// ---- Scrolling helpers ----

// Increment coarse X (tile column) in v
ppu_increment_x :: proc(ppu: ^PPU) {
	if (ppu.v & 0x001F) == 31 {
		ppu.v &= ~u16(0x001F) // Coarse X = 0
		ppu.v ~= 0x0400       // Switch horizontal nametable
	} else {
		ppu.v += 1
	}
}

// Increment fine Y (pixel row) in v
ppu_increment_y :: proc(ppu: ^PPU) {
	if (ppu.v & 0x7000) != 0x7000 {
		ppu.v += 0x1000 // Fine Y < 7, increment
	} else {
		ppu.v &= ~u16(0x7000) // Fine Y = 0
		y := (ppu.v & 0x03E0) >> 5 // Coarse Y
		if y == 29 {
			y = 0
			ppu.v ~= 0x0800 // Switch vertical nametable
		} else if y == 31 {
			y = 0 // Reset without switching nametable
		} else {
			y += 1
		}
		ppu.v = (ppu.v & ~u16(0x03E0)) | (y << 5)
	}
}

// Copy horizontal position bits from t to v
ppu_copy_x :: proc(ppu: ^PPU) {
	// v: ....A.. ...BCDEF = t: ....A.. ...BCDEF
	ppu.v = (ppu.v & 0xFBE0) | (ppu.t & 0x041F)
}

// Copy vertical position bits from t to v
ppu_copy_y :: proc(ppu: ^PPU) {
	// v: GHIA.BC DEF..... = t: GHIA.BC DEF.....
	ppu.v = (ppu.v & 0x841F) | (ppu.t & 0x7BE0)
}

// ---- Background rendering ----

// Load data into the shift registers for the next tile
ppu_load_bg_shifters :: proc(ppu: ^PPU) {
	ppu.bg_shift_pattern_lo = (ppu.bg_shift_pattern_lo & 0xFF00) | u16(ppu.bg_next_tile_lo)
	ppu.bg_shift_pattern_hi = (ppu.bg_shift_pattern_hi & 0xFF00) | u16(ppu.bg_next_tile_hi)

	// Expand attribute bits into the shift register (fill lower 8 bits)
	if (ppu.bg_next_tile_attrib & 0x01) != 0 {
		ppu.bg_shift_attrib_lo = (ppu.bg_shift_attrib_lo & 0xFF00) | 0xFF
	} else {
		ppu.bg_shift_attrib_lo = (ppu.bg_shift_attrib_lo & 0xFF00)
	}
	if (ppu.bg_next_tile_attrib & 0x02) != 0 {
		ppu.bg_shift_attrib_hi = (ppu.bg_shift_attrib_hi & 0xFF00) | 0xFF
	} else {
		ppu.bg_shift_attrib_hi = (ppu.bg_shift_attrib_hi & 0xFF00)
	}
}

// Shift all background shift registers by one bit
ppu_update_shifters :: proc(ppu: ^PPU) {
	if ppu_show_bg(ppu) {
		ppu.bg_shift_pattern_lo <<= 1
		ppu.bg_shift_pattern_hi <<= 1
		ppu.bg_shift_attrib_lo <<= 1
		ppu.bg_shift_attrib_hi <<= 1
	}
}

// Fetch background tile data (called at specific cycles)
ppu_fetch_bg :: proc(ppu: ^PPU) {
	switch ppu.cycle & 0x07 {
	case 1:
		// Load shifters at the start of each tile fetch cycle
		ppu_load_bg_shifters(ppu)
		// Nametable byte
		ppu.bg_next_tile_id = ppu_bus_read(ppu, 0x2000 | (ppu.v & 0x0FFF))

	case 3:
		// Attribute byte
		attr_addr := u16(0x23C0) | (ppu.v & 0x0C00) |
			((ppu.v >> 4) & 0x38) | ((ppu.v >> 2) & 0x07)
		attrib := ppu_bus_read(ppu, attr_addr)
		if (ppu.v >> 5) & 0x02 != 0 { attrib >>= 4 }
		if ppu.v & 0x02 != 0 { attrib >>= 2 }
		ppu.bg_next_tile_attrib = attrib & 0x03

	case 5:
		// Pattern table tile low byte
		fine_y := (ppu.v >> 12) & 0x07
		bg_table := u16(ppu.ctrl & 0x10) << 8 // 0x0000 or 0x1000
		tile_addr := bg_table + u16(ppu.bg_next_tile_id) * 16 + fine_y
		ppu.bg_next_tile_lo = ppu_bus_read(ppu, tile_addr)

	case 7:
		// Pattern table tile high byte
		fine_y := (ppu.v >> 12) & 0x07
		bg_table := u16(ppu.ctrl & 0x10) << 8
		tile_addr := bg_table + u16(ppu.bg_next_tile_id) * 16 + fine_y + 8
		ppu.bg_next_tile_hi = ppu_bus_read(ppu, tile_addr)
		// Increment coarse X after loading the complete tile
		ppu_increment_x(ppu)
	}
}

// ---- Sprite evaluation & rendering ----

// Evaluate which sprites are visible on the current scanline
ppu_evaluate_sprites :: proc(ppu: ^PPU) {
	h := ppu_sprite_height(ppu)
	ppu.sprite_count = 0

	for i in u16(0)..<64 {
		oam_idx := i * 4
		y := ppu.oam[oam_idx]
		row := i16(ppu.scanline) - i16(y)
		if row < 0 || row >= i16(h) { continue }

		if ppu.sprite_count < 8 {
			n := ppu.sprite_count
			tile_index := ppu.oam[oam_idx + 1]
			attributes := ppu.oam[oam_idx + 2]
			sprite_x := ppu.oam[oam_idx + 3]

			flip_v := (attributes & 0x80) != 0
			flip_h := (attributes & 0x40) != 0

			// Compute the actual row within the tile, accounting for vertical flip
			actual_row := u16(row)
			if flip_v {
				actual_row = h - 1 - u16(row)
			}

			// Fetch pattern data
			pattern_addr: u16
			if h == 16 {
				// 8x16 sprites: tile index bit 0 selects pattern table
				table := u16(tile_index & 0x01) * 0x1000
				tile := u16(tile_index & 0xFE)
				if actual_row >= 8 {
					tile += 1
					actual_row -= 8
				}
				pattern_addr = table + tile * 16 + actual_row
			} else {
				// 8x8 sprites
				table := u16(ppu.ctrl & 0x08) << 9 // Bit 3 → 0x0000 or 0x1000
				pattern_addr = table + u16(tile_index) * 16 + actual_row
			}

			lo := ppu_bus_read(ppu, pattern_addr)
			hi := ppu_bus_read(ppu, pattern_addr + 8)

			// Horizontal flip
			if flip_h {
				lo = reverse_byte(lo)
				hi = reverse_byte(hi)
			}

			ppu.sprite_patterns_lo[n] = lo
			ppu.sprite_patterns_hi[n] = hi
			ppu.sprite_positions[n] = sprite_x
			ppu.sprite_palettes[n] = (attributes & 0x03) + 4
			ppu.sprite_priorities[n] = (attributes >> 5) & 0x01
			ppu.sprite_indices[n] = u8(i)
			ppu.sprite_count += 1
		} else {
			// More than 8 sprites — set overflow flag
			ppu.status |= 0x20
			break
		}
	}
}

// Reverse bits in a byte (for horizontal sprite flip)
reverse_byte :: proc(b: u8) -> u8 {
	b := b
	b = (b & 0xF0) >> 4 | (b & 0x0F) << 4
	b = (b & 0xCC) >> 2 | (b & 0x33) << 2
	b = (b & 0xAA) >> 1 | (b & 0x55) << 1
	return b
}

// ---- Pixel output ----

ppu_render_pixel :: proc(ppu: ^PPU) {
	x := ppu.cycle - 1  // Cycle 1 = pixel 0
	y := ppu.scanline

	// Background pixel
	bg_pixel: u8 = 0
	bg_palette: u8 = 0

	if ppu_show_bg(ppu) {
		if ppu_show_bg_left(ppu) || x >= 8 {
			bit_select := u16(0x8000) >> ppu.x_fine
			p0: u8 = 1 if (ppu.bg_shift_pattern_lo & bit_select) != 0 else 0
			p1: u8 = 1 if (ppu.bg_shift_pattern_hi & bit_select) != 0 else 0
			bg_pixel = (p1 << 1) | p0

			a0: u8 = 1 if (ppu.bg_shift_attrib_lo & bit_select) != 0 else 0
			a1: u8 = 1 if (ppu.bg_shift_attrib_hi & bit_select) != 0 else 0
			bg_palette = (a1 << 1) | a0
		}
	}

	// Sprite pixel
	spr_pixel: u8 = 0
	spr_palette: u8 = 0
	spr_priority: u8 = 0
	is_sprite_zero := false

	if ppu_show_sprites(ppu) {
		if ppu_show_sprites_left(ppu) || x >= 8 {
			for i in u8(0)..<ppu.sprite_count {
				offset := x - u16(ppu.sprite_positions[i])
				if offset >= 8 { continue } // Not in range

				bit := u8(7 - offset)
				p0: u8 = (ppu.sprite_patterns_lo[i] >> bit) & 0x01
				p1: u8 = (ppu.sprite_patterns_hi[i] >> bit) & 0x01
				pixel := (p1 << 1) | p0

				if pixel == 0 { continue } // Transparent

				spr_pixel = pixel
				spr_palette = ppu.sprite_palettes[i]
				spr_priority = ppu.sprite_priorities[i]
				is_sprite_zero = (ppu.sprite_indices[i] == 0)
				break // First non-transparent sprite wins
			}
		}
	}

	// Sprite 0 hit detection
	if is_sprite_zero && bg_pixel != 0 && spr_pixel != 0 {
		if ppu_show_bg(ppu) && ppu_show_sprites(ppu) {
			// Not at x=255, and not if clipping is on at x<8
			left_clip := !(ppu_show_bg_left(ppu) && ppu_show_sprites_left(ppu))
			if !(left_clip && x < 8) && x != 255 {
				ppu.status |= 0x40 // Set sprite 0 hit
			}
		}
	}

	// Priority multiplexer
	final_pixel: u8 = 0
	final_palette: u8 = 0

	if bg_pixel == 0 && spr_pixel == 0 {
		// Both transparent → background color
	} else if bg_pixel == 0 && spr_pixel != 0 {
		final_pixel = spr_pixel
		final_palette = spr_palette
	} else if bg_pixel != 0 && spr_pixel == 0 {
		final_pixel = bg_pixel
		final_palette = bg_palette
	} else {
		// Both opaque — priority decides
		if spr_priority == 0 {
			final_pixel = spr_pixel
			final_palette = spr_palette
		} else {
			final_pixel = bg_pixel
			final_palette = bg_palette
		}
	}

	// Look up the NES color index from palette RAM
	color_index := ppu_bus_read(ppu, 0x3F00 + u16(final_palette) * 4 + u16(final_pixel))

	// Hide leftmost 8 pixels when the game masks them (overscan area on real TVs)
	pixel_color: u32
	if x < 8 && !ppu_show_bg_left(ppu) {
		pixel_color = palette_to_rgba(ppu_bus_read(ppu, 0x3F00)) // Universal BG color
	} else {
		pixel_color = palette_to_rgba(color_index)
	}
	ppu.framebuffer[u32(y) * 256 + u32(x)] = pixel_color
}

// ---- Main PPU tick ----

ppu_step :: proc(ppu: ^PPU) {
	rendering := ppu_rendering_enabled(ppu)
	pre_render := ppu.scanline == -1
	visible := ppu.scanline >= 0 && ppu.scanline < 240
	render_line := pre_render || visible
	fetch_cycle := ppu.cycle >= 1 && ppu.cycle <= 256
	prefetch_cycle := ppu.cycle >= 321 && ppu.cycle <= 336

	if rendering {
		// ---- Shift registers + pixel output ----
		if render_line && (fetch_cycle || prefetch_cycle) {
			ppu_update_shifters(ppu)
		}

		// ---- Visible scanlines: output pixels ----
		if visible && fetch_cycle {
			ppu_render_pixel(ppu)
		}

		// ---- Background tile fetches ----
		if render_line && (fetch_cycle || prefetch_cycle) {
			ppu_fetch_bg(ppu)
		}

		// ---- Increment Y at end of visible portion ----
		if render_line && ppu.cycle == 256 {
			ppu_increment_y(ppu)
		}

		// ---- Copy horizontal bits from t to v ----
		if render_line && ppu.cycle == 257 {
			ppu_load_bg_shifters(ppu)
			ppu_copy_x(ppu)
		}

		// ---- Pre-render: copy vertical bits from t to v ----
		if pre_render && ppu.cycle >= 280 && ppu.cycle <= 304 {
			ppu_copy_y(ppu)
		}

		// ---- Odd frame cycle skip ----
		if pre_render && ppu.cycle == 339 && (ppu.frame & 1) == 1 {
			ppu.cycle = 340
		}
	}

	// ---- Sprite evaluation at cycle 257 ----
	// Evaluates sprites for the CURRENT scanline (matching hardware behavior).
	// Must run even when rendering was recently re-enabled.
	if ppu.cycle == 257 {
		if visible {
			ppu_evaluate_sprites(ppu)
		} else {
			ppu.sprite_count = 0
		}
	}

	// ---- Mapper scanline counter (MMC3 IRQ) ----
	if rendering && render_line && ppu.cycle == 260 {
		mappers.mapper_scanline(&ppu.cartridge.mapper)
	}

	// ---- VBlank ----
	if ppu.scanline == 241 && ppu.cycle == 1 {
		ppu.status |= 0x80 // Set vblank flag
		ppu.nmi_occurred = true
		ppu_nmi_change(ppu)
		ppu.frame_ready = true
	}

	// ---- Pre-render scanline: clear flags ----
	if pre_render && ppu.cycle == 1 {
		ppu.status &= 0x1F // Clear vblank, sprite 0 hit, sprite overflow
		ppu.nmi_occurred = false
		ppu_nmi_change(ppu)
	}

	// ---- Advance cycle/scanline counters ----
	ppu.cycle += 1
	if ppu.cycle > 340 {
		ppu.cycle = 0
		ppu.scanline += 1
		if ppu.scanline > 260 {
			ppu.scanline = -1
			ppu.frame += 1
		}
	}
}
