package mappers

// MMC4 (Mapper 010) — FxROM
// Games: Fire Emblem (JP), Famicom Wars
// Like MMC2 but with 16KB switchable PRG instead of 8KB
// Same CHR latch mechanism as MMC2

Mapper_010 :: struct {
	prg_rom:     []u8,
	chr_rom:     []u8,
	prg_ram:     [8192]u8,
	prg_banks:   u8,    // In 16KB units

	prg_bank:    u8,    // 16KB switchable at $8000-$BFFF

	chr_bank_0_fd: u8,
	chr_bank_0_fe: u8,
	chr_bank_1_fd: u8,
	chr_bank_1_fe: u8,

	latch_0:     bool,  // false = $FD, true = $FE
	latch_1:     bool,

	mirror_mode: Mirror_Mode,
}

mapper_010_init :: proc(prg_rom: []u8, chr_rom: []u8, prg_banks: u8, mirror: Mirror_Mode) -> Mapper_010 {
	return Mapper_010{
		prg_rom     = prg_rom,
		chr_rom     = chr_rom,
		prg_banks   = prg_banks,
		mirror_mode = mirror,
		latch_0     = true,
		latch_1     = true,
	}
}

mapper_010_cpu_read :: proc(m: ^Mapper_010, addr: u16) -> (data: u8, ok: bool) {
	switch {
	case addr >= 0x6000 && addr <= 0x7FFF:
		return m.prg_ram[addr - 0x6000], true
	case addr >= 0x8000 && addr <= 0xBFFF:
		// Switchable 16KB bank
		idx := u32(m.prg_bank) * 16384 + u32(addr - 0x8000)
		if idx < u32(len(m.prg_rom)) { return m.prg_rom[idx], true }
	case addr >= 0xC000:
		// Fixed last 16KB bank
		last := u32(m.prg_banks - 1)
		idx := last * 16384 + u32(addr - 0xC000)
		if idx < u32(len(m.prg_rom)) { return m.prg_rom[idx], true }
	}
	return 0, false
}

mapper_010_cpu_write :: proc(m: ^Mapper_010, addr: u16, val: u8) -> bool {
	switch {
	case addr >= 0x6000 && addr <= 0x7FFF:
		m.prg_ram[addr - 0x6000] = val
		return true
	case addr >= 0xA000 && addr <= 0xAFFF:
		m.prg_bank = val & 0x0F
	case addr >= 0xB000 && addr <= 0xBFFF:
		m.chr_bank_0_fd = val & 0x1F
	case addr >= 0xC000 && addr <= 0xCFFF:
		m.chr_bank_0_fe = val & 0x1F
	case addr >= 0xD000 && addr <= 0xDFFF:
		m.chr_bank_1_fd = val & 0x1F
	case addr >= 0xE000 && addr <= 0xEFFF:
		m.chr_bank_1_fe = val & 0x1F
	case addr >= 0xF000:
		m.mirror_mode = .Horizontal if (val & 0x01) != 0 else .Vertical
	case:
		return false
	}
	return true
}

mapper_010_ppu_read :: proc(m: ^Mapper_010, addr: u16) -> (data: u8, ok: bool) {
	if addr > 0x1FFF { return 0, false }

	bank: u8
	if addr < 0x1000 {
		bank = m.chr_bank_0_fe if m.latch_0 else m.chr_bank_0_fd
		idx := u32(bank) * 4096 + u32(addr)
		result: u8 = 0
		if idx < u32(len(m.chr_rom)) { result = m.chr_rom[idx] }

		if addr >= 0x0FD8 && addr <= 0x0FDF { m.latch_0 = false }
		if addr >= 0x0FE8 && addr <= 0x0FEF { m.latch_0 = true }

		return result, true
	} else {
		bank = m.chr_bank_1_fe if m.latch_1 else m.chr_bank_1_fd
		idx := u32(bank) * 4096 + u32(addr - 0x1000)
		result: u8 = 0
		if idx < u32(len(m.chr_rom)) { result = m.chr_rom[idx] }

		if addr >= 0x1FD8 && addr <= 0x1FDF { m.latch_1 = false }
		if addr >= 0x1FE8 && addr <= 0x1FEF { m.latch_1 = true }

		return result, true
	}
}

mapper_010_ppu_write :: proc(m: ^Mapper_010, addr: u16, val: u8) -> bool {
	return false
}

mapper_010_mirror :: proc(m: ^Mapper_010) -> Mirror_Mode {
	return m.mirror_mode
}
