package nes

import "core:math"

// NES APU — 2A03 Audio Processing Unit
// 2 pulse channels, 1 triangle, 1 noise, 1 DMC
// Frame counter drives envelopes, length counters, sweeps

SAMPLE_RATE :: 44100
CPU_FREQ :: 1789773.0
FRAME_COUNTER_RATE :: CPU_FREQ / 240.0

// Length counter lookup table
LENGTH_TABLE :: [32]u8{
	10, 254, 20, 2, 40, 4, 80, 6, 160, 8, 60, 10, 14, 12, 26, 14,
	12, 16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30,
}

// Duty cycle sequences for pulse channels
DUTY_TABLE :: [4][8]u8{
	{0, 0, 0, 0, 0, 0, 0, 1}, // 12.5%
	{0, 0, 0, 0, 0, 0, 1, 1}, // 25%
	{0, 0, 0, 0, 1, 1, 1, 1}, // 50%
	{1, 1, 1, 1, 1, 1, 0, 0}, // 75% (inverted 25%)
}

// Triangle channel waveform (32 steps)
TRIANGLE_TABLE :: [32]u8{
	15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0,
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
}

// Noise channel period lookup (NTSC)
NOISE_TABLE :: [16]u16{
	4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068,
}

// DMC rate table (NTSC)
DMC_TABLE :: [16]u16{
	428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106, 84, 72, 54,
}

// ---- Mixer lookup tables (precalculated, non-linear) ----

pulse_table: [31]f32
tnd_table: [203]f32

@(init)
init_mixer_tables :: proc "contextless" () {
	for i in 0..<31 {
		pulse_table[i] = 95.52 / (8128.0 / f32(i) + 100.0)
	}
	for i in 0..<203 {
		tnd_table[i] = 163.67 / (24329.0 / f32(i) + 100.0)
	}
}

// ---- First-order IIR filter ----

Filter :: struct {
	b0, b1, a1: f32,
	prev_x:     f32,
	prev_y:     f32,
}

filter_step :: proc(f: ^Filter, x: f32) -> f32 {
	y := f.b0 * x + f.b1 * f.prev_x - f.a1 * f.prev_y
	f.prev_x = x
	f.prev_y = y
	return y
}

make_low_pass_filter :: proc(sample_rate: f32, cutoff: f32) -> Filter {
	c := sample_rate / math.PI / cutoff
	a0i := 1.0 / (1.0 + c)
	return Filter{
		b0 = a0i,
		b1 = a0i,
		a1 = (1.0 - c) * a0i,
	}
}

make_high_pass_filter :: proc(sample_rate: f32, cutoff: f32) -> Filter {
	c := sample_rate / math.PI / cutoff
	a0i := 1.0 / (1.0 + c)
	return Filter{
		b0 = c * a0i,
		b1 = -c * a0i,
		a1 = (1.0 - c) * a0i,
	}
}

// ---- Channel structs ----

Envelope :: struct {
	start:         bool,
	loop_flag:     bool,
	constant:      bool,
	volume:        u8,
	decay_level:   u8,
	divider:       u8,
}

Pulse_Channel :: struct {
	enabled:       bool,
	duty:          u8,
	duty_pos:      u8,

	envelope:      Envelope,
	length_counter: u8,
	length_halt:   bool,

	// Sweep
	sweep_enabled: bool,
	sweep_period:  u8,
	sweep_negate:  bool,
	sweep_shift:   u8,
	sweep_reload:  bool,
	sweep_value:   u8,

	// Timer
	timer_period:  u16,
	timer_value:   u16,

	channel_num:   u8,  // 1 or 2 (affects sweep negate behavior)
}

Triangle_Channel :: struct {
	enabled:        bool,
	length_counter: u8,
	length_halt:    bool,

	linear_counter:      u8,
	linear_period:       u8,
	linear_reload_flag:  bool,

	timer_period:   u16,
	timer_value:    u16,
	sequence_pos:   u8,
}

Noise_Channel :: struct {
	enabled:        bool,
	envelope:       Envelope,
	length_counter: u8,
	length_halt:    bool,

	mode:           bool,
	timer_period:   u16,
	timer_value:    u16,
	shift_register: u16,
}

