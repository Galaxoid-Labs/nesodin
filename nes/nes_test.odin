package nes

import "core:testing"
import "mappers"

// ---- Test Helpers ----

// Backing store for test PRG ROM (heap-allocated to avoid stack overflow)
Test_PRG :: struct {
	data: [16384]u8,
}

// Create a minimal test NES with a small PRG ROM — heap-allocated
make_test_nes :: proc(prg: []u8) -> (console: ^NES, prg_store: ^Test_PRG) {
	prg_store = new(Test_PRG)
	for i in 0..<min(len(prg), 16384) {
		prg_store.data[i] = prg[i]
	}

	console = new(NES)
	console.cartridge.prg_rom = prg_store.data[:]
	console.cartridge.prg_banks = 1
	console.cartridge.chr_banks = 0
	console.cartridge.chr_rom = console.cartridge.chr_ram[:]
	console.cartridge.mapper_id = 0
	console.cartridge.mirror_mode = .Horizontal
	console.cartridge.mapper = mappers.mapper_000_init(
		console.cartridge.prg_rom,
		console.cartridge.chr_rom,
		1,
		true,
	)

	ppu_init(&console.ppu, &console.cartridge)
	bus_init(&console.bus, &console.cartridge, &console.ppu, &console.cpu)

	return
}

destroy_test_nes :: proc(console: ^NES, prg_store: ^Test_PRG) {
	free(console)
	free(prg_store)
}

// Set reset vector to point to $8000 (start of PRG ROM)
set_reset_vector :: proc(console: ^NES) {
	prg := console.cartridge.prg_rom
	prg[0x3FFC] = 0x00 // Low byte → $8000
	prg[0x3FFD] = 0x80 // High byte
}

// Helper: init + reset CPU with reset vector at $8000
setup_cpu :: proc(console: ^NES) {
	set_reset_vector(console)
	cpu_init(&console.cpu)
	cpu_reset(&console.cpu, &console.bus)
}

// ---- Cartridge Tests ----

@(test)
test_ines_magic_validation :: proc(t: ^testing.T) {
	bad_data := []u8{0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, 0}
	_, err := cartridge_load_from_bytes(bad_data)
	testing.expect_value(t, err, Cartridge_Error.Invalid_Magic)
}

@(test)
test_ines_too_small :: proc(t: ^testing.T) {
	_, err := cartridge_load_from_bytes([]u8{0x4E, 0x45, 0x53})
	testing.expect_value(t, err, Cartridge_Error.File_Too_Small)
}

@(test)
test_ines_valid_header :: proc(t: ^testing.T) {
	data := make([]u8, 16 + 16384 + 8192)
	defer delete(data)
	data[0] = 0x4E; data[1] = 0x45; data[2] = 0x53; data[3] = 0x1A
	data[4] = 1    // 1x 16KB PRG
	data[5] = 1    // 1x 8KB CHR
	data[6] = 0x01 // Vertical mirroring

	cart, err := cartridge_load_from_bytes(data)
	testing.expect_value(t, err, Cartridge_Error.None)
	testing.expect_value(t, cart.prg_banks, 1)
	testing.expect_value(t, cart.chr_banks, 1)
	testing.expect_value(t, cart.mapper_id, 0)
	testing.expect_value(t, cart.mirror_mode, mappers.Mirror_Mode.Vertical)
	testing.expect_value(t, len(cart.prg_rom), 16384)
	testing.expect_value(t, len(cart.chr_rom), 8192)
}

@(test)
test_ines_chr_ram :: proc(t: ^testing.T) {
	data := make([]u8, 16 + 16384)
	defer delete(data)
	data[0] = 0x4E; data[1] = 0x45; data[2] = 0x53; data[3] = 0x1A
	data[4] = 1; data[5] = 0

	cart, err := cartridge_load_from_bytes(data)
	testing.expect_value(t, err, Cartridge_Error.None)
	testing.expect_value(t, cart.chr_banks, 0)
	testing.expect_value(t, len(cart.chr_rom), 8192)
}

