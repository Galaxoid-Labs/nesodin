package mappers

// CNROM (Mapper 003)
// Games: Arkanoid, Solomon's Key
// Simple CHR bank switching, fixed PRG

Mapper_003 :: struct {
	prg_rom:   []u8,
	chr:       []u8,
	prg_banks: u8,
	bank_select: u8,
}

mapper_003_init :: proc(prg_rom: []u8, chr: []u8, prg_banks: u8) -> Mapper_003 {
	return Mapper_003{
		prg_rom   = prg_rom,
		chr       = chr,
		prg_banks = prg_banks,
	}
}

mapper_003_cpu_read :: proc(m: ^Mapper_003, addr: u16) -> (data: u8, ok: bool) {
	if addr >= 0x8000 {
		mapped := addr - 0x8000
		if m.prg_banks == 1 {
			mapped &= 0x3FFF
		}
		return m.prg_rom[mapped], true
	}
	return 0, false
}

mapper_003_cpu_write :: proc(m: ^Mapper_003, addr: u16, val: u8) -> bool {
	if addr >= 0x8000 {
		m.bank_select = val & 0x03
		return true
	}
	return false
}

mapper_003_ppu_read :: proc(m: ^Mapper_003, addr: u16) -> (data: u8, ok: bool) {
	if addr <= 0x1FFF {
		idx := u32(m.bank_select) * 8192 + u32(addr)
		if idx < u32(len(m.chr)) {
			return m.chr[idx], true
		}
		return 0, true
	}
	return 0, false
}

mapper_003_ppu_write :: proc(m: ^Mapper_003, addr: u16, val: u8) -> bool {
	return false // CHR ROM only
}
