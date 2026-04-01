# NesOdin

A NES (Nintendo Entertainment System) emulator written in [Odin](https://odin-lang.org/), using [raylib](https://www.raylib.com/) for video, audio, and input.

## Features

- **CPU**: Full 6502 instruction set (official + unofficial opcodes) — 100% nestest passing
- **PPU**: Background and sprite rendering, scrolling, sprite 0 hit, 8x16 sprites
- **APU**: All 5 audio channels (2x pulse, triangle, noise, DMC) with hardware-accurate filtering
- **11 mappers**: Covers ~85-90% of the licensed NES library
- **CRT shader**: Optional post-processing with scanlines, curvature, and shadow mask
- **Save states**: 4 slots with quick save/load
- **Battery saves**: Automatic SRAM persistence for games like Zelda and Final Fantasy
- **Pattern viewer**: Inspect CHR tiles and export sprites as PNG
- **Drag and drop**: Drop a `.nes` file onto the window to play

## Supported Mappers

| Mapper | Name | Notable Games |
|--------|------|---------------|
| 0 | NROM | Super Mario Bros, Donkey Kong, Excitebike |
| 1 | MMC1 | The Legend of Zelda, Metroid, Mega Man 2 |
| 2 | UxROM | Castlevania, Contra, Life Force |
| 3 | CNROM | Arkanoid, Gradius |
| 4 | MMC3 | Super Mario Bros 3, Kirby's Adventure, Batman |
| 7 | AxROM | Marble Madness, Wizards & Warriors |
| 9 | MMC2 | Punch-Out!! |
| 10 | MMC4 | Fire Emblem (JP) |
| 11 | Color Dreams | Crystal Mines |
| 66 | GxROM | SMB / Duck Hunt |
| 71 | Camerica | Micro Machines |

## Building

Requires [Odin](https://odin-lang.org/) (raylib is bundled with the compiler).

```bash
# Build
odin build .

# Build optimized
odin build . -o:speed

# Run
./nesodin game.nes

# Run without a ROM (drag and drop onto window)
./nesodin
```

## Controls

### Game

| Key | NES Button |
|-----|-----------|
| Arrow keys | D-pad |
| Z | B |
| X | A |
| Enter | Start |
| Right Shift | Select |

### Emulator

| Key | Action |
|-----|--------|
| Escape | Toggle menu (pauses game) |
| F1 | Toggle CRT shader |
| F2 | Pattern viewer / sprite extraction |
| F5 | Quick save state |
| F9 | Quick load state |
| F12 | Reset console |
| Tab (hold) | Fast forward (3x speed) |

The menu (Escape) also shows all controls for reference.

## Pattern Viewer & Sprite Extraction

Press **F2** to open the pattern viewer. It shows:

- Both pattern tables ($0000 and $1000) rendered with the selected palette
- All 8 NES palettes — click to switch which one renders the tiles
- Current OAM sprites (all 64)
- **Export buttons** to save pattern tables, sprite sheets, or all tiles as PNG files

## Testing

```bash
# Unit tests (61 tests)
odin test nes/

# CPU validation against nestest.nes (8991 tests)
./nesodin --nestest
```

## Architecture

```
nesodin/
├── main.odin              # Entry point, game loop, save states
├── nestest_runner.odin    # CPU validation harness
├── nes/                   # Emulation core (no platform dependencies)
│   ├── cpu.odin           # 6502 CPU
│   ├── cpu_opcodes.odin   # Opcode table and execution
│   ├── ppu.odin           # Picture Processing Unit
│   ├── apu.odin           # Audio Processing Unit
│   ├── bus.odin           # CPU memory bus
│   ├── cartridge.odin     # ROM loading, battery saves
│   └── mappers/           # Cartridge mapper implementations
└── platform/              # Raylib integration
    ├── platform.odin      # Window, audio, input, menu (raygui)
    ├── viewer.odin        # Pattern table viewer, sprite export
    └── crt.glsl           # CRT post-processing shader
```

The emulation core (`nes/`) has no platform dependencies and can be used independently.

## License

This project is for educational purposes.
