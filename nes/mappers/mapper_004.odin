package mappers

// MMC3 (Mapper 004) — TxROM
// Games: SMB3, Kirby's Adventure, Mega Man 3-6, Batman
// PRG: Two switchable 8KB banks + two fixed 8KB banks
// CHR: Six switchable banks (two 2KB + four 1KB)
// Scanline counter IRQ, dynamic mirroring

Mapper_004 :: struct {
	prg_rom:     []u8,
	chr:         []u8,
	prg_ram:     [8192]u8,
	has_chr_ram: bool,
	prg_banks:   u8,    // In 8KB units
	chr_banks:   u8,    // In 1KB units

	// Bank select
	bank_select:  u8,   // Register index (0-7)
	prg_mode:     bool, // false = mode 0, true = mode 1
	chr_inversion: bool, // false = mode 0, true = mode 1
	registers:    [8]u8, // R0-R7 bank values

	// Mirroring
	mirror_mode:  Mirror_Mode,

	// PRG RAM
	ram_enabled:  bool,
	ram_protect:  bool,

	// IRQ
	irq_counter:  u8,
	irq_latch:    u8,
	irq_reload:   bool,
	irq_enabled:  bool,
	irq_pending:  bool,
}

mapper_004_init :: proc(prg_rom: []u8, chr: []u8, prg_banks_16k: u8, chr_banks_8k: u8,
	has_chr_ram: bool, mirror: Mirror_Mode) -> Mapper_004 {
	return Mapper_004{
		prg_rom     = prg_rom,
		chr         = chr,
		has_chr_ram = has_chr_ram,
		prg_banks   = prg_banks_16k * 2, // Convert to 8KB units
		chr_banks   = chr_banks_8k * 8,  // Convert to 1KB units
		mirror_mode = mirror,
		ram_enabled = true,
	}
}

mapper_004_cpu_read :: proc(m: ^Mapper_004, addr: u16) -> (data: u8, ok: bool) {
	switch {
	case addr >= 0x6000 && addr <= 0x7FFF:
		if m.ram_enabled {
			return m.prg_ram[addr - 0x6000], true
		}
		return 0, false

	case addr >= 0x8000:
		bank: u32
		offset := u32(addr & 0x1FFF)

		switch addr & 0xE000 {
		case 0x8000: // $8000-$9FFF
			if !m.prg_mode {
				bank = u32(m.registers[6] & 0x3F)
			} else {
				bank = u32(m.prg_banks - 2)
			}
		case 0xA000: // $A000-$BFFF
			bank = u32(m.registers[7] & 0x3F)
		case 0xC000: // $C000-$DFFF
			if !m.prg_mode {
				bank = u32(m.prg_banks - 2)
			} else {
				bank = u32(m.registers[6] & 0x3F)
			}
		case 0xE000: // $E000-$FFFF — always last bank
			bank = u32(m.prg_banks - 1)
		}

		idx := bank * 8192 + offset
		if idx < u32(len(m.prg_rom)) {
			return m.prg_rom[idx], true
		}
		return 0, true
	}
	return 0, false
}

mapper_004_cpu_write :: proc(m: ^Mapper_004, addr: u16, val: u8) -> bool {
	switch {
	case addr >= 0x6000 && addr <= 0x7FFF:
		if m.ram_enabled && !m.ram_protect {
			m.prg_ram[addr - 0x6000] = val
		}
		return true

	case addr >= 0x8000:
		even := (addr & 0x01) == 0

		switch addr & 0xE000 {
		case 0x8000:
			if even {
				// Bank select ($8000)
				m.bank_select = val & 0x07
				m.prg_mode = (val & 0x40) != 0
				m.chr_inversion = (val & 0x80) != 0
			} else {
				// Bank data ($8001)
				m.registers[m.bank_select] = val
				// R0 and R1 ignore bit 0 (2KB banks use even values)
				if m.bank_select == 0 || m.bank_select == 1 {
					m.registers[m.bank_select] &= 0xFE
				}
			}

		case 0xA000:
			if even {
				// Mirroring ($A000)
				if (val & 0x01) != 0 {
					m.mirror_mode = .Horizontal
				} else {
					m.mirror_mode = .Vertical
				}
			} else {
				// PRG RAM protect ($A001)
				m.ram_enabled = (val & 0x80) != 0
				m.ram_protect = (val & 0x40) != 0
			}

		case 0xC000:
			if even {
				// IRQ latch ($C000)
				m.irq_latch = val
			} else {
				// IRQ reload ($C001)
				m.irq_counter = 0
				m.irq_reload = true
			}

		case 0xE000:
			if even {
				// IRQ disable ($E000) — also acknowledges
				m.irq_enabled = false
				m.irq_pending = false
			} else {
				// IRQ enable ($E001)
				m.irq_enabled = true
			}
		}
		return true
	}
	return false
}