@(test)
test_ines_mapper_extraction :: proc(t: ^testing.T) {
	data := make([]u8, 16 + 16384)
	defer delete(data)
	data[0] = 0x4E; data[1] = 0x45; data[2] = 0x53; data[3] = 0x1A
	data[4] = 1; data[5] = 0
	data[6] = 0x10 // Mapper low nibble = 1
	data[7] = 0x20 // Mapper high nibble = 2 → mapper 0x21 = 33

	_, err := cartridge_load_from_bytes(data)
	testing.expect_value(t, err, Cartridge_Error.Unsupported_Mapper)
}

// ---- CPU Tests ----

@(test)
test_cpu_init :: proc(t: ^testing.T) {
	cpu: CPU
	cpu_init(&cpu)
	testing.expect_value(t, cpu.a, 0)
	testing.expect_value(t, cpu.x, 0)
	testing.expect_value(t, cpu.y, 0)
	testing.expect_value(t, cpu.sp, 0xFD)
	testing.expect(t, .Interrupt_Disable in cpu.status, "interrupt disable should be set")
	testing.expect(t, .Unused in cpu.status, "unused flag should be set")
}

@(test)
test_cpu_reset_reads_vector :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)
	testing.expect_value(t, console.cpu.pc, 0x8000)
}

@(test)
test_cpu_lda_immediate :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xA9, 0x42})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cycles := cpu_step(&console.cpu, &console.bus)

	testing.expect_value(t, console.cpu.a, 0x42)
	testing.expect_value(t, cycles, 2)
	testing.expect(t, .Zero not_in console.cpu.status, "zero should not be set")
	testing.expect(t, .Negative not_in console.cpu.status, "negative should not be set")
}

@(test)
test_cpu_lda_zero_flag :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xA9, 0x00})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus)
	testing.expect_value(t, console.cpu.a, 0x00)
	testing.expect(t, .Zero in console.cpu.status, "zero flag should be set")
}

@(test)
test_cpu_lda_negative_flag :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xA9, 0x80})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus)
	testing.expect(t, .Negative in console.cpu.status, "negative flag should be set")
}

@(test)
test_cpu_ldx_immediate :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xA2, 0x10})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus)
	testing.expect_value(t, console.cpu.x, 0x10)
}

@(test)
test_cpu_ldy_immediate :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xA0, 0x20})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus)
	testing.expect_value(t, console.cpu.y, 0x20)
}

@(test)
test_cpu_sta_zeropage :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xA9, 0xFF, 0x85, 0x10})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus) // LDA
	cpu_step(&console.cpu, &console.bus) // STA
	testing.expect_value(t, console.bus.ram[0x10], 0xFF)
}

@(test)
test_cpu_transfers :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xA9, 0x42, 0xAA, 0xA8})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus) // LDA #$42
	cpu_step(&console.cpu, &console.bus) // TAX
	cpu_step(&console.cpu, &console.bus) // TAY

	testing.expect_value(t, console.cpu.x, 0x42)
	testing.expect_value(t, console.cpu.y, 0x42)
}

@(test)
test_cpu_adc_basic :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0x18, 0xA9, 0x10, 0x69, 0x20})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus) // CLC
	cpu_step(&console.cpu, &console.bus) // LDA #$10
	cpu_step(&console.cpu, &console.bus) // ADC #$20

	testing.expect_value(t, console.cpu.a, 0x30)
	testing.expect(t, .Carry not_in console.cpu.status, "carry should not be set")
}

@(test)
test_cpu_adc_carry :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0x18, 0xA9, 0xFF, 0x69, 0x01})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus) // CLC
	cpu_step(&console.cpu, &console.bus) // LDA #$FF
	cpu_step(&console.cpu, &console.bus) // ADC #$01

	testing.expect_value(t, console.cpu.a, 0x00)
	testing.expect(t, .Carry in console.cpu.status, "carry should be set")
	testing.expect(t, .Zero in console.cpu.status, "zero should be set")
}

