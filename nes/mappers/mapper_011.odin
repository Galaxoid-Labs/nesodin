package mappers

// Color Dreams (Mapper 011)
// Games: Bible Adventures, Crystal Mines, Wisdom Tree titles
// Simple PRG (32KB) + CHR (8KB) bank switching via single register

Mapper_011 :: struct {
	prg_rom:   []u8,
	chr:       []u8,
	prg_banks: u8,     // In 32KB units
	prg_bank:  u8,
	chr_bank:  u8,
}

mapper_011_init :: proc(prg_rom: []u8, chr: []u8, prg_banks_16k: u8) -> Mapper_011 {
	return Mapper_011{
		prg_rom   = prg_rom,
		chr       = chr,
		prg_banks = prg_banks_16k / 2,
	}
}

mapper_011_cpu_read :: proc(m: ^Mapper_011, addr: u16) -> (data: u8, ok: bool) {
	if addr >= 0x8000 {
		idx := u32(m.prg_bank) * 32768 + u32(addr - 0x8000)
		if idx < u32(len(m.prg_rom)) { return m.prg_rom[idx], true }
	}
	return 0, false
}

mapper_011_cpu_write :: proc(m: ^Mapper_011, addr: u16, val: u8) -> bool {
	if addr >= 0x8000 {
		m.prg_bank = val & 0x03
		m.chr_bank = (val >> 4) & 0x0F
		return true
	}
	return false
}

mapper_011_ppu_read :: proc(m: ^Mapper_011, addr: u16) -> (data: u8, ok: bool) {
	if addr <= 0x1FFF {
		idx := u32(m.chr_bank) * 8192 + u32(addr)
		if idx < u32(len(m.chr)) { return m.chr[idx], true }
		return 0, true
	}
	return 0, false
}

mapper_011_ppu_write :: proc(m: ^Mapper_011, addr: u16, val: u8) -> bool {
	return false
}
