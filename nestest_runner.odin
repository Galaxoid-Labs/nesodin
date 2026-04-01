package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import "nes"

// Run nestest.nes in automation mode and compare against nestest.log
nestest_main :: proc() {
	// Load ROM
	cart, err := nes.cartridge_load("nestest.nes")
	if err != .None {
		fmt.eprintfln("Error loading nestest.nes: %v", err)
		os.exit(1)
	}

	// Load expected log
	log_data, log_ok := os.read_entire_file("nestest.log")
	if !log_ok {
		fmt.eprintln("Error loading nestest.log")
		os.exit(1)
	}
	defer delete(log_data)

	log_lines := strings.split(string(log_data), "\n")
	defer delete(log_lines)

	// Init NES
	console := new(nes.NES)
	defer free(console)
	nes.nes_init(console, cart)

	// Automation mode: override reset state
	console.cpu.pc = 0xC000
	console.cpu.sp = 0xFD
	console.cpu.status = transmute(nes.CPU_Flags)u8(0x24)
	console.cpu.cycles = 7

	passed := 0
	failed := 0
	total_lines := min(len(log_lines), 8991)

	for i in 0..<total_lines {
		if len(log_lines[i]) < 50 { continue }

		// Generate our CPU state line BEFORE executing instruction
		our_line := format_cpu_state(&console.cpu, &console.bus, &console.ppu)
		defer delete(our_line)

		// Parse expected values from log line
		expected := log_lines[i]

		// Compare PC, A, X, Y, P, SP, CYC
		match := compare_lines(our_line, expected)

		if !match {
			if failed < 20 {
				fmt.printfln("MISMATCH at line %d:", i + 1)
				fmt.printfln("  Expected: %s", expected[:min(len(expected), 80)])
				fmt.printfln("  Got:      %s", our_line[:min(len(our_line), 80)])
			}
			failed += 1
		} else {
			passed += 1
		}

		// Execute one instruction
		nes.cpu_step(&console.cpu, &console.bus)
	}

	fmt.printfln("\nNestest Results: %d passed, %d failed out of %d", passed, failed, passed + failed)

	// Check result codes
	result_02 := nes.bus_read(&console.bus, 0x0002)
	result_03 := nes.bus_read(&console.bus, 0x0003)
	if result_02 == 0 && result_03 == 0 {
		fmt.println("Test status: PASSED (both $02 and $03 are $00)")
	} else {
		fmt.printfln("Test status: FAILED ($02=$%02X, $03=$%02X)", result_02, result_03)
	}
}

format_cpu_state :: proc(cpu: ^nes.CPU, bus: ^nes.Bus, ppu: ^nes.PPU) -> string {
	// Read opcode bytes for display
	op0 := nes.bus_read(bus, cpu.pc)
	table := nes.OPCODE_TABLE
	info := table[op0]

	// Format: "C000  4C F5 C5  JMP $C5F5                       A:00 X:00 Y:00 P:24 SP:FD PPU:  0, 21 CYC:7"
	b := strings.builder_make()

	// PC
	fmt.sbprintf(&b, "%4X  ", cpu.pc)

	// Opcode bytes (1-3)
	op_len := addr_mode_len(info.mode)
	bytes_str: string
	switch op_len {
	case 1:
		bytes_str = fmt.tprintf("%02X       ", op0)
	case 2:
		op1 := nes.bus_read(bus, cpu.pc + 1)
		bytes_str = fmt.tprintf("%02X %02X    ", op0, op1)
	case 3:
		op1 := nes.bus_read(bus, cpu.pc + 1)
		op2 := nes.bus_read(bus, cpu.pc + 2)
		bytes_str = fmt.tprintf("%02X %02X %02X ", op0, op1, op2)
	}
	fmt.sbprintf(&b, "%s", bytes_str)

	// Mnemonic + operand (padded to 32 chars from start of mnemonic)
	mnemonic := format_mnemonic(cpu, bus, info, op0)
	defer delete(mnemonic)
	fmt.sbprintf(&b, "%-32s", mnemonic)

	// Registers
	p_val := nes.cpu_flags_to_u8(cpu.status)
	fmt.sbprintf(&b, "A:%02X X:%02X Y:%02X P:%02X SP:%02X ", cpu.a, cpu.x, cpu.y, p_val, cpu.sp)

	// PPU state — match nestest.log format "PPU:  0, 21"
	fmt.sbprintf(&b, "PPU:%3d,%3d ", i16(ppu.scanline), ppu.cycle)

	// Cycle count
	fmt.sbprintf(&b, "CYC:%d", cpu.cycles)

	return strings.to_string(b)
}

addr_mode_len :: proc(mode: nes.Addr_Mode) -> int {
	switch mode {
	case .IMP, .ACC: return 1
	case .IMM, .ZPG, .ZPX, .ZPY, .IZX, .IZY, .REL: return 2
	case .ABS, .ABX, .ABY, .IND: return 3
	}
	return 1
}

