package platform

import rl "vendor:raylib"
import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import "../nes"

SCALE :: 3
SCREEN_W :: 256 * SCALE
SCREEN_H :: 240 * SCALE

AUDIO_SAMPLE_RATE :: 44100
AUDIO_BUFFER_SIZE :: 512

MAX_SAVE_SLOTS :: 4

Menu_Action :: enum {
	None,
	Reset,
	Save_State,
	Load_State,
	Quit,
}

// Global APU pointer for audio callback (callback runs on audio thread)
g_apu: ^nes.APU

// Audio callback — pulls samples directly from APU ring buffer (no gaps)
// Runs on the audio thread, must be "c" calling convention
audio_callback :: proc "c" (buffer: rawptr, frames: c.uint) {
	if g_apu == nil { return }
	samples := ([^]f32)(buffer)

	// Direct ring buffer access — no Odin context needed
	n := u32(frames)
	available := g_apu.write_pos - g_apu.read_pos
	count := min(available, n)

	for i in u32(0)..<count {
		samples[i] = g_apu.sample_buf[(g_apu.read_pos + i) & 16383]
	}
	g_apu.read_pos += count

	// Fill remainder with last sample to avoid pops
	if count > 0 && count < n {
		last := samples[count - 1]
		for i in count..<n {
			samples[i] = last
		}
	} else if count == 0 {
		for i in u32(0)..<n {
			samples[i] = 0
		}
	}
}

Platform :: struct {
	texture:      rl.Texture2D,
	audio_stream: rl.AudioStream,

	// CRT shader
	crt_shader:   rl.Shader,
	crt_enabled:  bool,
	crt_res_loc:  i32,

	// Menu
	menu_open:    bool,
	paused:       bool,
	volume:       f32,
	save_slot:    c.int,
	fast_forward: bool,
	rom_name:     string,

}

platform_init :: proc(p: ^Platform, rom_path: string) {
	// Extract ROM name for window title
	name := rom_path
	if idx := strings.last_index(name, "/"); idx >= 0 { name = name[idx+1:] }
	if idx := strings.last_index(name, "\\"); idx >= 0 { name = name[idx+1:] }
	if idx := strings.last_index(name, "."); idx >= 0 { name = name[:idx] }
	p.rom_name = name

	title := fmt.ctprintf("NesOdin - %s", name)
	rl.InitWindow(SCREEN_W, SCREEN_H, title)
	rl.SetTargetFPS(60)
	rl.SetExitKey(.KEY_NULL) // Disable Escape closing the window — we use it for the menu

	img := rl.Image{
		data    = nil,
		width   = 256,
		height  = 240,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	p.texture = rl.LoadTextureFromImage(img)

	// Load CRT shader
	p.crt_shader = rl.LoadShader(nil, "platform/crt.glsl")
	p.crt_res_loc = rl.GetShaderLocation(p.crt_shader, "resolution")
	res := [2]f32{f32(SCREEN_W), f32(SCREEN_H)}
	rl.SetShaderValue(p.crt_shader, p.crt_res_loc, &res, .VEC2)
	p.crt_enabled = false

	// Init audio with callback-based streaming (gapless)
	rl.InitAudioDevice()
	rl.SetAudioStreamBufferSizeDefault(AUDIO_BUFFER_SIZE)
	p.audio_stream = rl.LoadAudioStream(AUDIO_SAMPLE_RATE, 32, 1)
	p.volume = 0.5
	rl.SetAudioStreamVolume(p.audio_stream, p.volume)
	rl.SetAudioStreamCallback(p.audio_stream, audio_callback)
	rl.PlayAudioStream(p.audio_stream)

	// Menu defaults
	p.save_slot = 0

	// GUI style — use 20px (2x the default 10px bitmap font) for crisp scaling
	rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiDefaultProperty.TEXT_SIZE), 20)
}

platform_shutdown :: proc(p: ^Platform) {
	rl.UnloadShader(p.crt_shader)
	rl.UnloadAudioStream(p.audio_stream)
	rl.CloseAudioDevice()
	rl.UnloadTexture(p.texture)
	rl.CloseWindow()
}

platform_should_close :: proc() -> bool {
	return rl.WindowShouldClose()
}

