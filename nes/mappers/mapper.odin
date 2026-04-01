package mappers

Mirror_Mode :: enum u8 {
	Horizontal,
	Vertical,
	Single_Screen_Low,
	Single_Screen_High,
	Four_Screen,
}

Mapper :: union {
	Mapper_000,
	Mapper_001,
	Mapper_002,
	Mapper_003,
	Mapper_004,
	Mapper_007,
	Mapper_009,
	Mapper_010,
	Mapper_011,
	Mapper_066,
	Mapper_071,
}

mapper_cpu_read :: proc(mapper: ^Mapper, addr: u16) -> (data: u8, ok: bool) {
	switch &m in mapper {
	case Mapper_000: return mapper_000_cpu_read(&m, addr)
	case Mapper_001: return mapper_001_cpu_read(&m, addr)
	case Mapper_002: return mapper_002_cpu_read(&m, addr)
	case Mapper_003: return mapper_003_cpu_read(&m, addr)
	case Mapper_004: return mapper_004_cpu_read(&m, addr)
	case Mapper_007: return mapper_007_cpu_read(&m, addr)
	case Mapper_009: return mapper_009_cpu_read(&m, addr)
	case Mapper_010: return mapper_010_cpu_read(&m, addr)
	case Mapper_011: return mapper_011_cpu_read(&m, addr)
	case Mapper_066: return mapper_066_cpu_read(&m, addr)
	case Mapper_071: return mapper_071_cpu_read(&m, addr)
	}
	return 0, false
}

mapper_cpu_write :: proc(mapper: ^Mapper, addr: u16, val: u8) -> bool {
	switch &m in mapper {
	case Mapper_000: return mapper_000_cpu_write(&m, addr, val)
	case Mapper_001: return mapper_001_cpu_write(&m, addr, val)
	case Mapper_002: return mapper_002_cpu_write(&m, addr, val)
	case Mapper_003: return mapper_003_cpu_write(&m, addr, val)
	case Mapper_004: return mapper_004_cpu_write(&m, addr, val)
	case Mapper_007: return mapper_007_cpu_write(&m, addr, val)
	case Mapper_009: return mapper_009_cpu_write(&m, addr, val)
	case Mapper_010: return mapper_010_cpu_write(&m, addr, val)
	case Mapper_011: return mapper_011_cpu_write(&m, addr, val)
	case Mapper_066: return mapper_066_cpu_write(&m, addr, val)
	case Mapper_071: return mapper_071_cpu_write(&m, addr, val)
	}
	return false
}

mapper_ppu_read :: proc(mapper: ^Mapper, addr: u16) -> (data: u8, ok: bool) {
	switch &m in mapper {
	case Mapper_000: return mapper_000_ppu_read(&m, addr)
	case Mapper_001: return mapper_001_ppu_read(&m, addr)
	case Mapper_002: return mapper_002_ppu_read(&m, addr)
	case Mapper_003: return mapper_003_ppu_read(&m, addr)
	case Mapper_004: return mapper_004_ppu_read(&m, addr)
	case Mapper_007: return mapper_007_ppu_read(&m, addr)
	case Mapper_009: return mapper_009_ppu_read(&m, addr)
	case Mapper_010: return mapper_010_ppu_read(&m, addr)
	case Mapper_011: return mapper_011_ppu_read(&m, addr)
	case Mapper_066: return mapper_066_ppu_read(&m, addr)
	case Mapper_071: return mapper_071_ppu_read(&m, addr)
	}
	return 0, false
}

mapper_ppu_write :: proc(mapper: ^Mapper, addr: u16, val: u8) -> bool {
	switch &m in mapper {
	case Mapper_000: return mapper_000_ppu_write(&m, addr, val)
	case Mapper_001: return mapper_001_ppu_write(&m, addr, val)
	case Mapper_002: return mapper_002_ppu_write(&m, addr, val)
	case Mapper_003: return mapper_003_ppu_write(&m, addr, val)
	case Mapper_004: return mapper_004_ppu_write(&m, addr, val)
	case Mapper_007: return mapper_007_ppu_write(&m, addr, val)
	case Mapper_009: return mapper_009_ppu_write(&m, addr, val)
	case Mapper_010: return mapper_010_ppu_write(&m, addr, val)
	case Mapper_011: return mapper_011_ppu_write(&m, addr, val)
	case Mapper_066: return mapper_066_ppu_write(&m, addr, val)
	case Mapper_071: return mapper_071_ppu_write(&m, addr, val)
	}
	return false
}

mapper_mirror_mode :: proc(mapper: ^Mapper) -> (mode: Mirror_Mode, is_dynamic: bool) {
	switch &m in mapper {
	case Mapper_001: return mapper_001_mirror(&m), true
	case Mapper_004: return mapper_004_mirror(&m), true
	case Mapper_007: return mapper_007_mirror(&m), true
	case Mapper_009: return mapper_009_mirror(&m), true
	case Mapper_010: return mapper_010_mirror(&m), true
	case Mapper_071:
		if m.has_mirror_ctrl { return mapper_071_mirror(&m), true }
		return .Horizontal, false
	case Mapper_000, Mapper_002, Mapper_003, Mapper_011, Mapper_066:
		return .Horizontal, false
	}
	return .Horizontal, false
}

mapper_scanline :: proc(mapper: ^Mapper) {
	switch &m in mapper {
	case Mapper_004: mapper_004_scanline(&m)
	case Mapper_000, Mapper_001, Mapper_002, Mapper_003, Mapper_007,
	     Mapper_009, Mapper_010, Mapper_011, Mapper_066, Mapper_071:
	}
}

mapper_irq_pending :: proc(mapper: ^Mapper) -> bool {
	switch &m in mapper {
	case Mapper_004: return m.irq_pending
	case Mapper_000, Mapper_001, Mapper_002, Mapper_003, Mapper_007,
	     Mapper_009, Mapper_010, Mapper_011, Mapper_066, Mapper_071:
		return false
	}
	return false
}

mapper_irq_clear :: proc(mapper: ^Mapper) {
	switch &m in mapper {
	case Mapper_004: m.irq_pending = false
	case Mapper_000, Mapper_001, Mapper_002, Mapper_003, Mapper_007,
	     Mapper_009, Mapper_010, Mapper_011, Mapper_066, Mapper_071:
	}
}
