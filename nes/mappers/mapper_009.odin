package mappers

// MMC2 (Mapper 009) — PxROM
// Games: Mike Tyson's Punch-Out!!
// PRG: 8KB switchable + three 8KB fixed banks
// CHR: Two 4KB banks, each with two latches that auto-switch on tile $FD/$FE fetch

Mapper_009 :: struct {
	prg_rom:     []u8,
	chr_rom:     []u8,
	prg_banks:   u8,    // In 8KB units

	prg_bank:    u8,    // 8KB switchable at $8000-$9FFF

	// CHR latches — each 4KB bank has two CHR banks selected by latch state
	chr_bank_0_fd: u8,  // $B000 register
	chr_bank_0_fe: u8,  // $C000 register
	chr_bank_1_fd: u8,  // $D000 register
	chr_bank_1_fe: u8,  // $E000 register

	latch_0:     bool,  // false = $FD selected, true = $FE selected
	latch_1:     bool,

	mirror_mode: Mirror_Mode,
}

mapper_009_init :: proc(prg_rom: []u8, chr_rom: []u8, prg_banks_16k: u8, mirror: Mirror_Mode) -> Mapper_009 {
	return Mapper_009{
		prg_rom     = prg_rom,
		chr_rom     = chr_rom,
		prg_banks   = prg_banks_16k * 2, // Convert to 8KB units
		mirror_mode = mirror,
		latch_0     = true,  // Both latches start at $FE
		latch_1     = true,
	}
}

mapper_009_cpu_read :: proc(m: ^Mapper_009, addr: u16) -> (data: u8, ok: bool) {
	switch {
	case addr >= 0x8000 && addr <= 0x9FFF:
		idx := u32(m.prg_bank) * 8192 + u32(addr - 0x8000)
		if idx < u32(len(m.prg_rom)) { return m.prg_rom[idx], true }
	case addr >= 0xA000 && addr <= 0xBFFF:
		bank := u32(m.prg_banks) - 3
		idx := bank * 8192 + u32(addr - 0xA000)
		if idx < u32(len(m.prg_rom)) { return m.prg_rom[idx], true }
	case addr >= 0xC000 && addr <= 0xDFFF:
		bank := u32(m.prg_banks) - 2
		idx := bank * 8192 + u32(addr - 0xC000)
		if idx < u32(len(m.prg_rom)) { return m.prg_rom[idx], true }
	case addr >= 0xE000:
		bank := u32(m.prg_banks) - 1
		idx := bank * 8192 + u32(addr - 0xE000)
		if idx < u32(len(m.prg_rom)) { return m.prg_rom[idx], true }
	}
	return 0, false
}

mapper_009_cpu_write :: proc(m: ^Mapper_009, addr: u16, val: u8) -> bool {
	switch {
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

mapper_009_ppu_read :: proc(m: ^Mapper_009, addr: u16) -> (data: u8, ok: bool) {
	if addr > 0x1FFF { return 0, false }

	bank: u8
	if addr < 0x1000 {
		// Low CHR bank — selected by latch_0
		bank = m.chr_bank_0_fe if m.latch_0 else m.chr_bank_0_fd
		idx := u32(bank) * 4096 + u32(addr)
		result: u8 = 0
		if idx < u32(len(m.chr_rom)) { result = m.chr_rom[idx] }

		// Update latch AFTER the read based on address range
		// $0FD8-$0FDF → select $FD bank, $0FE8-$0FEF → select $FE bank
		if addr >= 0x0FD8 && addr <= 0x0FDF { m.latch_0 = false }
		if addr >= 0x0FE8 && addr <= 0x0FEF { m.latch_0 = true }

		return result, true
	} else {
		// High CHR bank — selected by latch_1
		bank = m.chr_bank_1_fe if m.latch_1 else m.chr_bank_1_fd
		idx := u32(bank) * 4096 + u32(addr - 0x1000)
		result: u8 = 0
		if idx < u32(len(m.chr_rom)) { result = m.chr_rom[idx] }

		// $1FD8-$1FDF → select $FD bank, $1FE8-$1FEF → select $FE bank
		if addr >= 0x1FD8 && addr <= 0x1FDF { m.latch_1 = false }
		if addr >= 0x1FE8 && addr <= 0x1FEF { m.latch_1 = true }

		return result, true
	}
}

mapper_009_ppu_write :: proc(m: ^Mapper_009, addr: u16, val: u8) -> bool {
	return false // CHR ROM only on MMC2
}

mapper_009_mirror :: proc(m: ^Mapper_009) -> Mirror_Mode {
	return m.mirror_mode
}
