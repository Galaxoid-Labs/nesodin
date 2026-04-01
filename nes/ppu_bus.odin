package nes

import "mappers"

// PPU internal bus: pattern tables, nametables, palettes

// Get the effective mirror mode (mapper may override cartridge default)
ppu_effective_mirror :: proc(ppu: ^PPU) -> mappers.Mirror_Mode {
	mode, is_dynamic := mappers.mapper_mirror_mode(&ppu.cartridge.mapper)
	if is_dynamic {
		return mode
	}
	return ppu.cartridge.mirror_mode
}

ppu_bus_read :: proc(ppu: ^PPU, addr: u16) -> u8 {
	addr := addr & 0x3FFF

	switch {
	case addr <= 0x1FFF:
		data, _ := mappers.mapper_ppu_read(&ppu.cartridge.mapper, addr)
		return data

	case addr <= 0x3EFF:
		return ppu.vram[ppu_mirror_nametable(ppu_effective_mirror(ppu), addr)]

	case addr <= 0x3FFF:
		return ppu.palette[ppu_mirror_palette(addr)]
	}
	return 0
}

ppu_bus_write :: proc(ppu: ^PPU, addr: u16, val: u8) {
	addr := addr & 0x3FFF

	switch {
	case addr <= 0x1FFF:
		mappers.mapper_ppu_write(&ppu.cartridge.mapper, addr, val)

	case addr <= 0x3EFF:
		ppu.vram[ppu_mirror_nametable(ppu_effective_mirror(ppu), addr)] = val

	case addr <= 0x3FFF:
		ppu.palette[ppu_mirror_palette(addr)] = val
	}
}

// Convert a nametable address ($2000-$2FFF) to a VRAM index (0-2047)
ppu_mirror_nametable :: proc(mode: mappers.Mirror_Mode, addr: u16) -> u16 {
	a := (addr - 0x2000) & 0x0FFF // Remove $2000 base, wrap at $1000
	table := a / 0x0400            // Which nametable (0-3)
	offset := a & 0x03FF           // Offset within table

	switch mode {
	case .Horizontal:
		// Tables 0,1 → page 0; tables 2,3 → page 1
		return (table / 2) * 0x0400 + offset
	case .Vertical:
		// Tables 0,2 → page 0; tables 1,3 → page 1
		return (table & 1) * 0x0400 + offset
	case .Single_Screen_Low:
		return offset
	case .Single_Screen_High:
		return 0x0400 + offset
	case .Four_Screen:
		return a
	}
	return 0
}

// Mirror palette addresses
// $3F10/$3F14/$3F18/$3F1C mirror $3F00/$3F04/$3F08/$3F0C
ppu_mirror_palette :: proc(addr: u16) -> u16 {
	idx := (addr - 0x3F00) & 0x1F
	// Mirror sprite bg colors to universal bg color
	if idx == 0x10 || idx == 0x14 || idx == 0x18 || idx == 0x1C {
		return idx - 0x10
	}
	return idx
}
