package nes

import "core:fmt"
import "core:os"
import "mappers"

INES_MAGIC :: [4]u8{0x4E, 0x45, 0x53, 0x1A} // "NES\x1a"

Cartridge_Error :: enum {
	None,
	File_Not_Found,
	File_Too_Small,
	Invalid_Magic,
	Unsupported_Mapper,
	Invalid_ROM_Size,
}

Cartridge :: struct {
	prg_rom:     []u8,
	chr_rom:     []u8, // CHR ROM data (or CHR RAM backing)
	chr_ram:     [8192]u8, // CHR RAM backing store (used when cart has no CHR ROM)
	mapper_id:   u8,
	mirror_mode: mappers.Mirror_Mode,
	has_battery: bool,
	mapper:      mappers.Mapper,

	// Header info for display
	prg_banks:   u8, // In 16KB units
	chr_banks:   u8, // In 8KB units
}

cartridge_load :: proc(path: string) -> (cart: Cartridge, err: Cartridge_Error) {
	data, ok := os.read_entire_file(path)
	if !ok {
		return {}, .File_Not_Found
	}

	return cartridge_load_from_bytes(data)
}

cartridge_load_from_bytes :: proc(data: []u8) -> (cart: Cartridge, err: Cartridge_Error) {
	if len(data) < 16 {
		return {}, .File_Too_Small
	}

	// Validate magic bytes
	magic: [4]u8 = {data[0], data[1], data[2], data[3]}
	if magic != INES_MAGIC {
		return {}, .Invalid_Magic
	}

	prg_banks := data[4]  // In 16KB units
	chr_banks := data[5]  // In 8KB units (0 = CHR RAM)
	flags6 := data[6]
	flags7 := data[7]

	mapper_id := (flags7 & 0xF0) | (flags6 >> 4)
	has_trainer := (flags6 & 0x04) != 0
	has_battery := (flags6 & 0x02) != 0

	mirror_mode: mappers.Mirror_Mode
	if (flags6 & 0x08) != 0 {
		mirror_mode = .Four_Screen
	} else if (flags6 & 0x01) != 0 {
		mirror_mode = .Vertical
	} else {
		mirror_mode = .Horizontal
	}

	// Calculate data offsets
	offset: int = 16
	if has_trainer {
		offset += 512
	}

	prg_size := int(prg_banks) * 16384
	chr_size := int(chr_banks) * 8192

	if len(data) < offset + prg_size + chr_size {
		return {}, .Invalid_ROM_Size
	}

	prg_rom := data[offset:][:prg_size]
	offset += prg_size

	has_chr_ram := chr_banks == 0

	cart.prg_rom = prg_rom
	cart.prg_banks = prg_banks
	cart.chr_banks = chr_banks
	cart.mapper_id = mapper_id
	cart.mirror_mode = mirror_mode
	cart.has_battery = has_battery

	if has_chr_ram {
		// Initialize CHR RAM with $FF pattern — real NES hardware
		// powers on with non-zero random data. Some games (e.g.
		// Battletoads) rely on tile $00 being non-transparent at
		// startup for sprite 0 hit detection.
		for i in 0..<len(cart.chr_ram) {
			cart.chr_ram[i] = 0xFF
		}
		cart.chr_rom = cart.chr_ram[:]
	} else {
		cart.chr_rom = data[offset:][:chr_size]
	}

	// Create mapper
	switch mapper_id {
	case 0:
		cart.mapper = mappers.mapper_000_init(
			prg_rom, cart.chr_rom, prg_banks, has_chr_ram,
		)
	case 1:
		cart.mapper = mappers.mapper_001_init(
			prg_rom, cart.chr_rom, prg_banks, chr_banks, has_chr_ram, mirror_mode,
		)
	case 2:
		cart.mapper = mappers.mapper_002_init(
			prg_rom, cart.chr_rom, prg_banks, has_chr_ram,
		)
	case 3:
		cart.mapper = mappers.mapper_003_init(
			prg_rom, cart.chr_rom, prg_banks,
		)
	case 4:
		cart.mapper = mappers.mapper_004_init(
			prg_rom, cart.chr_rom, prg_banks, chr_banks, has_chr_ram, mirror_mode,
		)
	case 7:
		cart.mapper = mappers.mapper_007_init(
			prg_rom, cart.chr_rom, prg_banks, has_chr_ram,
		)
	case 9:
		cart.mapper = mappers.mapper_009_init(
			prg_rom, cart.chr_rom, prg_banks, mirror_mode,
		)
	case 10:
		cart.mapper = mappers.mapper_010_init(
			prg_rom, cart.chr_rom, prg_banks, mirror_mode,
		)
	case 11:
		cart.mapper = mappers.mapper_011_init(
			prg_rom, cart.chr_rom, prg_banks,
		)
	case 66:
		cart.mapper = mappers.mapper_066_init(
			prg_rom, cart.chr_rom, prg_banks,
		)
	case 71:
		cart.mapper = mappers.mapper_071_init(
			prg_rom, cart.chr_rom, prg_banks, has_chr_ram, mirror_mode,
		)
	case:
		return {}, .Unsupported_Mapper
	}

	return cart, .None
}

