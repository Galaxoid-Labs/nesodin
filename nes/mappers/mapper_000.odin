package mappers

// NROM (Mapper 000) — the simplest NES mapper
// PRG ROM: 16KB or 32KB (mirrored if 16KB)
// CHR ROM: 8KB (or 8KB CHR RAM if cart has no CHR ROM)
// PRG RAM: 8KB at $6000-$7FFF (optional)

Mapper_000 :: struct {
	prg_rom:   []u8,       // 16KB or 32KB
	chr:       []u8,       // 8KB CHR ROM or RAM
	prg_ram:   [8192]u8,   // $6000-$7FFF
	prg_banks: u8,         // 1 = 16KB (mirrored), 2 = 32KB
	has_chr_ram: bool,
}

mapper_000_init :: proc(prg_rom: []u8, chr: []u8, prg_banks: u8, has_chr_ram: bool) -> Mapper_000 {
	return Mapper_000{
		prg_rom   = prg_rom,
		chr       = chr,
		prg_banks = prg_banks,
		has_chr_ram = has_chr_ram,
	}
}

mapper_000_cpu_read :: proc(m: ^Mapper_000, addr: u16) -> (data: u8, ok: bool) {
	switch {
	case addr >= 0x6000 && addr <= 0x7FFF:
		// PRG RAM
		return m.prg_ram[addr - 0x6000], true
	case addr >= 0x8000:
		// PRG ROM — mirror if only 1 bank (16KB)
		mapped := addr - 0x8000
		if m.prg_banks == 1 {
			mapped &= 0x3FFF // Mirror 16KB
		}
		return m.prg_rom[mapped], true
	}
	return 0, false
}

mapper_000_cpu_write :: proc(m: ^Mapper_000, addr: u16, val: u8) -> bool {
	switch {
	case addr >= 0x6000 && addr <= 0x7FFF:
		m.prg_ram[addr - 0x6000] = val
		return true
	case addr >= 0x8000:
		// PRG ROM is read-only on NROM
		return false
	}
	return false
}

mapper_000_ppu_read :: proc(m: ^Mapper_000, addr: u16) -> (data: u8, ok: bool) {
	if addr <= 0x1FFF {
		return m.chr[addr], true
	}
	return 0, false
}

mapper_000_ppu_write :: proc(m: ^Mapper_000, addr: u16, val: u8) -> bool {
	if addr <= 0x1FFF && m.has_chr_ram {
		m.chr[addr] = val
		return true
	}
	return false
}