mapper_004_ppu_read :: proc(m: ^Mapper_004, addr: u16) -> (data: u8, ok: bool) {
	if addr > 0x1FFF { return 0, false }

	bank := mapper_004_chr_bank(m, addr)
	idx := u32(bank) * 1024 + u32(addr & 0x03FF)
	if idx < u32(len(m.chr)) {
		return m.chr[idx], true
	}
	return 0, true
}

mapper_004_ppu_write :: proc(m: ^Mapper_004, addr: u16, val: u8) -> bool {
	if addr <= 0x1FFF && m.has_chr_ram {
		bank := mapper_004_chr_bank(m, addr)
		idx := u32(bank) * 1024 + u32(addr & 0x03FF)
		if idx < u32(len(m.chr)) {
			m.chr[idx] = val
		}
		return true
	}
	return false
}

// Resolve a PPU address ($0000-$1FFF) to a 1KB CHR bank number
mapper_004_chr_bank :: proc(m: ^Mapper_004, addr: u16) -> u32 {
	slot := addr >> 10 // 0-7 (eight 1KB slots)

	if !m.chr_inversion {
		// Mode 0: R0,R0+1 at $0000; R1,R1+1 at $0800; R2-R5 at $1000-$1FFF
		switch slot {
		case 0: return u32(m.registers[0])     // $0000-$03FF
		case 1: return u32(m.registers[0]) + 1 // $0400-$07FF
		case 2: return u32(m.registers[1])     // $0800-$0BFF
		case 3: return u32(m.registers[1]) + 1 // $0C00-$0FFF
		case 4: return u32(m.registers[2])     // $1000-$13FF
		case 5: return u32(m.registers[3])     // $1400-$17FF
		case 6: return u32(m.registers[4])     // $1800-$1BFF
		case 7: return u32(m.registers[5])     // $1C00-$1FFF
		}
	} else {
		// Mode 1: R2-R5 at $0000-$0FFF; R0,R0+1 at $1000; R1,R1+1 at $1800
		switch slot {
		case 0: return u32(m.registers[2])     // $0000-$03FF
		case 1: return u32(m.registers[3])     // $0400-$07FF
		case 2: return u32(m.registers[4])     // $0800-$0BFF
		case 3: return u32(m.registers[5])     // $0C00-$0FFF
		case 4: return u32(m.registers[0])     // $1000-$13FF
		case 5: return u32(m.registers[0]) + 1 // $1400-$17FF
		case 6: return u32(m.registers[1])     // $1800-$1BFF
		case 7: return u32(m.registers[1]) + 1 // $1C00-$1FFF
		}
	}
	return 0
}

mapper_004_mirror :: proc(m: ^Mapper_004) -> Mirror_Mode {
	return m.mirror_mode
}

// Scanline counter — called when PPU A12 rises (0→1)
mapper_004_scanline :: proc(m: ^Mapper_004) {
	if m.irq_counter == 0 || m.irq_reload {
		m.irq_counter = m.irq_latch
		m.irq_reload = false
	} else {
		m.irq_counter -= 1
	}

	if m.irq_counter == 0 && m.irq_enabled {
		m.irq_pending = true
	}
}
