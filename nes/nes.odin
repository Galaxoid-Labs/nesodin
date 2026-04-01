package nes

import "mappers"

NES :: struct {
	cpu:          CPU,
	ppu:          PPU,
	apu:          APU,
	bus:          Bus,
	cartridge:    Cartridge,
	controller:   [2]Controller,
	system_clock: u64,
}

nes_init :: proc(console: ^NES, cart: Cartridge) {
	console.cartridge = cart

	// After copying the cartridge, fix up internal pointers.
	// CHR RAM slice pointed into the old cart's chr_ram array — update to point
	// into console.cartridge.chr_ram instead.
	if console.cartridge.chr_banks == 0 {
		console.cartridge.chr_rom = console.cartridge.chr_ram[:]
	}

	// Re-initialize the mapper with corrected slice pointers
	cartridge_init_mapper(&console.cartridge)

	ppu_init(&console.ppu, &console.cartridge)
	cpu_init(&console.cpu)
	bus_init(&console.bus, &console.cartridge, &console.ppu, &console.cpu, &console.apu)
	apu_init(&console.apu, &console.bus)
	cpu_reset(&console.cpu, &console.bus)
}

nes_reset :: proc(console: ^NES) {
	cpu_reset(&console.cpu, &console.bus)
	console.system_clock = 0
}

// Run one CPU instruction and the corresponding PPU/APU cycles
nes_tick :: proc(console: ^NES) {
	// CPU executes first, then PPU/APU catch up (matches fogleman/nes)
	cpu_cycles := cpu_step(&console.cpu, &console.bus)

	for _ in 0..<cpu_cycles {
		ppu_step(&console.ppu)
		ppu_step(&console.ppu)
		ppu_step(&console.ppu)
		apu_step(&console.apu)

		if console.ppu.nmi_pending {
			console.ppu.nmi_pending = false
			cpu_nmi(&console.cpu, &console.bus)
		}
	}

	// Check mapper IRQ (e.g. MMC3 scanline counter)
	if mappers.mapper_irq_pending(&console.cartridge.mapper) {
		mappers.mapper_irq_clear(&console.cartridge.mapper)
		cpu_irq(&console.cpu, &console.bus)
	}

	// APU IRQ — only fire if the game has IRQs enabled (interrupt disable clear)
	// and the APU actually has a pending interrupt
	if (console.apu.frame_irq || console.apu.dmc.irq_pending) &&
	   .Interrupt_Disable not_in console.cpu.status {
		cpu_irq(&console.cpu, &console.bus)
	}

	console.system_clock += u64(cpu_cycles)
}

// Run until a complete frame has been rendered
nes_run_frame :: proc(console: ^NES) {
	console.ppu.frame_ready = false
	for !console.ppu.frame_ready {
		nes_tick(console)
	}
}
