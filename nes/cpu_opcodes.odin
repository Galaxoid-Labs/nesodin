package nes

// 6502 addressing modes
Addr_Mode :: enum u8 {
	IMP, // Implied
	ACC, // Accumulator
	IMM, // Immediate
	ZPG, // Zero Page
	ZPX, // Zero Page,X
	ZPY, // Zero Page,Y
	ABS, // Absolute
	ABX, // Absolute,X
	ABY, // Absolute,Y
	IND, // Indirect (JMP only)
	IZX, // Indexed Indirect ($nn,X)
	IZY, // Indirect Indexed ($nn),Y
	REL, // Relative (branches)
}

// Instruction metadata
Opcode :: struct {
	name:   string,
	mode:   Addr_Mode,
	cycles: u8,
}

// Resolve the effective address for the current addressing mode.
// Returns (address, page_crossed)
cpu_resolve_addr :: proc(cpu: ^CPU, bus: ^Bus, mode: Addr_Mode) -> (addr: u16, page_crossed: bool) {
	switch mode {
	case .IMP, .ACC:
		return 0, false

	case .IMM:
		a := cpu.pc
		cpu.pc += 1
		return a, false

	case .ZPG:
		a := u16(bus_read(bus, cpu.pc))
		cpu.pc += 1
		return a, false

	case .ZPX:
		a := u16((bus_read(bus, cpu.pc) + cpu.x) & 0xFF)
		cpu.pc += 1
		return a, false

	case .ZPY:
		a := u16((bus_read(bus, cpu.pc) + cpu.y) & 0xFF)
		cpu.pc += 1
		return a, false

	case .ABS:
		lo := u16(bus_read(bus, cpu.pc))
		hi := u16(bus_read(bus, cpu.pc + 1))
		cpu.pc += 2
		return hi << 8 | lo, false

	case .ABX:
		lo := u16(bus_read(bus, cpu.pc))
		hi := u16(bus_read(bus, cpu.pc + 1))
		cpu.pc += 2
		base := hi << 8 | lo
		a := base + u16(cpu.x)
		return a, (a & 0xFF00) != (base & 0xFF00)

	case .ABY:
		lo := u16(bus_read(bus, cpu.pc))
		hi := u16(bus_read(bus, cpu.pc + 1))
		cpu.pc += 2
		base := hi << 8 | lo
		a := base + u16(cpu.y)
		return a, (a & 0xFF00) != (base & 0xFF00)

	case .IND:
		ptr_lo := u16(bus_read(bus, cpu.pc))
		ptr_hi := u16(bus_read(bus, cpu.pc + 1))
		cpu.pc += 2
		ptr := ptr_hi << 8 | ptr_lo
		// JMP indirect bug: if ptr is $xxFF, wraps within page
		lo := u16(bus_read(bus, ptr))
		hi: u16
		if ptr_lo == 0xFF {
			hi = u16(bus_read(bus, ptr & 0xFF00))
		} else {
			hi = u16(bus_read(bus, ptr + 1))
		}
		return hi << 8 | lo, false

	case .IZX:
		zp := bus_read(bus, cpu.pc)
		cpu.pc += 1
		ptr := u16((zp + cpu.x) & 0xFF)
		lo := u16(bus_read(bus, ptr & 0xFF))
		hi := u16(bus_read(bus, (ptr + 1) & 0xFF))
		return hi << 8 | lo, false

	case .IZY:
		zp := u16(bus_read(bus, cpu.pc))
		cpu.pc += 1
		lo := u16(bus_read(bus, zp & 0xFF))
		hi := u16(bus_read(bus, (zp + 1) & 0xFF))
		base := hi << 8 | lo
		a := base + u16(cpu.y)
		return a, (a & 0xFF00) != (base & 0xFF00)

	case .REL:
		offset := u16(bus_read(bus, cpu.pc))
		cpu.pc += 1
		if offset & 0x80 != 0 {
			return cpu.pc + offset - 256, false
		}
		return cpu.pc + offset, false
	}
	return 0, false
}