@(test)
test_cpu_adc_overflow :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0x18, 0xA9, 0x7F, 0x69, 0x01})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus) // CLC
	cpu_step(&console.cpu, &console.bus) // LDA #$7F
	cpu_step(&console.cpu, &console.bus) // ADC #$01

	testing.expect_value(t, console.cpu.a, 0x80)
	testing.expect(t, .Overflow in console.cpu.status, "overflow should be set")
	testing.expect(t, .Negative in console.cpu.status, "negative should be set")
}

@(test)
test_cpu_sbc :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0x38, 0xA9, 0x30, 0xE9, 0x10})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus) // SEC
	cpu_step(&console.cpu, &console.bus) // LDA #$30
	cpu_step(&console.cpu, &console.bus) // SBC #$10

	testing.expect_value(t, console.cpu.a, 0x20)
	testing.expect(t, .Carry in console.cpu.status, "carry should be set (no borrow)")
}

@(test)
test_cpu_and :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xA9, 0xFF, 0x29, 0x0F})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus)
	cpu_step(&console.cpu, &console.bus)
	testing.expect_value(t, console.cpu.a, 0x0F)
}

@(test)
test_cpu_ora :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xA9, 0xF0, 0x09, 0x0F})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus)
	cpu_step(&console.cpu, &console.bus)
	testing.expect_value(t, console.cpu.a, 0xFF)
}

@(test)
test_cpu_eor :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xA9, 0xFF, 0x49, 0xFF})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus)
	cpu_step(&console.cpu, &console.bus)
	testing.expect_value(t, console.cpu.a, 0x00)
	testing.expect(t, .Zero in console.cpu.status, "zero should be set")
}

@(test)
test_cpu_asl_accumulator :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xA9, 0x81, 0x0A})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus)
	cpu_step(&console.cpu, &console.bus)
	testing.expect_value(t, console.cpu.a, 0x02)
	testing.expect(t, .Carry in console.cpu.status, "carry should be set from bit 7")
}

@(test)
test_cpu_lsr_accumulator :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xA9, 0x03, 0x4A})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus)
	cpu_step(&console.cpu, &console.bus)
	testing.expect_value(t, console.cpu.a, 0x01)
	testing.expect(t, .Carry in console.cpu.status, "carry should be set from bit 0")
}

@(test)
test_cpu_rol_accumulator :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0x38, 0xA9, 0x80, 0x2A})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus) // SEC
	cpu_step(&console.cpu, &console.bus) // LDA #$80
	cpu_step(&console.cpu, &console.bus) // ROL A
	testing.expect_value(t, console.cpu.a, 0x01)
	testing.expect(t, .Carry in console.cpu.status, "carry should be set")
}

@(test)
test_cpu_ror_accumulator :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0x38, 0xA9, 0x01, 0x6A})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus) // SEC
	cpu_step(&console.cpu, &console.bus) // LDA #$01
	cpu_step(&console.cpu, &console.bus) // ROR A
	testing.expect_value(t, console.cpu.a, 0x80)
	testing.expect(t, .Carry in console.cpu.status, "carry should be set from bit 0")
}

@(test)
test_cpu_inc_dec :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xA9, 0x05, 0x85, 0x10, 0xE6, 0x10, 0xE6, 0x10, 0xC6, 0x10})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus) // LDA
	cpu_step(&console.cpu, &console.bus) // STA
	cpu_step(&console.cpu, &console.bus) // INC
	cpu_step(&console.cpu, &console.bus) // INC
	cpu_step(&console.cpu, &console.bus) // DEC
	testing.expect_value(t, console.bus.ram[0x10], 0x06)
}

@(test)
test_cpu_inx_dex :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xA2, 0x00, 0xE8, 0xE8, 0xCA})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus) // LDX
	cpu_step(&console.cpu, &console.bus) // INX
	cpu_step(&console.cpu, &console.bus) // INX
	cpu_step(&console.cpu, &console.bus) // DEX
	testing.expect_value(t, console.cpu.x, 0x01)
}

@(test)
test_cpu_cmp :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xA9, 0x10, 0xC9, 0x10})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus)
	cpu_step(&console.cpu, &console.bus)
	testing.expect(t, .Zero in console.cpu.status, "zero should be set (equal)")
	testing.expect(t, .Carry in console.cpu.status, "carry should be set (A >= M)")
}