// Re-initialize the mapper with the cartridge's current slice pointers.
// Must be called after copying the cartridge struct to fix dangling slices.
cartridge_init_mapper :: proc(cart: ^Cartridge) {
	has_chr_ram := cart.chr_banks == 0
	switch cart.mapper_id {
	case 0:
		cart.mapper = mappers.mapper_000_init(
			cart.prg_rom, cart.chr_rom, cart.prg_banks, has_chr_ram,
		)
	case 1:
		cart.mapper = mappers.mapper_001_init(
			cart.prg_rom, cart.chr_rom, cart.prg_banks, cart.chr_banks, has_chr_ram, cart.mirror_mode,
		)
	case 2:
		cart.mapper = mappers.mapper_002_init(
			cart.prg_rom, cart.chr_rom, cart.prg_banks, has_chr_ram,
		)
	case 3:
		cart.mapper = mappers.mapper_003_init(
			cart.prg_rom, cart.chr_rom, cart.prg_banks,
		)
	case 4:
		cart.mapper = mappers.mapper_004_init(
			cart.prg_rom, cart.chr_rom, cart.prg_banks, cart.chr_banks,
			cart.chr_banks == 0, cart.mirror_mode,
		)
	case 7:
		cart.mapper = mappers.mapper_007_init(
			cart.prg_rom, cart.chr_rom, cart.prg_banks, has_chr_ram,
		)
	case 9:
		cart.mapper = mappers.mapper_009_init(
			cart.prg_rom, cart.chr_rom, cart.prg_banks, cart.mirror_mode,
		)
	case 10:
		cart.mapper = mappers.mapper_010_init(
			cart.prg_rom, cart.chr_rom, cart.prg_banks, cart.mirror_mode,
		)
	case 11:
		cart.mapper = mappers.mapper_011_init(
			cart.prg_rom, cart.chr_rom, cart.prg_banks,
		)
	case 66:
		cart.mapper = mappers.mapper_066_init(
			cart.prg_rom, cart.chr_rom, cart.prg_banks,
		)
	case 71:
		cart.mapper = mappers.mapper_071_init(
			cart.prg_rom, cart.chr_rom, cart.prg_banks, has_chr_ram, cart.mirror_mode,
		)
	}
}

// Get a pointer to the mapper's PRG RAM (for battery save)
// Returns nil if the mapper doesn't have PRG RAM
cartridge_get_prg_ram :: proc(cart: ^Cartridge) -> []u8 {
	switch &m in cart.mapper {
	case mappers.Mapper_000: return m.prg_ram[:]
	case mappers.Mapper_001: return m.prg_ram[:]
	case mappers.Mapper_004: return m.prg_ram[:]
	case mappers.Mapper_010: return m.prg_ram[:]
	case mappers.Mapper_002, mappers.Mapper_003, mappers.Mapper_007,
	     mappers.Mapper_009, mappers.Mapper_011, mappers.Mapper_066,
	     mappers.Mapper_071:
		return nil
	}
	return nil
}

// Load battery save from .sav file into PRG RAM
cartridge_load_sram :: proc(cart: ^Cartridge, sav_path: string) -> bool {
	if !cart.has_battery { return false }
	ram := cartridge_get_prg_ram(cart)
	if ram == nil { return false }

	data, ok := os.read_entire_file(sav_path)
	if !ok { return false }
	defer delete(data)

	copy_len := min(len(data), len(ram))
	for i in 0..<copy_len {
		ram[i] = data[i]
	}
	fmt.printfln("Loaded battery save: %s (%d bytes)", sav_path, copy_len)
	return true
}

// Save PRG RAM to .sav file
cartridge_save_sram :: proc(cart: ^Cartridge, sav_path: string) -> bool {
	if !cart.has_battery { return false }
	ram := cartridge_get_prg_ram(cart)
	if ram == nil { return false }

	ok := os.write_entire_file(sav_path, ram)
	if ok {
		fmt.printfln("Saved battery save: %s", sav_path)
	}
	return ok
}

cartridge_print_info :: proc(cart: ^Cartridge) {
	fmt.println("=== Cartridge Info ===")
	fmt.printfln("  PRG ROM: %d x 16KB = %dKB", cart.prg_banks, int(cart.prg_banks) * 16)
	if cart.chr_banks == 0 {
		fmt.println("  CHR RAM: 8KB")
	} else {
		fmt.printfln("  CHR ROM: %d x 8KB = %dKB", cart.chr_banks, int(cart.chr_banks) * 8)
	}
	fmt.printfln("  Mapper:  %d", cart.mapper_id)
	fmt.printfln("  Mirror:  %v", cart.mirror_mode)
	fmt.printfln("  Battery: %v", cart.has_battery)
}