DMC_Channel :: struct {
	enabled:       bool,
	irq_enabled:   bool,
	loop_flag:     bool,

	rate:          u16,
	timer_value:   u16,

	sample_addr:   u16,
	sample_length: u16,
	current_addr:  u16,
	bytes_remaining: u16,

	sample_buffer:   u8,
	buffer_empty:    bool,

	shift_register:  u8,
	bits_remaining:  u8,
	output_level:    u8,
	silence:         bool,

	irq_pending:     bool,
}

APU :: struct {
	pulse1:   Pulse_Channel,
	pulse2:   Pulse_Channel,
	triangle: Triangle_Channel,
	noise:    Noise_Channel,
	dmc:      DMC_Channel,

	frame_period: u8,  // 4 or 5
	frame_value:  u8,  // Current step in sequence
	frame_irq:    bool,
	frame_irq_inhibit: bool,

	cycle:    u64,

	// Audio output
	sample_rate: f64, // CPU cycles per audio sample
	filter_hp1: Filter,
	filter_hp2: Filter,
	filter_lp:  Filter,
	sample_buf: [8192]f32,
	write_pos:  u32,
	read_pos:   u32,

	bus: ^Bus,
}

apu_init :: proc(apu: ^APU, bus: ^Bus) {
	apu.bus = bus
	apu.noise.shift_register = 1
	apu.dmc.buffer_empty = true
	apu.dmc.bits_remaining = 8
	apu.pulse1.channel_num = 1
	apu.pulse2.channel_num = 2
	apu.frame_period = 4
	apu.sample_rate = CPU_FREQ / f64(SAMPLE_RATE)

	// NES hardware filter chain (matches 2A03 analog output)
	apu.filter_hp1 = make_high_pass_filter(SAMPLE_RATE, 37)
	apu.filter_hp2 = make_high_pass_filter(SAMPLE_RATE, 14)
	apu.filter_lp = make_low_pass_filter(SAMPLE_RATE, 14000)
}

// Re-set bus pointer (used after save state load)
apu_init_bus :: proc(apu: ^APU, bus: ^Bus) {
	apu.bus = bus
}

// ---- Register writes ----

apu_write :: proc(apu: ^APU, addr: u16, val: u8) {
	switch addr {
	// Pulse 1: $4000-$4003
	case 0x4000: pulse_write_ctrl(&apu.pulse1, val)
	case 0x4001: pulse_write_sweep(&apu.pulse1, val)
	case 0x4002: pulse_write_timer_lo(&apu.pulse1, val)
	case 0x4003: pulse_write_timer_hi(&apu.pulse1, val)

	// Pulse 2: $4004-$4007
	case 0x4004: pulse_write_ctrl(&apu.pulse2, val)
	case 0x4005: pulse_write_sweep(&apu.pulse2, val)
	case 0x4006: pulse_write_timer_lo(&apu.pulse2, val)
	case 0x4007: pulse_write_timer_hi(&apu.pulse2, val)

	// Triangle: $4008-$400B
	case 0x4008:
		apu.triangle.length_halt = (val & 0x80) != 0
		apu.triangle.linear_period = val & 0x7F
	case 0x400A:
		apu.triangle.timer_period = (apu.triangle.timer_period & 0xFF00) | u16(val)
	case 0x400B:
		apu.triangle.timer_period = (apu.triangle.timer_period & 0x00FF) | (u16(val & 0x07) << 8)
		if apu.triangle.enabled {
			table := LENGTH_TABLE
			apu.triangle.length_counter = table[val >> 3]
		}
		apu.triangle.linear_reload_flag = true

	// Noise: $400C-$400F
	case 0x400C:
		apu.noise.length_halt = (val & 0x20) != 0
		apu.noise.envelope.constant = (val & 0x10) != 0
		apu.noise.envelope.volume = val & 0x0F
		apu.noise.envelope.loop_flag = (val & 0x20) != 0
	case 0x400E:
		apu.noise.mode = (val & 0x80) != 0
		table := NOISE_TABLE
		apu.noise.timer_period = table[val & 0x0F]
	case 0x400F:
		if apu.noise.enabled {
			table := LENGTH_TABLE
			apu.noise.length_counter = table[val >> 3]
		}
		apu.noise.envelope.start = true

	// DMC: $4010-$4013
	case 0x4010:
		apu.dmc.irq_enabled = (val & 0x80) != 0
		apu.dmc.loop_flag = (val & 0x40) != 0
		table := DMC_TABLE
		apu.dmc.rate = table[val & 0x0F]
		if !apu.dmc.irq_enabled {
			apu.dmc.irq_pending = false
		}
	case 0x4011:
		apu.dmc.output_level = val & 0x7F
	case 0x4012:
		apu.dmc.sample_addr = 0xC000 + u16(val) * 64
	case 0x4013:
		apu.dmc.sample_length = u16(val) * 16 + 1

	// Status: $4015
	case 0x4015:
		apu.pulse1.enabled = (val & 0x01) != 0
		if !apu.pulse1.enabled { apu.pulse1.length_counter = 0 }
		apu.pulse2.enabled = (val & 0x02) != 0
		if !apu.pulse2.enabled { apu.pulse2.length_counter = 0 }
		apu.triangle.enabled = (val & 0x04) != 0
		if !apu.triangle.enabled { apu.triangle.length_counter = 0 }
		apu.noise.enabled = (val & 0x08) != 0
		if !apu.noise.enabled { apu.noise.length_counter = 0 }

		apu.dmc.enabled = (val & 0x10) != 0
		if !apu.dmc.enabled {
			apu.dmc.bytes_remaining = 0
		} else if apu.dmc.bytes_remaining == 0 {
			apu.dmc.current_addr = apu.dmc.sample_addr
			apu.dmc.bytes_remaining = apu.dmc.sample_length
		}
		apu.dmc.irq_pending = false

	// Frame counter: $4017
	case 0x4017:
		apu.frame_period = 5 if (val & 0x80) != 0 else 4
		apu.frame_irq_inhibit = (val & 0x40) != 0
		if apu.frame_irq_inhibit {
			apu.frame_irq = false
		}
		if apu.frame_period == 5 {
			apu_step_envelope(apu)
			apu_step_sweep(apu)
			apu_step_length(apu)
		}
	}
}

