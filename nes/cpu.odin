package nes

CPU_Flag :: enum u8 {
	Carry,            // bit 0
	Zero,             // bit 1
	Interrupt_Disable,// bit 2
	Decimal,          // bit 3 (not used on NES but exists)
	Break,            // bit 4
	Unused,           // bit 5 (always 1 when pushed)
	Overflow,         // bit 6
	Negative,         // bit 7
}

CPU_Flags :: bit_set[CPU_Flag; u8]

CPU :: struct {
	a, x, y: u8,       // Registers
	sp:      u8,        // Stack pointer
	pc:      u16,       // Program counter
	status:  CPU_Flags, // Processor status (P register)
	cycles:  u64,       // Total elapsed cycles
	stall:   u16,       // Remaining stall cycles (for DMA etc.)
}

cpu_init :: proc(cpu: ^CPU) {
	cpu.a = 0
	cpu.x = 0
	cpu.y = 0
	cpu.sp = 0xFD
	cpu.status = {.Interrupt_Disable, .Unused}
	cpu.cycles = 7 // Reset takes 7 cycles
	cpu.stall = 0
}

cpu_reset :: proc(cpu: ^CPU, bus: ^Bus) {
	// Read reset vector
	lo := u16(bus_read(bus, 0xFFFC))
	hi := u16(bus_read(bus, 0xFFFD))
	cpu.pc = hi << 8 | lo

	cpu.sp -= 3 // Reset decrements SP by 3 but doesn't write
	cpu.status += {.Interrupt_Disable}
	cpu.cycles = 7
}

// Stack operations — stack lives at $0100-$01FF
cpu_push :: proc(cpu: ^CPU, bus: ^Bus, val: u8) {
	bus_write(bus, 0x0100 + u16(cpu.sp), val)
	cpu.sp -= 1
}

cpu_push16 :: proc(cpu: ^CPU, bus: ^Bus, val: u16) {
	cpu_push(cpu, bus, u8(val >> 8))   // High byte first
	cpu_push(cpu, bus, u8(val & 0xFF)) // Low byte second
}

cpu_pop :: proc(cpu: ^CPU, bus: ^Bus) -> u8 {
	cpu.sp += 1
	return bus_read(bus, 0x0100 + u16(cpu.sp))
}

cpu_pop16 :: proc(cpu: ^CPU, bus: ^Bus) -> u16 {
	lo := u16(cpu_pop(cpu, bus))
	hi := u16(cpu_pop(cpu, bus))
	return hi << 8 | lo
}

// Flag helpers
cpu_set_zn :: proc(cpu: ^CPU, val: u8) {
	if val == 0 {
		cpu.status += {.Zero}
	} else {
		cpu.status -= {.Zero}
	}
	if val & 0x80 != 0 {
		cpu.status += {.Negative}
	} else {
		cpu.status -= {.Negative}
	}
}

// Convert status to/from u8 for stack push/pop
cpu_flags_to_u8 :: proc(flags: CPU_Flags) -> u8 {
	return transmute(u8)flags | 0x20 // Bit 5 always set
}

cpu_u8_to_flags :: proc(val: u8) -> CPU_Flags {
	return transmute(CPU_Flags)(val & 0xEF | 0x20) // Clear break, set unused
}

// NMI: Non-Maskable Interrupt
cpu_nmi :: proc(cpu: ^CPU, bus: ^Bus) {
	cpu_push16(cpu, bus, cpu.pc)
	cpu_push(cpu, bus, cpu_flags_to_u8(cpu.status - {.Break}))
	cpu.status += {.Interrupt_Disable}
	lo := u16(bus_read(bus, 0xFFFA))
	hi := u16(bus_read(bus, 0xFFFB))
	cpu.pc = hi << 8 | lo
	cpu.cycles += 7
}

// IRQ: Interrupt Request
cpu_irq :: proc(cpu: ^CPU, bus: ^Bus) {
	if .Interrupt_Disable in cpu.status {
		return
	}
	cpu_push16(cpu, bus, cpu.pc)
	cpu_push(cpu, bus, cpu_flags_to_u8(cpu.status - {.Break}))
	cpu.status += {.Interrupt_Disable}
	lo := u16(bus_read(bus, 0xFFFE))
	hi := u16(bus_read(bus, 0xFFFF))
	cpu.pc = hi << 8 | lo
	cpu.cycles += 7
}
