package platform

import rl "vendor:raylib"
import "core:c"
import "core:fmt"
import "../nes"

TILE_SIZE    :: 8
TILES_PER_ROW :: 16
PATTERN_PX   :: TILES_PER_ROW * TILE_SIZE  // 128 pixels
VIEWER_SCALE :: 2
PATTERN_DRAW :: PATTERN_PX * VIEWER_SCALE  // 256 pixels drawn

// Render a single NES tile to an image at the given pixel position
draw_tile_to_image :: proc(img: ^rl.Image, ppu: ^nes.PPU, tile_addr: u16, palette_idx: u8, ox, oy: i32) {
	for row in u16(0)..<8 {
		lo := nes.ppu_bus_read(ppu, tile_addr + row)
		hi := nes.ppu_bus_read(ppu, tile_addr + row + 8)
		for col in u16(0)..<8 {
			bit := u8(7 - col)
			p0 := (lo >> bit) & 0x01
			p1 := (hi >> bit) & 0x01
			pixel := (p1 << 1) | p0

			color_idx: u8
			if pixel == 0 {
				color_idx = nes.ppu_bus_read(ppu, 0x3F00)
			} else {
				color_idx = nes.ppu_bus_read(ppu, 0x3F00 + u16(palette_idx) * 4 + u16(pixel))
			}

			rgba := nes.palette_to_rgba(color_idx)
			color := rl.Color{u8(rgba >> 24), u8((rgba >> 16) & 0xFF), u8((rgba >> 8) & 0xFF), 255}

			px := ox + i32(col)
			py := oy + i32(row)
			rl.ImageDrawPixel(img, px, py, color)
		}
	}
}

// Generate a 128x128 image of one pattern table (256 tiles)
gen_pattern_table_image :: proc(ppu: ^nes.PPU, table: u16, palette_idx: u8) -> rl.Image {
	img := rl.GenImageColor(PATTERN_PX, PATTERN_PX, rl.BLACK)

	for tile in u16(0)..<256 {
		tx := i32(tile % 16) * 8
		ty := i32(tile / 16) * 8
		tile_addr := table + tile * 16
		draw_tile_to_image(&img, ppu, tile_addr, palette_idx, tx, ty)
	}
	return img
}

// Generate an image of all current OAM sprites (up to 64 sprites in a grid)
gen_sprite_sheet_image :: proc(ppu: ^nes.PPU) -> rl.Image {
	h := u16(8)
	if (ppu.ctrl & 0x20) != 0 { h = 16 }

	// 8 sprites per row, 8 rows = 64 sprites
	img_w: i32 = 8 * 8  + 7  // 8 sprites * 8px + 7px gaps
	img_h: i32 = 8 * i32(h) + 7
	img := rl.GenImageColor(img_w, img_h, {0, 0, 0, 0}) // Transparent background

	spr_table := u16(ppu.ctrl & 0x08) << 9

	for i in u16(0)..<64 {
		oam_idx := i * 4
		tile_index := ppu.oam[oam_idx + 1]
		attributes := ppu.oam[oam_idx + 2]
		palette_idx := (attributes & 0x03) + 4 // Sprite palettes are 4-7

		grid_x := i32(i % 8)
		grid_y := i32(i / 8)
		ox := grid_x * 9  // 8px + 1px gap
		oy := grid_y * (i32(h) + 1)

		if h == 16 {
			table := u16(tile_index & 0x01) * 0x1000
			tile := u16(tile_index & 0xFE)
			draw_tile_to_image(&img, ppu, table + tile * 16, palette_idx, ox, oy)
			draw_tile_to_image(&img, ppu, table + (tile + 1) * 16, palette_idx, ox, oy + 8)
		} else {
			tile_addr := spr_table + u16(tile_index) * 16
			draw_tile_to_image(&img, ppu, tile_addr, palette_idx, ox, oy)
		}
	}
	return img
}