// Execute one CPU instruction. Returns cycles consumed.
cpu_step :: proc(cpu: ^CPU, bus: ^Bus) -> u8 {
	if cpu.stall > 0 {
		cpu.stall -= 1
		cpu.cycles += 1
		return 1
	}

	opcode_byte := bus_read(bus, cpu.pc)
	cpu.pc += 1

	table := OPCODE_TABLE
	op := table[opcode_byte]
	addr, page_crossed := cpu_resolve_addr(cpu, bus, op.mode)

	extra_cycles: u8 = 0

	switch opcode_byte {
	// === LDA ===
	case 0xA9, 0xA5, 0xB5, 0xAD, 0xBD, 0xB9, 0xA1, 0xB1:
		cpu.a = bus_read(bus, addr)
		cpu_set_zn(cpu, cpu.a)
		if page_crossed { extra_cycles = 1 }

	// === LDX ===
	case 0xA2, 0xA6, 0xB6, 0xAE, 0xBE:
		cpu.x = bus_read(bus, addr)
		cpu_set_zn(cpu, cpu.x)
		if page_crossed { extra_cycles = 1 }

	// === LDY ===
	case 0xA0, 0xA4, 0xB4, 0xAC, 0xBC:
		cpu.y = bus_read(bus, addr)
		cpu_set_zn(cpu, cpu.y)
		if page_crossed { extra_cycles = 1 }

	// === STA ===
	case 0x85, 0x95, 0x8D, 0x9D, 0x99, 0x81, 0x91:
		bus_write(bus, addr, cpu.a)

	// === STX ===
	case 0x86, 0x96, 0x8E:
		bus_write(bus, addr, cpu.x)

	// === STY ===
	case 0x84, 0x94, 0x8C:
		bus_write(bus, addr, cpu.y)

	// === TAX ===
	case 0xAA:
		cpu.x = cpu.a
		cpu_set_zn(cpu, cpu.x)

	// === TXA ===
	case 0x8A:
		cpu.a = cpu.x
		cpu_set_zn(cpu, cpu.a)

	// === TAY ===
	case 0xA8:
		cpu.y = cpu.a
		cpu_set_zn(cpu, cpu.y)

	// === TYA ===
	case 0x98:
		cpu.a = cpu.y
		cpu_set_zn(cpu, cpu.a)

	// === TSX ===
	case 0xBA:
		cpu.x = cpu.sp
		cpu_set_zn(cpu, cpu.x)

	// === TXS ===
	case 0x9A:
		cpu.sp = cpu.x

	// === ADC ===
	case 0x69, 0x65, 0x75, 0x6D, 0x7D, 0x79, 0x61, 0x71:
		val := bus_read(bus, addr)
		cpu_adc(cpu, val)
		if page_crossed { extra_cycles = 1 }

	// === SBC ===
	case 0xE9, 0xE5, 0xF5, 0xED, 0xFD, 0xF9, 0xE1, 0xF1:
		val := bus_read(bus, addr)
		cpu_adc(cpu, val ~ 0xFF) // SBC = ADC with complement
		if page_crossed { extra_cycles = 1 }

	// === AND ===
	case 0x29, 0x25, 0x35, 0x2D, 0x3D, 0x39, 0x21, 0x31:
		cpu.a &= bus_read(bus, addr)
		cpu_set_zn(cpu, cpu.a)
		if page_crossed { extra_cycles = 1 }

	// === ORA ===
	case 0x09, 0x05, 0x15, 0x0D, 0x1D, 0x19, 0x01, 0x11:
		cpu.a |= bus_read(bus, addr)
		cpu_set_zn(cpu, cpu.a)
		if page_crossed { extra_cycles = 1 }

	// === EOR ===
	case 0x49, 0x45, 0x55, 0x4D, 0x5D, 0x59, 0x41, 0x51:
		cpu.a ~= bus_read(bus, addr)
		cpu_set_zn(cpu, cpu.a)
		if page_crossed { extra_cycles = 1 }

	// === BIT ===
	case 0x24, 0x2C:
		val := bus_read(bus, addr)
		if val & 0x40 != 0 {
			cpu.status += {.Overflow}
		} else {
			cpu.status -= {.Overflow}
		}
		if val & 0x80 != 0 {
			cpu.status += {.Negative}
		} else {
			cpu.status -= {.Negative}
		}
		if val & cpu.a == 0 {
			cpu.status += {.Zero}
		} else {
			cpu.status -= {.Zero}
		}

	// === ASL Accumulator ===
	case 0x0A:
		if cpu.a & 0x80 != 0 {
			cpu.status += {.Carry}
		} else {
			cpu.status -= {.Carry}
		}
		cpu.a <<= 1
		cpu_set_zn(cpu, cpu.a)

	// === ASL Memory ===
	case 0x06, 0x16, 0x0E, 0x1E:
		val := bus_read(bus, addr)
		if val & 0x80 != 0 {
			cpu.status += {.Carry}
		} else {
			cpu.status -= {.Carry}
		}
		val <<= 1
		bus_write(bus, addr, val)
		cpu_set_zn(cpu, val)

	// === LSR Accumulator ===
	case 0x4A:
		if cpu.a & 0x01 != 0 {
			cpu.status += {.Carry}
		} else {
			cpu.status -= {.Carry}
		}
		cpu.a >>= 1
		cpu_set_zn(cpu, cpu.a)

	// === LSR Memory ===
	case 0x46, 0x56, 0x4E, 0x5E:
		val := bus_read(bus, addr)
		if val & 0x01 != 0 {
			cpu.status += {.Carry}
		} else {
			cpu.status -= {.Carry}
		}
		val >>= 1
		bus_write(bus, addr, val)
		cpu_set_zn(cpu, val)

	// === ROL Accumulator ===
	case 0x2A:
		old_carry: u8 = .Carry in cpu.status ? 1 : 0
		if cpu.a & 0x80 != 0 {
			cpu.status += {.Carry}
		} else {
			cpu.status -= {.Carry}
		}
		cpu.a = (cpu.a << 1) | old_carry
		cpu_set_zn(cpu, cpu.a)

	// === ROL Memory ===
	case 0x26, 0x36, 0x2E, 0x3E:
		val := bus_read(bus, addr)
		old_carry: u8 = .Carry in cpu.status ? 1 : 0
		if val & 0x80 != 0 {
			cpu.status += {.Carry}
		} else {
			cpu.status -= {.Carry}
		}
		val = (val << 1) | old_carry
		bus_write(bus, addr, val)
		cpu_set_zn(cpu, val)

	// === ROR Accumulator ===
	case 0x6A:
		old_carry: u8 = .Carry in cpu.status ? 0x80 : 0
		if cpu.a & 0x01 != 0 {
			cpu.status += {.Carry}
		} else {
			cpu.status -= {.Carry}
		}
		cpu.a = (cpu.a >> 1) | old_carry
		cpu_set_zn(cpu, cpu.a)

	// === ROR Memory ===
	case 0x66, 0x76, 0x6E, 0x7E:
		val := bus_read(bus, addr)
		old_carry: u8 = .Carry in cpu.status ? 0x80 : 0
		if val & 0x01 != 0 {
			cpu.status += {.Carry}
		} else {
			cpu.status -= {.Carry}
		}
		val = (val >> 1) | old_carry
		bus_write(bus, addr, val)
		cpu_set_zn(cpu, val)

	// === INC ===
	case 0xE6, 0xF6, 0xEE, 0xFE:
		val := bus_read(bus, addr) + 1
		bus_write(bus, addr, val)
		cpu_set_zn(cpu, val)

	// === DEC ===
	case 0xC6, 0xD6, 0xCE, 0xDE:
		val := bus_read(bus, addr) - 1
		bus_write(bus, addr, val)
		cpu_set_zn(cpu, val)

	// === INX ===
	case 0xE8:
		cpu.x += 1
		cpu_set_zn(cpu, cpu.x)

	// === DEX ===
	case 0xCA:
		cpu.x -= 1
		cpu_set_zn(cpu, cpu.x)

	// === INY ===
	case 0xC8:
		cpu.y += 1
		cpu_set_zn(cpu, cpu.y)

	// === DEY ===
	case 0x88:
		cpu.y -= 1
		cpu_set_zn(cpu, cpu.y)

	// === CMP ===
	case 0xC9, 0xC5, 0xD5, 0xCD, 0xDD, 0xD9, 0xC1, 0xD1:
		cpu_compare(cpu, cpu.a, bus_read(bus, addr))
		if page_crossed { extra_cycles = 1 }

	// === CPX ===
	case 0xE0, 0xE4, 0xEC:
		cpu_compare(cpu, cpu.x, bus_read(bus, addr))

	// === CPY ===
	case 0xC0, 0xC4, 0xCC:
		cpu_compare(cpu, cpu.y, bus_read(bus, addr))

	// === Branches ===
	case 0x90: // BCC
		extra_cycles = cpu_branch(cpu, addr, .Carry not_in cpu.status)
	case 0xB0: // BCS
		extra_cycles = cpu_branch(cpu, addr, .Carry in cpu.status)
	case 0xF0: // BEQ
		extra_cycles = cpu_branch(cpu, addr, .Zero in cpu.status)
	case 0xD0: // BNE
		extra_cycles = cpu_branch(cpu, addr, .Zero not_in cpu.status)
	case 0x30: // BMI
		extra_cycles = cpu_branch(cpu, addr, .Negative in cpu.status)
	case 0x10: // BPL
		extra_cycles = cpu_branch(cpu, addr, .Negative not_in cpu.status)
	case 0x50: // BVC
		extra_cycles = cpu_branch(cpu, addr, .Overflow not_in cpu.status)
	case 0x70: // BVS
		extra_cycles = cpu_branch(cpu, addr, .Overflow in cpu.status)

	// === JMP Absolute ===
	case 0x4C:
		cpu.pc = addr

	// === JMP Indirect ===
	case 0x6C:
		cpu.pc = addr

	// === JSR ===
	case 0x20:
		cpu_push16(cpu, bus, cpu.pc - 1) // Push PC-1
		cpu.pc = addr

	// === RTS ===
	case 0x60:
		cpu.pc = cpu_pop16(cpu, bus) + 1

	// === BRK ===
	case 0x00:
		cpu.pc += 1 // BRK pushes PC+2 (one extra byte)
		cpu_push16(cpu, bus, cpu.pc)
		cpu_push(cpu, bus, cpu_flags_to_u8(cpu.status + {.Break}))
		cpu.status += {.Interrupt_Disable}
		lo := u16(bus_read(bus, 0xFFFE))
		hi := u16(bus_read(bus, 0xFFFF))
		cpu.pc = hi << 8 | lo

	// === RTI ===
	case 0x40:
		cpu.status = cpu_u8_to_flags(cpu_pop(cpu, bus))
		cpu.pc = cpu_pop16(cpu, bus)

	// === PHA ===
	case 0x48:
		cpu_push(cpu, bus, cpu.a)

	// === PLA ===
	case 0x68:
		cpu.a = cpu_pop(cpu, bus)
		cpu_set_zn(cpu, cpu.a)

	// === PHP ===
	case 0x08:
		cpu_push(cpu, bus, cpu_flags_to_u8(cpu.status + {.Break}))

	// === PLP ===
	case 0x28:
		cpu.status = cpu_u8_to_flags(cpu_pop(cpu, bus))

	// === Flag instructions ===
	case 0x18: cpu.status -= {.Carry}             // CLC
	case 0x38: cpu.status += {.Carry}             // SEC
	case 0x58: cpu.status -= {.Interrupt_Disable} // CLI
	case 0x78: cpu.status += {.Interrupt_Disable} // SEI
	case 0xB8: cpu.status -= {.Overflow}          // CLV
	case 0xD8: cpu.status -= {.Decimal}           // CLD
	case 0xF8: cpu.status += {.Decimal}           // SED

	// === NOP ===
	case 0xEA:
		// Do nothing

	// === Unofficial NOP (multi-byte variants) ===
	case 0x1A, 0x3A, 0x5A, 0x7A, 0xDA, 0xFA: // 1-byte implied NOPs
		// Do nothing

	case 0x80, 0x82, 0x89, 0xC2, 0xE2: // 2-byte immediate NOPs
		_ = bus_read(bus, addr) // Read and discard

	case 0x04, 0x44, 0x64: // 2-byte zero page NOPs
		_ = bus_read(bus, addr)

	case 0x14, 0x34, 0x54, 0x74, 0xD4, 0xF4: // 2-byte zero page,X NOPs
		_ = bus_read(bus, addr)

	case 0x0C: // 3-byte absolute NOP
		_ = bus_read(bus, addr)

	case 0x1C, 0x3C, 0x5C, 0x7C, 0xDC, 0xFC: // 3-byte absolute,X NOPs
		_ = bus_read(bus, addr)
		if page_crossed { extra_cycles = 1 }

	// === Unofficial SBC ($EB) — identical to $E9 ===
	case 0xEB:
		val := bus_read(bus, addr)
		cpu_adc(cpu, val ~ 0xFF)

	// === LAX — LDA + LDX ===
	case 0xA7, 0xB7, 0xAF, 0xBF, 0xA3, 0xB3:
		val := bus_read(bus, addr)
		cpu.a = val
		cpu.x = val
		cpu_set_zn(cpu, val)
		if page_crossed { extra_cycles = 1 }

	// === SAX — Store A & X ===
	case 0x87, 0x97, 0x8F, 0x83:
		bus_write(bus, addr, cpu.a & cpu.x)

	// === DCP — DEC + CMP ===
	case 0xC7, 0xD7, 0xCF, 0xDF, 0xDB, 0xC3, 0xD3:
		val := bus_read(bus, addr) - 1
		bus_write(bus, addr, val)
		cpu_compare(cpu, cpu.a, val)

	// === ISB (ISC) — INC + SBC ===
	case 0xE7, 0xF7, 0xEF, 0xFF, 0xFB, 0xE3, 0xF3:
		val := bus_read(bus, addr) + 1
		bus_write(bus, addr, val)
		cpu_adc(cpu, val ~ 0xFF)

	// === SLO — ASL + ORA ===
	case 0x07, 0x17, 0x0F, 0x1F, 0x1B, 0x03, 0x13:
		val := bus_read(bus, addr)
		if val & 0x80 != 0 {
			cpu.status += {.Carry}
		} else {
			cpu.status -= {.Carry}
		}
		val <<= 1
		bus_write(bus, addr, val)
		cpu.a |= val
		cpu_set_zn(cpu, cpu.a)

	// === SRE — LSR + EOR ===
	case 0x47, 0x57, 0x4F, 0x5F, 0x5B, 0x43, 0x53:
		val := bus_read(bus, addr)
		if val & 0x01 != 0 {
			cpu.status += {.Carry}
		} else {
			cpu.status -= {.Carry}
		}
		val >>= 1
		bus_write(bus, addr, val)
		cpu.a ~= val
		cpu_set_zn(cpu, cpu.a)

	// === RLA — ROL + AND ===
	case 0x27, 0x37, 0x2F, 0x3F, 0x3B, 0x23, 0x33:
		val := bus_read(bus, addr)
		old_carry: u8 = .Carry in cpu.status ? 1 : 0
		if val & 0x80 != 0 {
			cpu.status += {.Carry}
		} else {
			cpu.status -= {.Carry}
		}
		val = (val << 1) | old_carry
		bus_write(bus, addr, val)
		cpu.a &= val
		cpu_set_zn(cpu, cpu.a)

	// === RRA — ROR + ADC ===
	case 0x67, 0x77, 0x6F, 0x7F, 0x7B, 0x63, 0x73:
		val := bus_read(bus, addr)
		old_carry: u8 = .Carry in cpu.status ? 0x80 : 0
		if val & 0x01 != 0 {
			cpu.status += {.Carry}
		} else {
			cpu.status -= {.Carry}
		}
		val = (val >> 1) | old_carry
		bus_write(bus, addr, val)
		cpu_adc(cpu, val)

	// === Catch-all for any remaining undefined opcodes ===
	case:
		if page_crossed { extra_cycles = 1 }
	}

	total := op.cycles + extra_cycles
	cpu.cycles += u64(total)
	return total
}

