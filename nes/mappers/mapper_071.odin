package mappers

// Camerica/Codemasters (Mapper 071)
// Games: Micro Machines, Fire Hawk, Bee 52, Big Nose
// 16KB switchable PRG + 16KB fixed last bank, optional single-screen mirroring

Mapper_071 :: struct {
	prg_rom:      []u8,
	chr:          []u8,
	has_chr_ram:  bool,
	prg_banks:    u8,
	bank_select:  u8,
	mirror_mode:  Mirror_Mode,
	has_mirror_ctrl: bool,
}

mapper_071_init :: proc(prg_rom: []u8, chr: []u8, prg_banks: u8, has_chr_ram: bool, mirror: Mirror_Mode) -> Mapper_071 {
	return Mapper_071{
		prg_rom     = prg_rom,
		chr         = chr,
		has_chr_ram = has_chr_ram,
		prg_banks   = prg_banks,
		mirror_mode = mirror,
	}
}

mapper_071_cpu_read :: proc(m: ^Mapper_071, addr: u16) -> (data: u8, ok: bool) {
	switch {
	case addr >= 0x8000 && addr <= 0xBFFF:
		idx := u32(m.bank_select) * 16384 + u32(addr - 0x8000)
		if idx < u32(len(m.prg_rom)) { return m.prg_rom[idx], true }
	case addr >= 0xC000:
		last := u32(m.prg_banks - 1)
		idx := last * 16384 + u32(addr - 0xC000)
		if idx < u32(len(m.prg_rom)) { return m.prg_rom[idx], true }
	}
	return 0, false
}

mapper_071_cpu_write :: proc(m: ^Mapper_071, addr: u16, val: u8) -> bool {
	switch {
	case addr >= 0x9000 && addr <= 0x9FFF:
		// Mirroring control (Codemasters variant)
		if (val & 0x10) != 0 {
			m.mirror_mode = .Single_Screen_High
		} else {
			m.mirror_mode = .Single_Screen_Low
		}
		m.has_mirror_ctrl = true
		return true
	case addr >= 0xC000:
		m.bank_select = val & 0x0F
		return true
	}
	return false
}

mapper_071_ppu_read :: proc(m: ^Mapper_071, addr: u16) -> (data: u8, ok: bool) {
	if addr <= 0x1FFF {
		return m.chr[addr], true
	}
	return 0, false
}

mapper_071_ppu_write :: proc(m: ^Mapper_071, addr: u16, val: u8) -> bool {
	if addr <= 0x1FFF && m.has_chr_ram {
		m.chr[addr] = val
		return true
	}
	return false
}

mapper_071_mirror :: proc(m: ^Mapper_071) -> Mirror_Mode {
	return m.mirror_mode
}