platform_render_frame :: proc(p: ^Platform, framebuffer: ^[256 * 240]u32) -> Menu_Action {
	action := Menu_Action.None

	// Toggle menu with Escape
	if rl.IsKeyPressed(.ESCAPE) {
		p.menu_open = !p.menu_open
		p.paused = p.menu_open
	}

	// Toggle CRT shader with F1
	if rl.IsKeyPressed(.F1) {
		p.crt_enabled = !p.crt_enabled
	}

	// Fast forward with Tab (hold)
	p.fast_forward = rl.IsKeyDown(.TAB)

	// Quick save/load with F5/F9
	if rl.IsKeyPressed(.F5) { action = .Save_State }
	if rl.IsKeyPressed(.F9) { action = .Load_State }

	// Quick reset with F12
	if rl.IsKeyPressed(.F12) { action = .Reset }

	// Update texture from framebuffer
	@(static) pixels: [256 * 240 * 4]u8
	for i in 0..<(256 * 240) {
		rgba := framebuffer[i]
		pixels[i * 4 + 0] = u8(rgba >> 24)
		pixels[i * 4 + 1] = u8((rgba >> 16) & 0xFF)
		pixels[i * 4 + 2] = u8((rgba >> 8) & 0xFF)
		pixels[i * 4 + 3] = u8(rgba & 0xFF)
	}
	rl.UpdateTexture(p.texture, raw_data(&pixels))

	rl.BeginDrawing()
	rl.ClearBackground(rl.BLACK)

	// Calculate scaling (handles both windowed and fullscreen)
	screen_w := f32(rl.GetScreenWidth())
	screen_h := f32(rl.GetScreenHeight())
	scale := min(screen_w / 256.0, screen_h / 240.0)
	draw_w := 256.0 * scale
	draw_h := 240.0 * scale
	draw_x := (screen_w - draw_w) / 2.0
	draw_y := (screen_h - draw_h) / 2.0

	// Draw game screen
	if p.crt_enabled {
		// Update shader resolution uniform for current screen size
		res := [2]f32{screen_w, screen_h}
		rl.SetShaderValue(p.crt_shader, p.crt_res_loc, &res, .VEC2)
		rl.BeginShaderMode(p.crt_shader)
	}
	rl.DrawTextureEx(p.texture, {draw_x, draw_y}, 0, scale, rl.WHITE)
	if p.crt_enabled {
		rl.EndShaderMode()
	}

	// Draw menu overlay
	if p.menu_open {
		action = draw_menu(p)
	}

	// Draw status indicators
	if !p.menu_open {
		if p.fast_forward {
			rl.DrawText(">> FAST", SCREEN_W - 90, 5, 16, rl.YELLOW)
		}
		if p.paused {
			rl.DrawText("PAUSED", SCREEN_W / 2 - 40, 5, 16, rl.YELLOW)
		}
	}

	rl.EndDrawing()

	return action
}

