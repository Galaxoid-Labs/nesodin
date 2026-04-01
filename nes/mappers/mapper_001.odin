package mappers

// MMC1 (Mapper 001) — SxROM
// Games: Zelda, Metroid, Mega Man 2, Final Fantasy
// 5-bit serial shift register written one bit at a time
// Controls PRG/CHR bank switching and mirroring

Mapper_001 :: struct {
	prg_rom:      []u8,
	chr:          []u8,
	prg_ram:      [8192]u8,
	has_chr_ram:  bool,
	prg_banks:    u8,
	chr_banks:    u8,

	// Shift register
	shift:        u8,
	shift_count:  u8,

	// Registers
	control:      u8,  // $8000-$9FFF
	chr_bank_0:   u8,  // $A000-$BFFF
	chr_bank_1:   u8,  // $C000-$DFFF
	prg_bank:     u8,  // $E000-$FFFF

	mirror_mode:  Mirror_Mode,
}

mapper_001_init :: proc(prg_rom: []u8, chr: []u8, prg_banks, chr_banks: u8, has_chr_ram: bool, mirror: Mirror_Mode) -> Mapper_001 {
	return Mapper_001{
		prg_rom     = prg_rom,
		chr         = chr,
		has_chr_ram = has_chr_ram,
		prg_banks   = prg_banks,
		chr_banks   = chr_banks,
		control     = 0x0C, // Default: PRG fix last bank, 32KB CHR mode
		mirror_mode = mirror,
	}
}

mapper_001_cpu_read :: proc(m: ^Mapper_001, addr: u16) -> (data: u8, ok: bool) {
	switch {
	case addr >= 0x6000 && addr <= 0x7FFF:
		return m.prg_ram[addr - 0x6000], true
	case addr >= 0x8000:
		prg_mode := (m.control >> 2) & 0x03
		switch prg_mode {
		case 0, 1:
			// 32KB mode: ignore low bit of bank
			bank := u32(m.prg_bank & 0x0E)
			offset := u32(addr - 0x8000)
			idx := bank * 16384 + offset
			if idx < u32(len(m.prg_rom)) { return m.prg_rom[idx], true }
		case 2:
			// Fix first bank, switch second
			if addr < 0xC000 {
				return m.prg_rom[addr - 0x8000], true
			} else {
				bank := u32(m.prg_bank & 0x0F)
				idx := bank * 16384 + u32(addr - 0xC000)
				if idx < u32(len(m.prg_rom)) { return m.prg_rom[idx], true }
			}
		case 3:
			// Switch first bank, fix last
			if addr < 0xC000 {
				bank := u32(m.prg_bank & 0x0F)
				idx := bank * 16384 + u32(addr - 0x8000)
				if idx < u32(len(m.prg_rom)) { return m.prg_rom[idx], true }
			} else {
				// Last bank
				last := u32(m.prg_banks - 1)
				idx := last * 16384 + u32(addr - 0xC000)
				if idx < u32(len(m.prg_rom)) { return m.prg_rom[idx], true }
			}
		}
	}
	return 0, false
}

mapper_001_cpu_write :: proc(m: ^Mapper_001, addr: u16, val: u8) -> bool {
	switch {
	case addr >= 0x6000 && addr <= 0x7FFF:
		m.prg_ram[addr - 0x6000] = val
		return true
	case addr >= 0x8000:
		if (val & 0x80) != 0 {
			// Reset shift register
			m.shift = 0
			m.shift_count = 0
			m.control |= 0x0C
			return true
		}
		m.shift |= (val & 0x01) << m.shift_count
		m.shift_count += 1
		if m.shift_count == 5 {
			// Write to internal register based on address
			switch {
			case addr <= 0x9FFF:
				m.control = m.shift
				switch m.control & 0x03 {
				case 0: m.mirror_mode = .Single_Screen_Low
				case 1: m.mirror_mode = .Single_Screen_High
				case 2: m.mirror_mode = .Vertical
				case 3: m.mirror_mode = .Horizontal
				}
			case addr <= 0xBFFF:
				m.chr_bank_0 = m.shift
			case addr <= 0xDFFF:
				m.chr_bank_1 = m.shift
			case addr <= 0xFFFF:
				m.prg_bank = m.shift & 0x0F
			}
			m.shift = 0
			m.shift_count = 0
		}
		return true
	}
	return false
}

mapper_001_ppu_read :: proc(m: ^Mapper_001, addr: u16) -> (data: u8, ok: bool) {
	if addr <= 0x1FFF {
		chr_mode := (m.control >> 4) & 0x01
		idx: u32
		if chr_mode == 0 {
			// 8KB mode
			bank := u32(m.chr_bank_0 & 0x1E) // Ignore low bit
			idx = bank * 4096 + u32(addr)
		} else {
			// 4KB mode
			if addr < 0x1000 {
				idx = u32(m.chr_bank_0) * 4096 + u32(addr)
			} else {
				idx = u32(m.chr_bank_1) * 4096 + u32(addr - 0x1000)
			}
		}
		if idx < u32(len(m.chr)) {
			return m.chr[idx], true
		}
		return 0, true
	}
	return 0, false
}

mapper_001_ppu_write :: proc(m: ^Mapper_001, addr: u16, val: u8) -> bool {
	if addr <= 0x1FFF && m.has_chr_ram {
		m.chr[addr] = val
		return true
	}
	return false
}

mapper_001_mirror :: proc(m: ^Mapper_001) -> Mirror_Mode {
	return m.mirror_mode
}