@(test)
test_cpu_branch_beq :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xA9, 0x00, 0xF0, 0x02, 0xA9, 0xFF, 0xEA})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus) // LDA #$00
	cpu_step(&console.cpu, &console.bus) // BEQ +2
	cpu_step(&console.cpu, &console.bus) // NOP (skipped over LDA #$FF)
	testing.expect_value(t, console.cpu.a, 0x00)
}

@(test)
test_cpu_branch_bne :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xA9, 0x01, 0xD0, 0x02, 0xA9, 0xFF, 0xEA})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus) // LDA #$01
	cpu_step(&console.cpu, &console.bus) // BNE +2
	cpu_step(&console.cpu, &console.bus) // NOP
	testing.expect_value(t, console.cpu.a, 0x01)
}

@(test)
test_cpu_jmp_absolute :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)

	p := console.cartridge.prg_rom
	p[0] = 0x4C; p[1] = 0x05; p[2] = 0x80 // JMP $8005
	p[3] = 0xEA; p[4] = 0xEA               // NOPs (skipped)
	p[5] = 0xA9; p[6] = 0x42               // LDA #$42

	setup_cpu(console)
	cpu_step(&console.cpu, &console.bus) // JMP
	cpu_step(&console.cpu, &console.bus) // LDA #$42
	testing.expect_value(t, console.cpu.a, 0x42)
}

@(test)
test_cpu_jsr_rts :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)

	p := console.cartridge.prg_rom
	p[0] = 0x20; p[1] = 0x05; p[2] = 0x80 // JSR $8005
	p[3] = 0xA9; p[4] = 0x01               // LDA #$01 (return point)
	p[5] = 0xA9; p[6] = 0x42               // LDA #$42
	p[7] = 0x60                             // RTS

	setup_cpu(console)
	cpu_step(&console.cpu, &console.bus) // JSR $8005
	testing.expect_value(t, console.cpu.pc, 0x8005)

	cpu_step(&console.cpu, &console.bus) // LDA #$42
	testing.expect_value(t, console.cpu.a, 0x42)

	cpu_step(&console.cpu, &console.bus) // RTS → back to $8003
	testing.expect_value(t, console.cpu.pc, 0x8003)

	cpu_step(&console.cpu, &console.bus) // LDA #$01
	testing.expect_value(t, console.cpu.a, 0x01)
}

@(test)
test_cpu_stack_push_pop :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xA9, 0x42, 0x48, 0xA9, 0x00, 0x68})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus) // LDA #$42
	cpu_step(&console.cpu, &console.bus) // PHA
	cpu_step(&console.cpu, &console.bus) // LDA #$00
	testing.expect_value(t, console.cpu.a, 0x00)
	cpu_step(&console.cpu, &console.bus) // PLA
	testing.expect_value(t, console.cpu.a, 0x42)
}

@(test)
test_cpu_flags_clc_sec :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0x38, 0x18})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus) // SEC
	testing.expect(t, .Carry in console.cpu.status, "carry should be set")
	cpu_step(&console.cpu, &console.bus) // CLC
	testing.expect(t, .Carry not_in console.cpu.status, "carry should be clear")
}

@(test)
test_cpu_bit_instruction :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xA9, 0xC0, 0x85, 0x10, 0xA9, 0x00, 0x24, 0x10})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	cpu_step(&console.cpu, &console.bus) // LDA #$C0
	cpu_step(&console.cpu, &console.bus) // STA $10
	cpu_step(&console.cpu, &console.bus) // LDA #$00
	cpu_step(&console.cpu, &console.bus) // BIT $10

	testing.expect(t, .Negative in console.cpu.status, "N should be set (bit 7 of mem)")
	testing.expect(t, .Overflow in console.cpu.status, "V should be set (bit 6 of mem)")
	testing.expect(t, .Zero in console.cpu.status, "Z should be set (A & M == 0)")
}

// ---- Bus Tests ----