// Read $4015
apu_read_status :: proc(apu: ^APU) -> u8 {
	status: u8 = 0
	if apu.pulse1.length_counter > 0 { status |= 0x01 }
	if apu.pulse2.length_counter > 0 { status |= 0x02 }
	if apu.triangle.length_counter > 0 { status |= 0x04 }
	if apu.noise.length_counter > 0 { status |= 0x08 }
	if apu.dmc.bytes_remaining > 0 { status |= 0x10 }
	if apu.frame_irq { status |= 0x40 }
	if apu.dmc.irq_pending { status |= 0x80 }
	apu.frame_irq = false
	return status
}

// ---- Pulse channel ----

pulse_write_ctrl :: proc(p: ^Pulse_Channel, val: u8) {
	p.duty = (val >> 6) & 0x03
	p.length_halt = (val & 0x20) != 0
	p.envelope.constant = (val & 0x10) != 0
	p.envelope.volume = val & 0x0F
	p.envelope.loop_flag = (val & 0x20) != 0
}

pulse_write_sweep :: proc(p: ^Pulse_Channel, val: u8) {
	p.sweep_enabled = (val & 0x80) != 0
	p.sweep_period = (val >> 4) & 0x07
	p.sweep_negate = (val & 0x08) != 0
	p.sweep_shift = val & 0x07
	p.sweep_reload = true
}

pulse_write_timer_lo :: proc(p: ^Pulse_Channel, val: u8) {
	p.timer_period = (p.timer_period & 0xFF00) | u16(val)
}

pulse_write_timer_hi :: proc(p: ^Pulse_Channel, val: u8) {
	p.timer_period = (p.timer_period & 0x00FF) | (u16(val & 0x07) << 8)
	if p.enabled {
		table := LENGTH_TABLE
		p.length_counter = table[val >> 3]
	}
	// NOTE: Hardware resets duty_pos to 0 here, but this causes audible clicks
	// in emulation. Skipping this is a common emulator compromise.
	p.envelope.start = true
}

pulse_output :: proc(p: ^Pulse_Channel) -> u8 {
	if !p.enabled { return 0 }
	if p.length_counter == 0 { return 0 }
	duty := DUTY_TABLE
	if duty[p.duty][p.duty_pos] == 0 { return 0 }
	if p.timer_period < 8 || p.timer_period > 0x7FF { return 0 }
	return envelope_output(&p.envelope)
}

pulse_tick :: proc(p: ^Pulse_Channel) {
	if p.timer_value == 0 {
		p.timer_value = p.timer_period
		p.duty_pos = (p.duty_pos + 1) & 0x07
	} else {
		p.timer_value -= 1
	}
}

