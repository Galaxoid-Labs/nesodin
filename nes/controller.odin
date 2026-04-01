package nes

// NES controller — 8 buttons read via shift register

Controller_Button :: enum u8 {
	A,
	B,
	Select,
	Start,
	Up,
	Down,
	Left,
	Right,
}

Controller :: struct {
	buttons: bit_set[Controller_Button; u8], // Current button state
	shift:   u8,                              // Shift register value
	index:   u8,                              // Current bit position (0-7)
	strobe:  bool,                            // Strobe mode (continuously reload)
}

controller_write :: proc(c: ^Controller, val: u8) {
	c.strobe = (val & 1) != 0
	if c.strobe {
		c.shift = transmute(u8)c.buttons
		c.index = 0
	}
}

controller_read :: proc(c: ^Controller) -> u8 {
	if c.index > 7 {
		return 1 // After 8 reads, returns 1
	}

	val := (c.shift >> c.index) & 1
	c.index += 1

	if c.strobe {
		c.shift = transmute(u8)c.buttons
		c.index = 0
	}

	return val
}