draw_menu :: proc(p: ^Platform) -> Menu_Action {
	action := Menu_Action.None

	// Dim the game screen
	rl.DrawRectangle(0, 0, SCREEN_W, SCREEN_H, {0, 0, 0, 160})

	// Menu panel
	panel_w: f32 = 380
	panel_h: f32 = 580
	panel_x: f32 = (SCREEN_W - panel_w) / 2
	panel_y: f32 = (SCREEN_H - panel_h) / 2

	close := rl.GuiWindowBox({panel_x, panel_y, panel_w, panel_h}, "NesOdin Menu")
	if close != 0 {
		p.menu_open = false
		p.paused = false
	}

	x: f32 = panel_x + 20
	y: f32 = panel_y + 40
	w: f32 = panel_w - 40
	h: f32 = 30

	// ---- Game info ----
	rl.GuiLabel({x, y, w, h}, fmt.ctprintf("Game: %s", p.rom_name))
	y += 30

	rl.GuiLine({x, y, w, 1}, "Actions")
	y += 20

	// ---- Save/Load State ----
	rl.GuiLabel({x, y, 40, h}, "Slot:")
	rl.GuiToggleGroup({x + 45, y, (w - 45) / 4, h}, "1;2;3;4", &p.save_slot)
	y += 40

	if rl.GuiButton({x, y, (w - 10) / 2, h}, "Save State (F5)") {
		action = .Save_State
	}
	if rl.GuiButton({x + (w + 10) / 2, y, (w - 10) / 2, h}, "Load State (F9)") {
		action = .Load_State
	}
	y += 40

	// ---- Controls ----
	rl.GuiLine({x, y, w, 1}, "Settings")
	y += 20

	// CRT toggle
	rl.GuiCheckBox({x, y, 20, 20}, "CRT Shader (F1)", &p.crt_enabled)
	y += 30

	// Volume
	rl.GuiLabel({x, y, 60, h}, "Volume:")
	old_vol := p.volume
	rl.GuiSliderBar({x + 65, y, w - 65, h}, nil, nil, &p.volume, 0, 1)
	if p.volume != old_vol {
		rl.SetAudioStreamVolume(p.audio_stream, p.volume)
	}
	y += 40

	rl.GuiLine({x, y, w, 1}, nil)
	y += 20

	// ---- Actions ----
	if rl.GuiButton({x, y, w, h}, "Reset (F12)") {
		action = .Reset
		p.menu_open = false
		p.paused = false
	}
	y += 40

	if rl.GuiButton({x, y, w, h}, "Resume (Esc)") {
		p.menu_open = false
		p.paused = false
	}
	y += 40

	if rl.GuiButton({x, y, w, h}, "Quit") {
		action = .Quit
	}
	y += 40

	// ---- Controls reference ----
	rl.GuiLine({x, y, w, 1}, "Controls")
	y += 20

	controls := [?]struct{key, action: cstring}{
		{"Arrows",      "D-Pad"},
		{"Z / X",       "B / A"},
		{"Enter",       "Start"},
		{"Right Shift", "Select"},
		{"Escape",      "Menu"},
		{"F1",          "CRT Shader"},
		{"F5 / F9",     "Save / Load State"},
		{"F12",         "Reset"},
		{"Tab (hold)",  "Fast Forward"},
	}

	for ctrl in controls {
		rl.DrawText(ctrl.key, i32(x), i32(y), 10, {180, 180, 200, 255})
		rl.DrawText(ctrl.action, i32(x + 110), i32(y), 10, {140, 140, 160, 255})
		y += 14
	}

	// Close menu on action
	if action == .Save_State || action == .Load_State {
		p.menu_open = false
		p.paused = false
	}

	return action
}

// Set the APU pointer for the audio callback
platform_update_audio :: proc(p: ^Platform, apu: ^nes.APU) {
	g_apu = apu
}

// Update window title with ROM name
platform_set_rom_name :: proc(p: ^Platform, rom_path: string) {
	name := rom_path
	if idx := strings.last_index(name, "/"); idx >= 0 { name = name[idx+1:] }
	if idx := strings.last_index(name, "\\"); idx >= 0 { name = name[idx+1:] }
	if idx := strings.last_index(name, "."); idx >= 0 { name = name[:idx] }
	p.rom_name = name
	rl.SetWindowTitle(fmt.ctprintf("NesOdin - %s", name))
}

// Drag and drop support
check_file_drop :: proc() -> bool {
	return rl.IsFileDropped()
}

get_dropped_file_and_clear :: proc() -> string {
	files := rl.LoadDroppedFiles()
	defer rl.UnloadDroppedFiles(files)
	if files.count > 0 {
		return strings.clone_from_cstring(files.paths[0])
	}
	return ""
}