format_mnemonic :: proc(cpu: ^nes.CPU, bus: ^nes.Bus, info: nes.Opcode, op: u8) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "%s ", info.name)

	switch info.mode {
	case .IMP:
		// nothing
	case .ACC:
		fmt.sbprintf(&b, "A")
	case .IMM:
		val := nes.bus_read(bus, cpu.pc + 1)
		fmt.sbprintf(&b, "#$%02X", val)
	case .ZPG:
		addr := nes.bus_read(bus, cpu.pc + 1)
		val := nes.bus_read(bus, u16(addr))
		fmt.sbprintf(&b, "$%02X = %02X", addr, val)
	case .ZPX:
		addr := nes.bus_read(bus, cpu.pc + 1)
		eff := (addr + cpu.x) & 0xFF
		val := nes.bus_read(bus, u16(eff))
		fmt.sbprintf(&b, "$%02X,X @ %02X = %02X", addr, eff, val)
	case .ZPY:
		addr := nes.bus_read(bus, cpu.pc + 1)
		eff := (addr + cpu.y) & 0xFF
		val := nes.bus_read(bus, u16(eff))
		fmt.sbprintf(&b, "$%02X,Y @ %02X = %02X", addr, eff, val)
	case .ABS:
		lo := nes.bus_read(bus, cpu.pc + 1)
		hi := nes.bus_read(bus, cpu.pc + 2)
		addr := u16(hi) << 8 | u16(lo)
		if info.name == "JMP" || info.name == "JSR" {
			fmt.sbprintf(&b, "$%04X", addr)
		} else {
			val := nes.bus_read(bus, addr)
			fmt.sbprintf(&b, "$%04X = %02X", addr, val)
		}
	case .ABX:
		lo := nes.bus_read(bus, cpu.pc + 1)
		hi := nes.bus_read(bus, cpu.pc + 2)
		base := u16(hi) << 8 | u16(lo)
		eff := base + u16(cpu.x)
		val := nes.bus_read(bus, eff)
		fmt.sbprintf(&b, "$%04X,X @ %04X = %02X", base, eff, val)
	case .ABY:
		lo := nes.bus_read(bus, cpu.pc + 1)
		hi := nes.bus_read(bus, cpu.pc + 2)
		base := u16(hi) << 8 | u16(lo)
		eff := base + u16(cpu.y)
		val := nes.bus_read(bus, eff)
		fmt.sbprintf(&b, "$%04X,Y @ %04X = %02X", base, eff, val)
	case .IND:
		lo := nes.bus_read(bus, cpu.pc + 1)
		hi := nes.bus_read(bus, cpu.pc + 2)
		addr := u16(hi) << 8 | u16(lo)
		// JMP indirect bug
		eff_lo := u16(nes.bus_read(bus, addr))
		eff_hi: u16
		if lo == 0xFF {
			eff_hi = u16(nes.bus_read(bus, addr & 0xFF00))
		} else {
			eff_hi = u16(nes.bus_read(bus, addr + 1))
		}
		eff := eff_hi << 8 | eff_lo
		fmt.sbprintf(&b, "($%04X) = %04X", addr, eff)
	case .IZX:
		zp := nes.bus_read(bus, cpu.pc + 1)
		ptr := (zp + cpu.x) & 0xFF
		lo := u16(nes.bus_read(bus, u16(ptr)))
		hi := u16(nes.bus_read(bus, u16((ptr + 1) & 0xFF)))
		eff := hi << 8 | lo
		val := nes.bus_read(bus, eff)
		fmt.sbprintf(&b, "($%02X,X) @ %02X = %04X = %02X", zp, ptr, eff, val)
	case .IZY:
		zp := nes.bus_read(bus, cpu.pc + 1)
		lo := u16(nes.bus_read(bus, u16(zp)))
		hi := u16(nes.bus_read(bus, u16((zp + 1) & 0xFF)))
		base := hi << 8 | lo
		eff := base + u16(cpu.y)
		val := nes.bus_read(bus, eff)
		fmt.sbprintf(&b, "($%02X),Y = %04X @ %04X = %02X", zp, base, eff, val)
	case .REL:
		offset := nes.bus_read(bus, cpu.pc + 1)
		target: u16
		if offset & 0x80 != 0 {
			target = cpu.pc + 2 + u16(offset) - 256
		} else {
			target = cpu.pc + 2 + u16(offset)
		}
		fmt.sbprintf(&b, "$%04X", target)
	}

	return strings.to_string(b)
}

compare_lines :: proc(ours: string, expected: string) -> bool {
	if len(ours) < 70 || len(expected) < 70 { return false }

	// Compare PC (chars 0-3)
	if ours[:4] != expected[:4] { return false }

	// Compare A, X, Y, P, SP — find them by marker
	our_a := find_field(ours, "A:")
	exp_a := find_field(expected, "A:")
	if our_a != exp_a { return false }

	our_x := find_field(ours, "X:")
	exp_x := find_field(expected, "X:")
	if our_x != exp_x { return false }

	our_y := find_field(ours, "Y:")
	exp_y := find_field(expected, "Y:")
	if our_y != exp_y { return false }

	our_p := find_field(ours, "P:")
	exp_p := find_field(expected, "P:")
	if our_p != exp_p { return false }

	our_sp := find_field(ours, "SP:")
	exp_sp := find_field(expected, "SP:")
	if our_sp != exp_sp { return false }

	// Compare CYC
	our_cyc := find_field(ours, "CYC:")
	exp_cyc := find_field(expected, "CYC:")
	if our_cyc != exp_cyc { return false }

	return true
}

find_field :: proc(line: string, marker: string) -> string {
	idx := strings.index(line, marker)
	if idx < 0 { return "" }
	start := idx + len(marker)
	end := start
	for end < len(line) && line[end] != ' ' && line[end] != '\n' && line[end] != '\r' {
		end += 1
	}
	return line[start:end]
}
