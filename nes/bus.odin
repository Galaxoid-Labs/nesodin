package nes

import "mappers"

Bus :: struct {
	ram:        [2048]u8,
	cartridge:  ^Cartridge,
	ppu:        ^PPU,
	cpu:        ^CPU,
	apu:        ^APU,
	controller: [2]Controller,
}

bus_init :: proc(bus: ^Bus, cart: ^Cartridge, ppu: ^PPU, cpu: ^CPU = nil, apu: ^APU = nil) {
	bus.cartridge = cart
	bus.ppu = ppu
	bus.cpu = cpu
	bus.apu = apu
}

bus_read :: proc(bus: ^Bus, addr: u16) -> u8 {
	switch {
	case addr <= 0x1FFF:
		return bus.ram[addr & 0x07FF]

	case addr <= 0x3FFF:
		return ppu_cpu_read(bus.ppu, 0x2000 + (addr & 0x0007))

	case addr == 0x4015:
		if bus.apu != nil {
			return apu_read_status(bus.apu)
		}
		return 0

	case addr == 0x4016:
		return controller_read(&bus.controller[0])

	case addr == 0x4017:
		return controller_read(&bus.controller[1])

	case addr >= 0x4000 && addr <= 0x4014:
		return 0 // Write-only APU/IO registers

	case addr >= 0x4020:
		data, ok := mappers.mapper_cpu_read(&bus.cartridge.mapper, addr)
		if ok {
			return data
		}
		return 0
	}
	return 0
}

bus_write :: proc(bus: ^Bus, addr: u16, val: u8) {
	switch {
	case addr <= 0x1FFF:
		bus.ram[addr & 0x07FF] = val

	case addr <= 0x3FFF:
		ppu_cpu_write(bus.ppu, 0x2000 + (addr & 0x0007), val)

	case addr == 0x4014:
		ppu_oam_dma(bus.ppu, bus, val)
		if bus.cpu != nil {
			bus.cpu.stall += 513
		}

	case addr == 0x4016:
		controller_write(&bus.controller[0], val)
		controller_write(&bus.controller[1], val)

	case addr >= 0x4000 && addr <= 0x4013,
	     addr == 0x4015,
	     addr == 0x4017:
		if bus.apu != nil {
			apu_write(bus.apu, addr, val)
		}

	case addr >= 0x4020:
		mappers.mapper_cpu_write(&bus.cartridge.mapper, addr, val)
	}
}