// Render the "no ROM" drop prompt screen
platform_render_drop_prompt :: proc(p: ^Platform) {
	rl.BeginDrawing()
	rl.ClearBackground({24, 24, 32, 255})

	// Title
	title_size: i32 = 40
	title_w := rl.MeasureText("NesOdin", title_size)
	rl.DrawText("NesOdin", (SCREEN_W - title_w) / 2, SCREEN_H / 2 - 80, title_size, {200, 200, 220, 255})

	// Subtitle
	sub_size: i32 = 20
	sub_w := rl.MeasureText("NES Emulator", sub_size)
	rl.DrawText("NES Emulator", (SCREEN_W - sub_w) / 2, SCREEN_H / 2 - 35, sub_size, {140, 140, 160, 255})

	// Drop prompt — pulse alpha for attention
	t := rl.GetTime()
	alpha := u8(140 + 80 * math.abs(math.sin(t * 2.0)) * 115)
	msg_size: i32 = 18
	msg_w := rl.MeasureText("Drop a .nes ROM here to play", msg_size)
	rl.DrawText("Drop a .nes ROM here to play", (SCREEN_W - msg_w) / 2, SCREEN_H / 2 + 20, msg_size, {180, 180, 200, alpha})

	// Controls hint
	hint_size: i32 = 14
	hint_w := rl.MeasureText("or run: nesodin <rom.nes>", hint_size)
	rl.DrawText("or run: nesodin <rom.nes>", (SCREEN_W - hint_w) / 2, SCREEN_H / 2 + 50, hint_size, {100, 100, 120, 255})

	rl.EndDrawing()
}

// Map keyboard and gamepad to NES controller buttons
platform_read_input :: proc(p: ^Platform, controller: ^nes.Controller) {
	if p.menu_open {
		controller.buttons = {}
		return
	}

	controller.buttons = {}

	// Keyboard
	if rl.IsKeyDown(.RIGHT)       { controller.buttons += {.Right} }
	if rl.IsKeyDown(.LEFT)        { controller.buttons += {.Left} }
	if rl.IsKeyDown(.UP)          { controller.buttons += {.Up} }
	if rl.IsKeyDown(.DOWN)        { controller.buttons += {.Down} }
	if rl.IsKeyDown(.Z)           { controller.buttons += {.B} }
	if rl.IsKeyDown(.X)           { controller.buttons += {.A} }
	if rl.IsKeyDown(.ENTER)       { controller.buttons += {.Start} }
	if rl.IsKeyDown(.RIGHT_SHIFT) { controller.buttons += {.Select} }

	// Gamepad (player 1 = gamepad 0)
	if rl.IsGamepadAvailable(0) {
		// D-pad
		if rl.IsGamepadButtonDown(0, .LEFT_FACE_RIGHT) { controller.buttons += {.Right} }
		if rl.IsGamepadButtonDown(0, .LEFT_FACE_LEFT)  { controller.buttons += {.Left} }
		if rl.IsGamepadButtonDown(0, .LEFT_FACE_UP)    { controller.buttons += {.Up} }
		if rl.IsGamepadButtonDown(0, .LEFT_FACE_DOWN)  { controller.buttons += {.Down} }

		// Left stick (with deadzone)
		DEADZONE :: 0.3
		stick_x := rl.GetGamepadAxisMovement(0, .LEFT_X)
		stick_y := rl.GetGamepadAxisMovement(0, .LEFT_Y)
		if stick_x >  DEADZONE { controller.buttons += {.Right} }
		if stick_x < -DEADZONE { controller.buttons += {.Left} }
		if stick_y < -DEADZONE { controller.buttons += {.Up} }
		if stick_y >  DEADZONE { controller.buttons += {.Down} }

		// Face buttons: B = west/left, A = south/down (natural NES layout)
		if rl.IsGamepadButtonDown(0, .RIGHT_FACE_LEFT)  { controller.buttons += {.B} } // X/Square
		if rl.IsGamepadButtonDown(0, .RIGHT_FACE_DOWN)  { controller.buttons += {.A} } // A/Cross
		// Also map right face buttons as alternatives
		if rl.IsGamepadButtonDown(0, .RIGHT_FACE_RIGHT) { controller.buttons += {.A} } // B/Circle
		if rl.IsGamepadButtonDown(0, .RIGHT_FACE_UP)    { controller.buttons += {.B} } // Y/Triangle

		// Start / Select
		if rl.IsGamepadButtonDown(0, .MIDDLE_RIGHT) { controller.buttons += {.Start} }
		if rl.IsGamepadButtonDown(0, .MIDDLE_LEFT)  { controller.buttons += {.Select} }

		// Shoulder buttons as A/B alternatives
		if rl.IsGamepadButtonDown(0, .RIGHT_TRIGGER_1) { controller.buttons += {.A} }
		if rl.IsGamepadButtonDown(0, .LEFT_TRIGGER_1)  { controller.buttons += {.B} }
	}
}