@(test)
test_bus_ram_mirroring :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)

	bus_write(&console.bus, 0x0000, 0x42)
	testing.expect_value(t, bus_read(&console.bus, 0x0000), 0x42)
	testing.expect_value(t, bus_read(&console.bus, 0x0800), 0x42)
	testing.expect_value(t, bus_read(&console.bus, 0x1000), 0x42)
	testing.expect_value(t, bus_read(&console.bus, 0x1800), 0x42)
}

@(test)
test_bus_ram_write_via_mirror :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)

	bus_write(&console.bus, 0x0800, 0xFF)
	testing.expect_value(t, bus_read(&console.bus, 0x0000), 0xFF)
}

// ---- Mapper 000 Tests ----

@(test)
test_mapper_000_prg_mirror :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{0xAB})
	defer destroy_test_nes(console, prg)

	testing.expect_value(t, bus_read(&console.bus, 0x8000), 0xAB)
	testing.expect_value(t, bus_read(&console.bus, 0xC000), 0xAB)
}

@(test)
test_mapper_000_prg_ram :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)

	bus_write(&console.bus, 0x6000, 0x42)
	testing.expect_value(t, bus_read(&console.bus, 0x6000), 0x42)
	bus_write(&console.bus, 0x7FFF, 0xFF)
	testing.expect_value(t, bus_read(&console.bus, 0x7FFF), 0xFF)
}

// ---- PPU Bus Tests ----

@(test)
test_ppu_palette_mirror :: proc(t: ^testing.T) {
	testing.expect_value(t, ppu_mirror_palette(0x3F10), 0x00)
	testing.expect_value(t, ppu_mirror_palette(0x3F14), 0x04)
	testing.expect_value(t, ppu_mirror_palette(0x3F18), 0x08)
	testing.expect_value(t, ppu_mirror_palette(0x3F1C), 0x0C)
	testing.expect_value(t, ppu_mirror_palette(0x3F01), 0x01)
}

@(test)
test_ppu_nametable_horizontal_mirror :: proc(t: ^testing.T) {
	testing.expect_value(t, ppu_mirror_nametable(.Horizontal, 0x2000), 0x0000)
	testing.expect_value(t, ppu_mirror_nametable(.Horizontal, 0x2400), 0x0000)
	testing.expect_value(t, ppu_mirror_nametable(.Horizontal, 0x2800), 0x0400)
	testing.expect_value(t, ppu_mirror_nametable(.Horizontal, 0x2C00), 0x0400)
}

@(test)
test_ppu_nametable_vertical_mirror :: proc(t: ^testing.T) {
	testing.expect_value(t, ppu_mirror_nametable(.Vertical, 0x2000), 0x0000)
	testing.expect_value(t, ppu_mirror_nametable(.Vertical, 0x2400), 0x0400)
	testing.expect_value(t, ppu_mirror_nametable(.Vertical, 0x2800), 0x0000)
	testing.expect_value(t, ppu_mirror_nametable(.Vertical, 0x2C00), 0x0400)
}

// ---- Controller Tests ----

@(test)
test_controller_read_sequence :: proc(t: ^testing.T) {
	c: Controller
	c.buttons = {.A, .Start}

	controller_write(&c, 1)
	controller_write(&c, 0)

	a     := controller_read(&c)
	b     := controller_read(&c)
	sel   := controller_read(&c)
	start := controller_read(&c)

	testing.expect_value(t, a, 1)
	testing.expect_value(t, b, 0)
	testing.expect_value(t, sel, 0)
	testing.expect_value(t, start, 1)
}

// ---- Palette Tests ----

@(test)
test_palette_to_rgba :: proc(t: ^testing.T) {
	testing.expect_value(t, palette_to_rgba(0x00), 0x626262FF)
	testing.expect_value(t, palette_to_rgba(0x20), 0xFFFFFFFF)
}

@(test)
test_palette_index_wraps :: proc(t: ^testing.T) {
	testing.expect_value(t, palette_to_rgba(0x40), palette_to_rgba(0x00))
}

// ---- PPU Register Tests ----

