package mappers

// AxROM (Mapper 007)
// Games: Battletoads, Marble Madness, RC Pro-Am, Wizards & Warriors
// 32KB PRG bank switching, single-screen mirroring select, CHR RAM

Mapper_007 :: struct {
	prg_rom:     []u8,
	chr:         []u8,
	has_chr_ram: bool,
	prg_banks:   u8,     // In 32KB units
	bank_select: u8,
	mirror_mode: Mirror_Mode,
}

mapper_007_init :: proc(prg_rom: []u8, chr: []u8, prg_banks_16k: u8, has_chr_ram: bool) -> Mapper_007 {
	return Mapper_007{
		prg_rom     = prg_rom,
		chr         = chr,
		has_chr_ram = has_chr_ram,
		prg_banks   = prg_banks_16k / 2, // Convert to 32KB units
		mirror_mode = .Single_Screen_Low,
	}
}

mapper_007_cpu_read :: proc(m: ^Mapper_007, addr: u16) -> (data: u8, ok: bool) {
	if addr >= 0x8000 {
		idx := u32(m.bank_select) * 32768 + u32(addr - 0x8000)
		if idx < u32(len(m.prg_rom)) { return m.prg_rom[idx], true }
	}
	return 0, false
}

mapper_007_cpu_write :: proc(m: ^Mapper_007, addr: u16, val: u8) -> bool {
	if addr >= 0x8000 {
		m.bank_select = val & 0x07
		if (val & 0x10) != 0 {
			m.mirror_mode = .Single_Screen_High
		} else {
			m.mirror_mode = .Single_Screen_Low
		}
		return true
	}
	return false
}

mapper_007_ppu_read :: proc(m: ^Mapper_007, addr: u16) -> (data: u8, ok: bool) {
	if addr <= 0x1FFF {
		return m.chr[addr], true
	}
	return 0, false
}

mapper_007_ppu_write :: proc(m: ^Mapper_007, addr: u16, val: u8) -> bool {
	if addr <= 0x1FFF && m.has_chr_ram {
		m.chr[addr] = val
		return true
	}
	return false
}

mapper_007_mirror :: proc(m: ^Mapper_007) -> Mirror_Mode {
	return m.mirror_mode
}