pulse_sweep :: proc(p: ^Pulse_Channel) {
	delta := p.timer_period >> p.sweep_shift
	if p.sweep_negate {
		p.timer_period -= delta
		if p.channel_num == 1 {
			p.timer_period -= 1
		}
	} else {
		p.timer_period += delta
	}
}

pulse_sweep_tick :: proc(p: ^Pulse_Channel) {
	if p.sweep_reload {
		if p.sweep_enabled && p.sweep_value == 0 {
			pulse_sweep(p)
		}
		p.sweep_value = p.sweep_period
		p.sweep_reload = false
	} else if p.sweep_value > 0 {
		p.sweep_value -= 1
	} else {
		if p.sweep_enabled {
			pulse_sweep(p)
		}
		p.sweep_value = p.sweep_period
	}
}

// ---- Envelope ----

envelope_output :: proc(e: ^Envelope) -> u8 {
	return e.volume if e.constant else e.decay_level
}

envelope_tick :: proc(e: ^Envelope) {
	if e.start {
		e.start = false
		e.decay_level = 15
		e.divider = e.volume
		return
	}

	if e.divider == 0 {
		e.divider = e.volume
		if e.decay_level > 0 {
			e.decay_level -= 1
		} else if e.loop_flag {
			e.decay_level = 15
		}
	} else {
		e.divider -= 1
	}
}

// ---- Triangle channel ----

triangle_tick :: proc(tri: ^Triangle_Channel) {
	if tri.timer_value == 0 {
		tri.timer_value = tri.timer_period
		if tri.length_counter > 0 && tri.linear_counter > 0 {
			tri.sequence_pos = (tri.sequence_pos + 1) & 0x1F
		}
	} else {
		tri.timer_value -= 1
	}
}

triangle_output :: proc(tri: ^Triangle_Channel) -> u8 {
	if !tri.enabled { return 0 }
	if tri.length_counter == 0 { return 0 }
	if tri.linear_counter == 0 { return 0 }
	if tri.timer_period < 3 { return 0 }
	table := TRIANGLE_TABLE
	return table[tri.sequence_pos]
}

// ---- Noise channel ----

noise_tick :: proc(n: ^Noise_Channel) {
	if n.timer_value == 0 {
		n.timer_value = n.timer_period
		bit: u16 = 6 if n.mode else 1
		feedback := (n.shift_register & 0x01) ~ ((n.shift_register >> bit) & 0x01)
		n.shift_register >>= 1
		n.shift_register |= feedback << 14
	} else {
		n.timer_value -= 1
	}
}

noise_output :: proc(n: ^Noise_Channel) -> u8 {
	if !n.enabled { return 0 }
	if n.length_counter == 0 { return 0 }
	if (n.shift_register & 0x01) != 0 { return 0 }
	return envelope_output(&n.envelope)
}

// ---- DMC channel ----

dmc_tick :: proc(d: ^DMC_Channel, bus: ^Bus) {
	// Try to fill sample buffer
	if d.buffer_empty && d.bytes_remaining > 0 && bus != nil {
		d.sample_buffer = bus_read(bus, d.current_addr)
		d.buffer_empty = false
		d.current_addr += 1
		if d.current_addr == 0 {
			d.current_addr = 0x8000
		}
		d.bytes_remaining -= 1
		if d.bytes_remaining == 0 {
			if d.loop_flag {
				d.current_addr = d.sample_addr
				d.bytes_remaining = d.sample_length
			} else if d.irq_enabled {
				d.irq_pending = true
			}
		}
	}

	if d.timer_value == 0 {
		d.timer_value = d.rate

		if !d.silence {
			if (d.shift_register & 0x01) != 0 {
				if d.output_level <= 125 {
					d.output_level += 2
				}
			} else {
				if d.output_level >= 2 {
					d.output_level -= 2
				}
			}
			d.shift_register >>= 1
		}

		d.bits_remaining -= 1
		if d.bits_remaining == 0 {
			d.bits_remaining = 8
			if d.buffer_empty {
				d.silence = true
			} else {
				d.silence = false
				d.shift_register = d.sample_buffer
				d.buffer_empty = true
			}
		}
	} else {
		d.timer_value -= 1
	}
}

// ---- Frame counter ----