@(test)
test_ppu_status_clears_vblank :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)

	console.ppu.status = 0x80 // Set vblank flag
	console.ppu.nmi_occurred = true
	console.ppu.w = true

	result := ppu_cpu_read(&console.ppu, 0x2002)
	testing.expect(t, (result & 0x80) != 0, "vblank should be reported in read value")
	testing.expect(t, (console.ppu.status & 0x80) == 0, "vblank should be cleared after read")
	testing.expect(t, !console.ppu.w, "write toggle should be reset")
	testing.expect(t, !console.ppu.nmi_occurred, "nmi_occurred should be cleared")
}

@(test)
test_ppu_ppuaddr_write :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)

	// Write $2100 to PPUADDR
	ppu_cpu_write(&console.ppu, 0x2006, 0x21) // High byte
	ppu_cpu_write(&console.ppu, 0x2006, 0x00) // Low byte

	testing.expect_value(t, console.ppu.v, 0x2100)
	testing.expect(t, !console.ppu.w, "write toggle should be reset after two writes")
}

@(test)
test_ppu_ppudata_write_read :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)

	// Write to palette RAM ($3F00) — palette reads are immediate
	ppu_cpu_write(&console.ppu, 0x2006, 0x3F) // High
	ppu_cpu_write(&console.ppu, 0x2006, 0x00) // Low → $3F00
	ppu_cpu_write(&console.ppu, 0x2007, 0x15) // Write color index

	// Read it back — need to set address again
	ppu_cpu_write(&console.ppu, 0x2006, 0x3F)
	ppu_cpu_write(&console.ppu, 0x2006, 0x00)
	val := ppu_cpu_read(&console.ppu, 0x2007) // Palette reads are immediate

	testing.expect_value(t, val, 0x15)
}

@(test)
test_ppu_ppudata_buffered_read :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)

	// Write to nametable RAM
	ppu_cpu_write(&console.ppu, 0x2006, 0x20)
	ppu_cpu_write(&console.ppu, 0x2006, 0x00) // $2000
	ppu_cpu_write(&console.ppu, 0x2007, 0xAB)

	// Read it back — first read returns buffer (stale), second returns actual
	ppu_cpu_write(&console.ppu, 0x2006, 0x20)
	ppu_cpu_write(&console.ppu, 0x2006, 0x00)
	_ = ppu_cpu_read(&console.ppu, 0x2007) // Dummy read (fills buffer)
	val := ppu_cpu_read(&console.ppu, 0x2007) // Real read from buffer

	testing.expect_value(t, val, 0xAB)
}

@(test)
test_ppu_scroll_write :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)

	ppu_cpu_write(&console.ppu, 0x2005, 0x7D) // X scroll = 125 → coarse X = 15, fine X = 5
	testing.expect_value(t, console.ppu.x_fine, 5)
	testing.expect_value(t, console.ppu.t & 0x001F, 15)
	testing.expect(t, console.ppu.w, "toggle should be set after first write")

	ppu_cpu_write(&console.ppu, 0x2005, 0x5E) // Y scroll = 94
	testing.expect(t, !console.ppu.w, "toggle should be reset after second write")
}

@(test)
test_ppu_ctrl_nametable_bits :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)

	ppu_cpu_write(&console.ppu, 0x2000, 0x02) // Nametable select = 2
	testing.expect_value(t, (console.ppu.t >> 10) & 0x03, 0x02)
}

// ---- PPU Scrolling Tests ----

@(test)
test_ppu_increment_x_wraps :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)

	console.ppu.v = 0x001F // Coarse X = 31
	ppu_increment_x(&console.ppu)
	testing.expect_value(t, console.ppu.v & 0x001F, 0) // Wrapped to 0
	testing.expect(t, (console.ppu.v & 0x0400) != 0, "horizontal nametable should toggle")
}

@(test)
test_ppu_increment_y_wraps :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)

	// Set fine Y = 7, coarse Y = 29 (last visible row)
	console.ppu.v = 0x7000 | (29 << 5)
	ppu_increment_y(&console.ppu)
	// Should wrap: fine Y = 0, coarse Y = 0, toggle vertical nametable
	testing.expect_value(t, console.ppu.v & 0x7000, 0) // Fine Y = 0
	testing.expect_value(t, (console.ppu.v >> 5) & 0x1F, 0) // Coarse Y = 0
	testing.expect(t, (console.ppu.v & 0x0800) != 0, "vertical nametable should toggle")
}