// ADC implementation
cpu_adc :: proc(cpu: ^CPU, val: u8) {
	carry: u16 = .Carry in cpu.status ? 1 : 0
	sum := u16(cpu.a) + u16(val) + carry

	if sum > 0xFF {
		cpu.status += {.Carry}
	} else {
		cpu.status -= {.Carry}
	}

	result := u8(sum & 0xFF)

	// Overflow: set if sign bit is wrong
	if (cpu.a ~ result) & (val ~ result) & 0x80 != 0 {
		cpu.status += {.Overflow}
	} else {
		cpu.status -= {.Overflow}
	}

	cpu.a = result
	cpu_set_zn(cpu, cpu.a)
}

// Compare helper
cpu_compare :: proc(cpu: ^CPU, reg: u8, val: u8) {
	diff := reg - val
	if reg >= val {
		cpu.status += {.Carry}
	} else {
		cpu.status -= {.Carry}
	}
	cpu_set_zn(cpu, diff)
}

// Branch helper — returns extra cycles
cpu_branch :: proc(cpu: ^CPU, addr: u16, condition: bool) -> u8 {
	if !condition {
		return 0
	}
	extra: u8 = 1
	if (cpu.pc & 0xFF00) != (addr & 0xFF00) {
		extra = 2 // Page crossing
	}
	cpu.pc = addr
	return extra
}

