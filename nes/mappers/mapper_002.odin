package mappers

// UxROM (Mapper 002)
// Games: Castlevania, Contra, DuckTales, Mega Man
// Simple PRG bank switching (16KB switchable + 16KB fixed last bank)
// Fixed CHR (8KB, usually RAM)

Mapper_002 :: struct {
	prg_rom:     []u8,
	chr:         []u8,
	has_chr_ram: bool,
	prg_banks:   u8,
	bank_select: u8,
}

mapper_002_init :: proc(prg_rom: []u8, chr: []u8, prg_banks: u8, has_chr_ram: bool) -> Mapper_002 {
	return Mapper_002{
		prg_rom     = prg_rom,
		chr         = chr,
		has_chr_ram = has_chr_ram,
		prg_banks   = prg_banks,
	}
}

mapper_002_cpu_read :: proc(m: ^Mapper_002, addr: u16) -> (data: u8, ok: bool) {
	switch {
	case addr >= 0x8000 && addr <= 0xBFFF:
		// Switchable bank
		idx := u32(m.bank_select) * 16384 + u32(addr - 0x8000)
		if idx < u32(len(m.prg_rom)) { return m.prg_rom[idx], true }
	case addr >= 0xC000:
		// Fixed last bank
		last := u32(m.prg_banks - 1)
		idx := last * 16384 + u32(addr - 0xC000)
		if idx < u32(len(m.prg_rom)) { return m.prg_rom[idx], true }
	}
	return 0, false
}

mapper_002_cpu_write :: proc(m: ^Mapper_002, addr: u16, val: u8) -> bool {
	if addr >= 0x8000 {
		m.bank_select = val & 0x0F
		return true
	}
	return false
}

mapper_002_ppu_read :: proc(m: ^Mapper_002, addr: u16) -> (data: u8, ok: bool) {
	if addr <= 0x1FFF {
		return m.chr[addr], true
	}
	return 0, false
}

mapper_002_ppu_write :: proc(m: ^Mapper_002, addr: u16, val: u8) -> bool {
	if addr <= 0x1FFF && m.has_chr_ram {
		m.chr[addr] = val
		return true
	}
	return false
}
