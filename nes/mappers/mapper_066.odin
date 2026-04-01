package mappers

// GxROM (Mapper 066)
// Games: SMB + Duck Hunt, Dragon Power, Super Mario Bros / Tetris / World Cup
// Simple PRG (32KB) + CHR (8KB) bank switching

Mapper_066 :: struct {
	prg_rom:   []u8,
	chr:       []u8,
	prg_banks: u8,     // In 32KB units
	prg_bank:  u8,
	chr_bank:  u8,
}

mapper_066_init :: proc(prg_rom: []u8, chr: []u8, prg_banks_16k: u8) -> Mapper_066 {
	return Mapper_066{
		prg_rom   = prg_rom,
		chr       = chr,
		prg_banks = prg_banks_16k / 2,
	}
}

mapper_066_cpu_read :: proc(m: ^Mapper_066, addr: u16) -> (data: u8, ok: bool) {
	if addr >= 0x8000 {
		idx := u32(m.prg_bank) * 32768 + u32(addr - 0x8000)
		if idx < u32(len(m.prg_rom)) { return m.prg_rom[idx], true }
	}
	return 0, false
}

mapper_066_cpu_write :: proc(m: ^Mapper_066, addr: u16, val: u8) -> bool {
	if addr >= 0x8000 {
		m.chr_bank = val & 0x03
		m.prg_bank = (val >> 4) & 0x03
		return true
	}
	return false
}

mapper_066_ppu_read :: proc(m: ^Mapper_066, addr: u16) -> (data: u8, ok: bool) {
	if addr <= 0x1FFF {
		idx := u32(m.chr_bank) * 8192 + u32(addr)
		if idx < u32(len(m.chr)) { return m.chr[idx], true }
		return 0, true
	}
	return 0, false
}

mapper_066_ppu_write :: proc(m: ^Mapper_066, addr: u16, val: u8) -> bool {
	return false
}
