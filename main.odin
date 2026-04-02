package main

import "core:fmt"
import "core:os"
import "core:mem"
import "core:strings"
import "nes"
import "platform"

// Save state — raw snapshot of the NES struct
Save_State :: struct {
	data:  []u8,
	valid: bool,
}

save_states: [platform.MAX_SAVE_SLOTS]Save_State

save_state :: proc(console: ^nes.NES, slot: int) {
	size := size_of(nes.NES)
	if !save_states[slot].valid {
		save_states[slot].data = make([]u8, size)
	}
	mem.copy(raw_data(save_states[slot].data), console, size)
	save_states[slot].valid = true
	fmt.printfln("State saved to slot %d", slot + 1)
}

load_state :: proc(console: ^nes.NES, slot: int) -> bool {
	if !save_states[slot].valid {
		fmt.printfln("No save in slot %d", slot + 1)
		return false
	}
	cart_prg := console.cartridge.prg_rom
	cart_chr_rom := console.cartridge.chr_rom

	mem.copy(console, raw_data(save_states[slot].data), size_of(nes.NES))

	console.cartridge.prg_rom = cart_prg
	if console.cartridge.chr_banks == 0 {
		console.cartridge.chr_rom = console.cartridge.chr_ram[:]
	} else {
		console.cartridge.chr_rom = cart_chr_rom
	}

	nes.cartridge_init_mapper(&console.cartridge)
	nes.ppu_init(&console.ppu, &console.cartridge)
	nes.bus_init(&console.bus, &console.cartridge, &console.ppu, &console.cpu, &console.apu)
	nes.apu_init_bus(&console.apu, &console.bus)

	fmt.printfln("State loaded from slot %d", slot + 1)
	return true
}

sav_path: string // Current .sav file path for battery saves

// Derive .sav path from ROM path
make_sav_path :: proc(rom_path: string) -> string {
	// Replace .nes extension with .sav
	if idx := strings.last_index(rom_path, "."); idx >= 0 {
		return strings.concatenate({rom_path[:idx], ".sav"})
	}
	return strings.concatenate({rom_path, ".sav"})
}

load_rom :: proc(console: ^nes.NES, p: ^platform.Platform, path: string) -> bool {
	// Save current battery data before loading new ROM
	if len(sav_path) > 0 {
		nes.cartridge_save_sram(&console.cartridge, sav_path)
		delete(sav_path)
	}

	cart, err := nes.cartridge_load(path)
	if err != .None {
		fmt.eprintfln("Error loading ROM: %v", err)
		return false
	}
	nes.cartridge_print_info(&cart)
	nes.nes_init(console, cart)

	// Load battery save if it exists
	sav_path = make_sav_path(path)
	nes.cartridge_load_sram(&console.cartridge, sav_path)

	// Clear save states when loading a new ROM
	for &s in save_states {
		s.valid = false
	}

	// Update window title
	platform.platform_set_rom_name(p, path)
	return true
}

main :: proc() {
	args := os.args

	if len(args) >= 2 && args[1] == "--nestest" {
		nestest_main()
		return
	}

	console := new(nes.NES)
	defer free(console)

	p: platform.Platform
	rom_loaded := false

	// If ROM passed on command line, load it
	if len(args) >= 2 {
		platform.platform_init(&p, args[1])

		cart, err := nes.cartridge_load(args[1])
		if err != .None {
			fmt.eprintfln("Error loading ROM: %v", err)
			os.exit(1)
		}
		nes.cartridge_print_info(&cart)
		nes.nes_init(console, cart)
		rom_loaded = true
	} else {
		platform.platform_init(&p, "")
	}

	defer platform.platform_shutdown(&p)
	defer for &s in save_states { if s.valid { delete(s.data) } }
	defer {
		// Save battery RAM on exit
		if len(sav_path) > 0 && rom_loaded {
			nes.cartridge_save_sram(&console.cartridge, sav_path)
			delete(sav_path)
		}
	}

	sram_save_timer := 0 // Auto-save SRAM every ~5 seconds

	for !platform.platform_should_close() {
		// Check for drag-and-drop
		if platform.check_file_drop() {
			path := platform.get_dropped_file_and_clear()
			defer delete(path)
			if len(path) > 0 {
				if load_rom(console, &p, path) {
					rom_loaded = true
				}
			}
		}

		if rom_loaded {
			// Read input
			platform.platform_read_input(&p, &console.bus.controller[0])

			// Run emulation (unless paused)
			if !p.paused {
				frames := 1
				if p.fast_forward { frames = 3 }
				for _ in 0..<frames {
					nes.nes_run_frame(console)
				}
			}

			// Audio
			platform.platform_update_audio(&p, &console.apu)

			// Render + menu
			action := platform.platform_render_frame(&p, &console.ppu.framebuffer)

			// Auto-save SRAM every ~5 seconds (300 frames)
			if console.cartridge.has_battery && len(sav_path) > 0 {
				sram_save_timer += 1
				if sram_save_timer >= 300 {
					nes.cartridge_save_sram(&console.cartridge, sav_path)
					sram_save_timer = 0
				}
			}

			switch action {
			case .Reset:
				nes.nes_reset(console)
				fmt.println("Console reset")
			case .Save_State:
				save_state(console, int(p.save_slot))
			case .Load_State:
				load_state(console, int(p.save_slot))
			case .Quit:
				return
			case .None:
			}
		} else {
			// No ROM loaded — show drop prompt
			platform.platform_render_drop_prompt(&p)
		}
	}
}