// Full 256-entry opcode table (official + unofficial)
// Unofficial opcodes marked with * prefix in name
OPCODE_TABLE :: [256]Opcode{
	// 0x00
	{name = "BRK", mode = .IMP, cycles = 7},  // 00
	{name = "ORA", mode = .IZX, cycles = 6},  // 01
	{name = "???", mode = .IMP, cycles = 2},  // 02
	{name = "*SLO", mode = .IZX, cycles = 8}, // 03
	{name = "*NOP", mode = .ZPG, cycles = 3}, // 04
	{name = "ORA", mode = .ZPG, cycles = 3},  // 05
	{name = "ASL", mode = .ZPG, cycles = 5},  // 06
	{name = "*SLO", mode = .ZPG, cycles = 5}, // 07
	{name = "PHP", mode = .IMP, cycles = 3},  // 08
	{name = "ORA", mode = .IMM, cycles = 2},  // 09
	{name = "ASL", mode = .ACC, cycles = 2},  // 0A
	{name = "???", mode = .IMP, cycles = 2},  // 0B
	{name = "*NOP", mode = .ABS, cycles = 4}, // 0C
	{name = "ORA", mode = .ABS, cycles = 4},  // 0D
	{name = "ASL", mode = .ABS, cycles = 6},  // 0E
	{name = "*SLO", mode = .ABS, cycles = 6}, // 0F

	// 0x10
	{name = "BPL", mode = .REL, cycles = 2},  // 10
	{name = "ORA", mode = .IZY, cycles = 5},  // 11
	{name = "???", mode = .IMP, cycles = 2},  // 12
	{name = "*SLO", mode = .IZY, cycles = 8}, // 13
	{name = "*NOP", mode = .ZPX, cycles = 4}, // 14
	{name = "ORA", mode = .ZPX, cycles = 4},  // 15
	{name = "ASL", mode = .ZPX, cycles = 6},  // 16
	{name = "*SLO", mode = .ZPX, cycles = 6}, // 17
	{name = "CLC", mode = .IMP, cycles = 2},  // 18
	{name = "ORA", mode = .ABY, cycles = 4},  // 19
	{name = "*NOP", mode = .IMP, cycles = 2}, // 1A
	{name = "*SLO", mode = .ABY, cycles = 7}, // 1B
	{name = "*NOP", mode = .ABX, cycles = 4}, // 1C
	{name = "ORA", mode = .ABX, cycles = 4},  // 1D
	{name = "ASL", mode = .ABX, cycles = 7},  // 1E
	{name = "*SLO", mode = .ABX, cycles = 7}, // 1F

	// 0x20
	{name = "JSR", mode = .ABS, cycles = 6},  // 20
	{name = "AND", mode = .IZX, cycles = 6},  // 21
	{name = "???", mode = .IMP, cycles = 2},  // 22
	{name = "*RLA", mode = .IZX, cycles = 8}, // 23
	{name = "BIT", mode = .ZPG, cycles = 3},  // 24
	{name = "AND", mode = .ZPG, cycles = 3},  // 25
	{name = "ROL", mode = .ZPG, cycles = 5},  // 26
	{name = "*RLA", mode = .ZPG, cycles = 5}, // 27
	{name = "PLP", mode = .IMP, cycles = 4},  // 28
	{name = "AND", mode = .IMM, cycles = 2},  // 29
	{name = "ROL", mode = .ACC, cycles = 2},  // 2A
	{name = "???", mode = .IMP, cycles = 2},  // 2B
	{name = "BIT", mode = .ABS, cycles = 4},  // 2C
	{name = "AND", mode = .ABS, cycles = 4},  // 2D
	{name = "ROL", mode = .ABS, cycles = 6},  // 2E
	{name = "*RLA", mode = .ABS, cycles = 6}, // 2F

	// 0x30
	{name = "BMI", mode = .REL, cycles = 2},  // 30
	{name = "AND", mode = .IZY, cycles = 5},  // 31
	{name = "???", mode = .IMP, cycles = 2},  // 32
	{name = "*RLA", mode = .IZY, cycles = 8}, // 33
	{name = "*NOP", mode = .ZPX, cycles = 4}, // 34
	{name = "AND", mode = .ZPX, cycles = 4},  // 35
	{name = "ROL", mode = .ZPX, cycles = 6},  // 36
	{name = "*RLA", mode = .ZPX, cycles = 6}, // 37
	{name = "SEC", mode = .IMP, cycles = 2},  // 38
	{name = "AND", mode = .ABY, cycles = 4},  // 39
	{name = "*NOP", mode = .IMP, cycles = 2}, // 3A
	{name = "*RLA", mode = .ABY, cycles = 7}, // 3B
	{name = "*NOP", mode = .ABX, cycles = 4}, // 3C
	{name = "AND", mode = .ABX, cycles = 4},  // 3D
	{name = "ROL", mode = .ABX, cycles = 7},  // 3E
	{name = "*RLA", mode = .ABX, cycles = 7}, // 3F

	// 0x40
	{name = "RTI", mode = .IMP, cycles = 6},  // 40
	{name = "EOR", mode = .IZX, cycles = 6},  // 41
	{name = "???", mode = .IMP, cycles = 2},  // 42
	{name = "*SRE", mode = .IZX, cycles = 8}, // 43
	{name = "*NOP", mode = .ZPG, cycles = 3}, // 44
	{name = "EOR", mode = .ZPG, cycles = 3},  // 45
	{name = "LSR", mode = .ZPG, cycles = 5},  // 46
	{name = "*SRE", mode = .ZPG, cycles = 5}, // 47
	{name = "PHA", mode = .IMP, cycles = 3},  // 48
	{name = "EOR", mode = .IMM, cycles = 2},  // 49
	{name = "LSR", mode = .ACC, cycles = 2},  // 4A
	{name = "???", mode = .IMP, cycles = 2},  // 4B
	{name = "JMP", mode = .ABS, cycles = 3},  // 4C
	{name = "EOR", mode = .ABS, cycles = 4},  // 4D
	{name = "LSR", mode = .ABS, cycles = 6},  // 4E
	{name = "*SRE", mode = .ABS, cycles = 6}, // 4F

	// 0x50
	{name = "BVC", mode = .REL, cycles = 2},  // 50
	{name = "EOR", mode = .IZY, cycles = 5},  // 51
	{name = "???", mode = .IMP, cycles = 2},  // 52
	{name = "*SRE", mode = .IZY, cycles = 8}, // 53
	{name = "*NOP", mode = .ZPX, cycles = 4}, // 54
	{name = "EOR", mode = .ZPX, cycles = 4},  // 55
	{name = "LSR", mode = .ZPX, cycles = 6},  // 56
	{name = "*SRE", mode = .ZPX, cycles = 6}, // 57
	{name = "CLI", mode = .IMP, cycles = 2},  // 58
	{name = "EOR", mode = .ABY, cycles = 4},  // 59
	{name = "*NOP", mode = .IMP, cycles = 2}, // 5A
	{name = "*SRE", mode = .ABY, cycles = 7}, // 5B
	{name = "*NOP", mode = .ABX, cycles = 4}, // 5C
	{name = "EOR", mode = .ABX, cycles = 4},  // 5D
	{name = "LSR", mode = .ABX, cycles = 7},  // 5E
	{name = "*SRE", mode = .ABX, cycles = 7}, // 5F

	// 0x60
	{name = "RTS", mode = .IMP, cycles = 6},  // 60
	{name = "ADC", mode = .IZX, cycles = 6},  // 61
	{name = "???", mode = .IMP, cycles = 2},  // 62
	{name = "*RRA", mode = .IZX, cycles = 8}, // 63
	{name = "*NOP", mode = .ZPG, cycles = 3}, // 64
	{name = "ADC", mode = .ZPG, cycles = 3},  // 65
	{name = "ROR", mode = .ZPG, cycles = 5},  // 66
	{name = "*RRA", mode = .ZPG, cycles = 5}, // 67
	{name = "PLA", mode = .IMP, cycles = 4},  // 68
	{name = "ADC", mode = .IMM, cycles = 2},  // 69
	{name = "ROR", mode = .ACC, cycles = 2},  // 6A
	{name = "???", mode = .IMP, cycles = 2},  // 6B
	{name = "JMP", mode = .IND, cycles = 5},  // 6C
	{name = "ADC", mode = .ABS, cycles = 4},  // 6D
	{name = "ROR", mode = .ABS, cycles = 6},  // 6E
	{name = "*RRA", mode = .ABS, cycles = 6}, // 6F

	// 0x70
	{name = "BVS", mode = .REL, cycles = 2},  // 70
	{name = "ADC", mode = .IZY, cycles = 5},  // 71
	{name = "???", mode = .IMP, cycles = 2},  // 72
	{name = "*RRA", mode = .IZY, cycles = 8}, // 73
	{name = "*NOP", mode = .ZPX, cycles = 4}, // 74
	{name = "ADC", mode = .ZPX, cycles = 4},  // 75
	{name = "ROR", mode = .ZPX, cycles = 6},  // 76
	{name = "*RRA", mode = .ZPX, cycles = 6}, // 77
	{name = "SEI", mode = .IMP, cycles = 2},  // 78
	{name = "ADC", mode = .ABY, cycles = 4},  // 79
	{name = "*NOP", mode = .IMP, cycles = 2}, // 7A
	{name = "*RRA", mode = .ABY, cycles = 7}, // 7B
	{name = "*NOP", mode = .ABX, cycles = 4}, // 7C
	{name = "ADC", mode = .ABX, cycles = 4},  // 7D
	{name = "ROR", mode = .ABX, cycles = 7},  // 7E
	{name = "*RRA", mode = .ABX, cycles = 7}, // 7F

	// 0x80
	{name = "*NOP", mode = .IMM, cycles = 2}, // 80
	{name = "STA", mode = .IZX, cycles = 6},  // 81
	{name = "*NOP", mode = .IMM, cycles = 2}, // 82
	{name = "*SAX", mode = .IZX, cycles = 6}, // 83
	{name = "STY", mode = .ZPG, cycles = 3},  // 84
	{name = "STA", mode = .ZPG, cycles = 3},  // 85
	{name = "STX", mode = .ZPG, cycles = 3},  // 86
	{name = "*SAX", mode = .ZPG, cycles = 3}, // 87
	{name = "DEY", mode = .IMP, cycles = 2},  // 88
	{name = "*NOP", mode = .IMM, cycles = 2}, // 89
	{name = "TXA", mode = .IMP, cycles = 2},  // 8A
	{name = "???", mode = .IMP, cycles = 2},  // 8B
	{name = "STY", mode = .ABS, cycles = 4},  // 8C
	{name = "STA", mode = .ABS, cycles = 4},  // 8D
	{name = "STX", mode = .ABS, cycles = 4},  // 8E
	{name = "*SAX", mode = .ABS, cycles = 4}, // 8F

	// 0x90
	{name = "BCC", mode = .REL, cycles = 2},  // 90
	{name = "STA", mode = .IZY, cycles = 6},  // 91
	{name = "???", mode = .IMP, cycles = 2},  // 92
	{name = "???", mode = .IMP, cycles = 2},  // 93
	{name = "STY", mode = .ZPX, cycles = 4},  // 94
	{name = "STA", mode = .ZPX, cycles = 4},  // 95
	{name = "STX", mode = .ZPY, cycles = 4},  // 96
	{name = "*SAX", mode = .ZPY, cycles = 4}, // 97
	{name = "TYA", mode = .IMP, cycles = 2},  // 98
	{name = "STA", mode = .ABY, cycles = 5},  // 99
	{name = "TXS", mode = .IMP, cycles = 2},  // 9A
	{name = "???", mode = .IMP, cycles = 2},  // 9B
	{name = "???", mode = .IMP, cycles = 2},  // 9C
	{name = "STA", mode = .ABX, cycles = 5},  // 9D
	{name = "???", mode = .IMP, cycles = 2},  // 9E
	{name = "???", mode = .IMP, cycles = 2},  // 9F

	// 0xA0
	{name = "LDY", mode = .IMM, cycles = 2},  // A0
	{name = "LDA", mode = .IZX, cycles = 6},  // A1
	{name = "LDX", mode = .IMM, cycles = 2},  // A2
	{name = "*LAX", mode = .IZX, cycles = 6}, // A3
	{name = "LDY", mode = .ZPG, cycles = 3},  // A4
	{name = "LDA", mode = .ZPG, cycles = 3},  // A5
	{name = "LDX", mode = .ZPG, cycles = 3},  // A6
	{name = "*LAX", mode = .ZPG, cycles = 3}, // A7
	{name = "TAY", mode = .IMP, cycles = 2},  // A8
	{name = "LDA", mode = .IMM, cycles = 2},  // A9
	{name = "TAX", mode = .IMP, cycles = 2},  // AA
	{name = "???", mode = .IMP, cycles = 2},  // AB
	{name = "LDY", mode = .ABS, cycles = 4},  // AC
	{name = "LDA", mode = .ABS, cycles = 4},  // AD
	{name = "LDX", mode = .ABS, cycles = 4},  // AE
	{name = "*LAX", mode = .ABS, cycles = 4}, // AF

	// 0xB0
	{name = "BCS", mode = .REL, cycles = 2},  // B0
	{name = "LDA", mode = .IZY, cycles = 5},  // B1
	{name = "???", mode = .IMP, cycles = 2},  // B2
	{name = "*LAX", mode = .IZY, cycles = 5}, // B3
	{name = "LDY", mode = .ZPX, cycles = 4},  // B4
	{name = "LDA", mode = .ZPX, cycles = 4},  // B5
	{name = "LDX", mode = .ZPY, cycles = 4},  // B6
	{name = "*LAX", mode = .ZPY, cycles = 4}, // B7
	{name = "CLV", mode = .IMP, cycles = 2},  // B8
	{name = "LDA", mode = .ABY, cycles = 4},  // B9
	{name = "TSX", mode = .IMP, cycles = 2},  // BA
	{name = "???", mode = .IMP, cycles = 2},  // BB
	{name = "LDY", mode = .ABX, cycles = 4},  // BC
	{name = "LDA", mode = .ABX, cycles = 4},  // BD
	{name = "LDX", mode = .ABY, cycles = 4},  // BE
	{name = "*LAX", mode = .ABY, cycles = 4}, // BF

	// 0xC0
	{name = "CPY", mode = .IMM, cycles = 2},  // C0
	{name = "CMP", mode = .IZX, cycles = 6},  // C1
	{name = "*NOP", mode = .IMM, cycles = 2}, // C2
	{name = "*DCP", mode = .IZX, cycles = 8}, // C3
	{name = "CPY", mode = .ZPG, cycles = 3},  // C4
	{name = "CMP", mode = .ZPG, cycles = 3},  // C5
	{name = "DEC", mode = .ZPG, cycles = 5},  // C6
	{name = "*DCP", mode = .ZPG, cycles = 5}, // C7
	{name = "INY", mode = .IMP, cycles = 2},  // C8
	{name = "CMP", mode = .IMM, cycles = 2},  // C9
	{name = "DEX", mode = .IMP, cycles = 2},  // CA
	{name = "???", mode = .IMP, cycles = 2},  // CB
	{name = "CPY", mode = .ABS, cycles = 4},  // CC
	{name = "CMP", mode = .ABS, cycles = 4},  // CD
	{name = "DEC", mode = .ABS, cycles = 6},  // CE
	{name = "*DCP", mode = .ABS, cycles = 6}, // CF

	// 0xD0
	{name = "BNE", mode = .REL, cycles = 2},  // D0
	{name = "CMP", mode = .IZY, cycles = 5},  // D1
	{name = "???", mode = .IMP, cycles = 2},  // D2
	{name = "*DCP", mode = .IZY, cycles = 8}, // D3
	{name = "*NOP", mode = .ZPX, cycles = 4}, // D4
	{name = "CMP", mode = .ZPX, cycles = 4},  // D5
	{name = "DEC", mode = .ZPX, cycles = 6},  // D6
	{name = "*DCP", mode = .ZPX, cycles = 6}, // D7
	{name = "CLD", mode = .IMP, cycles = 2},  // D8
	{name = "CMP", mode = .ABY, cycles = 4},  // D9
	{name = "*NOP", mode = .IMP, cycles = 2}, // DA
	{name = "*DCP", mode = .ABY, cycles = 7}, // DB
	{name = "*NOP", mode = .ABX, cycles = 4}, // DC
	{name = "CMP", mode = .ABX, cycles = 4},  // DD
	{name = "DEC", mode = .ABX, cycles = 7},  // DE
	{name = "*DCP", mode = .ABX, cycles = 7}, // DF

	// 0xE0
	{name = "CPX", mode = .IMM, cycles = 2},  // E0
	{name = "SBC", mode = .IZX, cycles = 6},  // E1
	{name = "*NOP", mode = .IMM, cycles = 2}, // E2
	{name = "*ISB", mode = .IZX, cycles = 8}, // E3
	{name = "CPX", mode = .ZPG, cycles = 3},  // E4
	{name = "SBC", mode = .ZPG, cycles = 3},  // E5
	{name = "INC", mode = .ZPG, cycles = 5},  // E6
	{name = "*ISB", mode = .ZPG, cycles = 5}, // E7
	{name = "INX", mode = .IMP, cycles = 2},  // E8
	{name = "SBC", mode = .IMM, cycles = 2},  // E9
	{name = "NOP", mode = .IMP, cycles = 2},  // EA
	{name = "*SBC", mode = .IMM, cycles = 2}, // EB
	{name = "CPX", mode = .ABS, cycles = 4},  // EC
	{name = "SBC", mode = .ABS, cycles = 4},  // ED
	{name = "INC", mode = .ABS, cycles = 6},  // EE
	{name = "*ISB", mode = .ABS, cycles = 6}, // EF

	// 0xF0
	{name = "BEQ", mode = .REL, cycles = 2},  // F0
	{name = "SBC", mode = .IZY, cycles = 5},  // F1
	{name = "???", mode = .IMP, cycles = 2},  // F2
	{name = "*ISB", mode = .IZY, cycles = 8}, // F3
	{name = "*NOP", mode = .ZPX, cycles = 4}, // F4
	{name = "SBC", mode = .ZPX, cycles = 4},  // F5
	{name = "INC", mode = .ZPX, cycles = 6},  // F6
	{name = "*ISB", mode = .ZPX, cycles = 6}, // F7
	{name = "SED", mode = .IMP, cycles = 2},  // F8
	{name = "SBC", mode = .ABY, cycles = 4},  // F9
	{name = "*NOP", mode = .IMP, cycles = 2}, // FA
	{name = "*ISB", mode = .ABY, cycles = 7}, // FB
	{name = "*NOP", mode = .ABX, cycles = 4}, // FC
	{name = "SBC", mode = .ABX, cycles = 4},  // FD
	{name = "INC", mode = .ABX, cycles = 7},  // FE
	{name = "*ISB", mode = .ABX, cycles = 7}, // FF
}