// Draw the pattern viewer overlay
platform_render_viewer :: proc(p: ^Platform, ppu: ^nes.PPU) {
	rl.BeginDrawing()
	rl.ClearBackground({24, 24, 32, 255})

	// ---- Pattern tables ----
	margin_x: f32 = 20
	margin_y: f32 = 40

	rl.DrawText("Pattern Table $0000", i32(margin_x), 20, 16, rl.LIGHTGRAY)
	rl.DrawText("Pattern Table $1000", i32(margin_x) + PATTERN_DRAW + 20, 20, 16, rl.LIGHTGRAY)

	// Generate and draw pattern table 0
	img0 := gen_pattern_table_image(ppu, 0x0000, p.viewer_palette)
	tex0 := rl.LoadTextureFromImage(img0)
	rl.DrawTextureEx(tex0, {margin_x, margin_y}, 0, VIEWER_SCALE, rl.WHITE)
	rl.UnloadTexture(tex0)
	rl.UnloadImage(img0)

	// Generate and draw pattern table 1
	img1 := gen_pattern_table_image(ppu, 0x1000, p.viewer_palette)
	tex1 := rl.LoadTextureFromImage(img1)
	rl.DrawTextureEx(tex1, {margin_x + PATTERN_DRAW + 20, margin_y}, 0, VIEWER_SCALE, rl.WHITE)
	rl.UnloadTexture(tex1)
	rl.UnloadImage(img1)

	// ---- Palette display ----
	pal_y: f32 = margin_y + PATTERN_DRAW + 20
	rl.DrawText("Palettes (click to select)", i32(margin_x), i32(pal_y) - 16, 16, rl.LIGHTGRAY)

	for p_idx in u8(0)..<8 {
		label := "BG" if p_idx < 4 else "SPR"
		label_x := margin_x + f32(p_idx) * 65
		rl.DrawText(fmt.ctprintf("%s%d", label, p_idx % 4), i32(label_x), i32(pal_y), 12, rl.GRAY)

		for c_idx in u16(0)..<4 {
			color_idx := nes.ppu_bus_read(ppu, 0x3F00 + u16(p_idx) * 4 + c_idx)
			rgba := nes.palette_to_rgba(color_idx)
			color := rl.Color{u8(rgba >> 24), u8((rgba >> 16) & 0xFF), u8((rgba >> 8) & 0xFF), 255}

			sx := label_x + f32(c_idx) * 15
			sy := pal_y + 14

			rl.DrawRectangleRec({sx, sy, 14, 14}, color)

			// Highlight selected palette
			if p_idx == p.viewer_palette {
				rl.DrawRectangleLinesEx({sx, sy, 14, 14}, 2, rl.WHITE)
			}
		}

		// Click to select palette
		px := label_x
		py := pal_y + 14
		if rl.IsMouseButtonPressed(.LEFT) {
			mouse := rl.GetMousePosition()
			if mouse.x >= px && mouse.x < px + 60 && mouse.y >= py && mouse.y < py + 14 {
				p.viewer_palette = p_idx
			}
		}
	}

	// ---- OAM Sprite preview ----
	spr_y := pal_y + 50
	rl.DrawText("OAM Sprites (64)", i32(margin_x), i32(spr_y) - 16, 16, rl.LIGHTGRAY)

	spr_img := gen_sprite_sheet_image(ppu)
	spr_tex := rl.LoadTextureFromImage(spr_img)
	rl.DrawTextureEx(spr_tex, {margin_x, spr_y}, 0, 2, rl.WHITE)
	rl.UnloadTexture(spr_tex)
	rl.UnloadImage(spr_img)

	// ---- Export buttons ----
	btn_x := margin_x + PATTERN_DRAW + 80
	btn_y := spr_y

	if rl.GuiButton({btn_x, btn_y, 180, 30}, "Export Pattern Tables") {
		export_img0 := gen_pattern_table_image(ppu, 0x0000, p.viewer_palette)
		export_img1 := gen_pattern_table_image(ppu, 0x1000, p.viewer_palette)
		rl.ExportImage(export_img0, "pattern_table_0.png")
		rl.ExportImage(export_img1, "pattern_table_1.png")
		rl.UnloadImage(export_img0)
		rl.UnloadImage(export_img1)
		fmt.println("Exported pattern_table_0.png and pattern_table_1.png")
	}

	if rl.GuiButton({btn_x, btn_y + 40, 180, 30}, "Export Sprite Sheet") {
		export_spr := gen_sprite_sheet_image(ppu)
		rl.ExportImage(export_spr, "sprites.png")
		rl.UnloadImage(export_spr)
		fmt.println("Exported sprites.png")
	}

	if rl.GuiButton({btn_x, btn_y + 80, 180, 30}, "Export All Tiles") {
		// Export all 512 tiles as a single 256x128 image
		all_img := rl.GenImageColor(256, 128, rl.BLACK)
		for tile in u16(0)..<256 {
			tx := i32(tile % 16) * 8
			ty := i32(tile / 16) * 8
			draw_tile_to_image(&all_img, ppu, tile * 16, p.viewer_palette, tx, ty)
		}
		for tile in u16(0)..<256 {
			tx := i32(tile % 16) * 8 + 128
			ty := i32(tile / 16) * 8
			draw_tile_to_image(&all_img, ppu, 0x1000 + tile * 16, p.viewer_palette, tx, ty)
		}
		rl.ExportImage(all_img, "all_tiles.png")
		rl.UnloadImage(all_img)
		fmt.println("Exported all_tiles.png (256x128)")
	}

	// ---- Help text ----
	rl.DrawText("F2: Back to game", i32(margin_x), SCREEN_H - 20, 14, rl.GRAY)

	rl.EndDrawing()
}