@(test)
test_ppu_copy_x :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)

	console.ppu.t = 0x041F // Horizontal nametable + coarse X = 31
	console.ppu.v = 0x0000
	ppu_copy_x(&console.ppu)
	testing.expect_value(t, console.ppu.v & 0x041F, 0x041F)
}

@(test)
test_ppu_copy_y :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)

	console.ppu.t = 0x7BE0
	console.ppu.v = 0x0000
	ppu_copy_y(&console.ppu)
	testing.expect_value(t, console.ppu.v & 0x7BE0, 0x7BE0)
}

// ---- PPU VBlank / NMI Tests ----

@(test)
test_ppu_vblank_sets_at_scanline_241 :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)

	// VBlank is set at scanline 241, cycle 1
	// ppu_step checks BEFORE incrementing cycle, so set cycle = 1
	console.ppu.scanline = 241
	console.ppu.cycle = 1

	ppu_step(&console.ppu)
	testing.expect(t, (console.ppu.status & 0x80) != 0, "vblank flag should be set at scanline 241, cycle 1")
	testing.expect(t, console.ppu.nmi_occurred, "nmi_occurred should be true")
	testing.expect(t, console.ppu.frame_ready, "frame should be ready")
}

@(test)
test_ppu_prerender_clears_flags :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)

	console.ppu.scanline = -1
	console.ppu.cycle = 1 // Flags clear at cycle 1
	console.ppu.status = 0xE0 // Set vblank, sprite 0, overflow
	console.ppu.nmi_occurred = true

	ppu_step(&console.ppu)
	testing.expect_value(t, console.ppu.status & 0xE0, 0)
	testing.expect(t, !console.ppu.nmi_occurred, "nmi_occurred should be cleared")
}

@(test)
test_ppu_nmi_triggers_when_enabled :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)

	// Enable NMI output
	console.ppu.nmi_output = true
	console.ppu.nmi_previous = false

	// Simulate VBlank occurring
	console.ppu.nmi_occurred = true
	ppu_nmi_change(&console.ppu)

	testing.expect(t, console.ppu.nmi_pending, "NMI should be pending after rising edge")
}

@(test)
test_ppu_nmi_no_trigger_when_disabled :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)

	console.ppu.nmi_output = false // NMI disabled
	console.ppu.nmi_occurred = true
	ppu_nmi_change(&console.ppu)

	testing.expect(t, !console.ppu.nmi_pending, "NMI should NOT be pending when disabled")
}

// ---- Reverse byte test (for sprite flip) ----

@(test)
test_reverse_byte :: proc(t: ^testing.T) {
	testing.expect_value(t, reverse_byte(0b10000000), 0b00000001)
	testing.expect_value(t, reverse_byte(0b11001010), 0b01010011)
	testing.expect_value(t, reverse_byte(0xFF), 0xFF)
	testing.expect_value(t, reverse_byte(0x00), 0x00)
}

// ---- NES Integration Tests ----

@(test)
test_nes_run_frame_completes :: proc(t: ^testing.T) {
	console, prg := make_test_nes([]u8{})
	defer destroy_test_nes(console, prg)
	setup_cpu(console)

	// Put an infinite loop at $8000: JMP $8000 → 4C 00 80
	console.cartridge.prg_rom[0] = 0x4C
	console.cartridge.prg_rom[1] = 0x00
	console.cartridge.prg_rom[2] = 0x80

	// PPU starts at scanline -1, frame 0. After one full frame render,
	// frame_ready is set at scanline 241, so the loop exits there.
	nes_run_frame(console)

	testing.expect(t, console.ppu.frame_ready, "frame should be complete")
	// Frame counter increments when scanline wraps from 260 to -1,
	// which happens AFTER frame_ready is set. So after nes_run_frame
	// returns (at scanline 241), the frame counter may still be 0.
	// What matters is that frame_ready was set.
	testing.expect(t, console.system_clock > 0, "system clock should advance")
}