apu_step_envelope :: proc(apu: ^APU) {
	envelope_tick(&apu.pulse1.envelope)
	envelope_tick(&apu.pulse2.envelope)
	envelope_tick(&apu.noise.envelope)

	// Triangle linear counter
	if apu.triangle.linear_reload_flag {
		apu.triangle.linear_counter = apu.triangle.linear_period
	} else if apu.triangle.linear_counter > 0 {
		apu.triangle.linear_counter -= 1
	}
	if !apu.triangle.length_halt {
		apu.triangle.linear_reload_flag = false
	}
}

apu_step_sweep :: proc(apu: ^APU) {
	pulse_sweep_tick(&apu.pulse1)
	pulse_sweep_tick(&apu.pulse2)
}

apu_step_length :: proc(apu: ^APU) {
	if apu.pulse1.length_counter > 0 && !apu.pulse1.length_halt {
		apu.pulse1.length_counter -= 1
	}
	if apu.pulse2.length_counter > 0 && !apu.pulse2.length_halt {
		apu.pulse2.length_counter -= 1
	}
	if apu.triangle.length_counter > 0 && !apu.triangle.length_halt {
		apu.triangle.length_counter -= 1
	}
	if apu.noise.length_counter > 0 && !apu.noise.length_halt {
		apu.noise.length_counter -= 1
	}
}

apu_step_frame_counter :: proc(apu: ^APU) {
	if apu.frame_period == 4 {
		apu.frame_value = (apu.frame_value + 1) % 4
		switch apu.frame_value {
		case 0, 2:
			apu_step_envelope(apu)
		case 1:
			apu_step_envelope(apu)
			apu_step_sweep(apu)
			apu_step_length(apu)
		case 3:
			apu_step_envelope(apu)
			apu_step_sweep(apu)
			apu_step_length(apu)
			if !apu.frame_irq_inhibit {
				apu.frame_irq = true
			}
		}
	} else {
		apu.frame_value = (apu.frame_value + 1) % 5
		switch apu.frame_value {
		case 0, 2:
			apu_step_envelope(apu)
		case 1, 3:
			apu_step_envelope(apu)
			apu_step_sweep(apu)
			apu_step_length(apu)
		}
	}
}

// ---- Mixer ----

apu_mix :: proc(apu: ^APU) -> f32 {
	p1 := pulse_output(&apu.pulse1)
	p2 := pulse_output(&apu.pulse2)
	t  := triangle_output(&apu.triangle)
	n  := noise_output(&apu.noise)
	d  := apu.dmc.output_level

	pulse_out := pulse_table[p1 + p2]
	tnd_out := tnd_table[3 * u16(t) + 2 * u16(n) + u16(d)]
	return pulse_out + tnd_out
}

// ---- Main APU tick (called once per CPU cycle) ----

apu_step :: proc(apu: ^APU) {
	cycle1 := apu.cycle
	apu.cycle += 1
	cycle2 := apu.cycle

	// Timer ticks: pulse and noise at half CPU rate, triangle every cycle
	if (cycle2 & 1) == 0 {
		pulse_tick(&apu.pulse1)
		pulse_tick(&apu.pulse2)
		noise_tick(&apu.noise)
		dmc_tick(&apu.dmc, apu.bus)
	}
	triangle_tick(&apu.triangle)

	// Frame counter — fires at ~240 Hz
	f1 := u64(f64(cycle1) / FRAME_COUNTER_RATE)
	f2 := u64(f64(cycle2) / FRAME_COUNTER_RATE)
	if f1 != f2 {
		apu_step_frame_counter(apu)
	}

	// Generate audio sample at target rate
	s1 := u64(f64(cycle1) / apu.sample_rate)
	s2 := u64(f64(cycle2) / apu.sample_rate)
	if s1 != s2 {
		sample := apu_mix(apu)
		sample = filter_step(&apu.filter_hp1, sample)
		sample = filter_step(&apu.filter_hp2, sample)
		sample = filter_step(&apu.filter_lp, sample)

		if apu.write_pos - apu.read_pos < 8192 {
			apu.sample_buf[apu.write_pos & 8191] = sample
			apu.write_pos += 1
		}
	}
}

// Get available samples
apu_samples_available :: proc(apu: ^APU) -> u32 {
	return apu.write_pos - apu.read_pos
}

// Read samples into output buffer
apu_read_samples :: proc(apu: ^APU, out: []f32) -> u32 {
	available := apu_samples_available(apu)
	count := min(available, u32(len(out)))
	for i in u32(0)..<count {
		out[i] = apu.sample_buf[(apu.read_pos + i) & 8191]
	}
	apu.read_pos += count
	return count
}
