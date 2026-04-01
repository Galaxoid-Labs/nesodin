# CLAUDE.md — NesOdin: NES Emulator in Odin

## Project Overview

**NesOdin** is a cycle-approximate NES (Nintendo Entertainment System) emulator written in Odin, targeting desktop platforms (macOS, Linux, Windows). It runs the majority of the licensed NES library with correct video, audio, and input.

**Tech Stack:**
- **Language:** Odin
- **Video/Input/Audio:** `vendor:raylib` v5.5 (bundled with Odin — no external deps)
- **Build:** `odin build .` / `odin run .`
- **Testing:** `odin test nes/` with `core:testing`

**Design Principles:**
- Data-oriented: flat structs, no OOP hierarchies, plain arrays for memory
- Separation of emulation core from platform layer (raylib is isolated in `platform/`)
- Cycle-accurate enough to pass standard test ROMs, not cycle-exact
- No dynamic allocation in the hot path — all memory is statically sized

---

## Architecture

```
nesodin/
├── CLAUDE.md
├── README.md
├── main.odin                # Entry point, main loop, --nestest mode
├── nestest_runner.odin      # Nestest CPU validation harness
├── nes/
│   ├── nes.odin             # Top-level NES struct, tick coordination, frame loop
│   ├── cpu.odin             # 6502 CPU: registers, flags, stack, reset, NMI, IRQ
│   ├── cpu_opcodes.odin     # All 256 opcodes (151 official + unofficial), addressing modes
│   ├── ppu.odin             # PPU: rendering, sprites, sprite 0 hit, scrolling, NMI
│   ├── ppu_bus.odin         # PPU memory bus: pattern tables, nametables, palette mirroring
│   ├── apu.odin             # APU: pulse, triangle, noise, DMC, frame counter, mixer, filters
│   ├── bus.odin             # CPU memory bus: RAM, PPU/APU registers, mapper dispatch
│   ├── cartridge.odin       # iNES ROM parser, mapper init
│   ├── controller.odin      # Joypad shift register
│   ├── palette.odin         # NES master palette (64 RGB colors)
│   ├── nes_test.odin        # Unit tests (61 tests)
│   └── mappers/
│       ├── mapper.odin      # Mapper union + dispatch (read/write/mirror/IRQ)
│       ├── mapper_000.odin  # NROM
│       ├── mapper_001.odin  # MMC1
│       ├── mapper_002.odin  # UxROM
│       ├── mapper_003.odin  # CNROM
│       ├── mapper_004.odin  # MMC3 (scanline IRQ)
│       ├── mapper_007.odin  # AxROM
│       ├── mapper_009.odin  # MMC2 (CHR latch)
│       ├── mapper_010.odin  # MMC4 (CHR latch)
│       ├── mapper_011.odin  # Color Dreams
│       ├── mapper_066.odin  # GxROM
│       └── mapper_071.odin  # Camerica
└── platform/
    ├── platform.odin        # Window, texture, audio stream, input, menu, CRT shader
    ├── viewer.odin          # Pattern table viewer, sprite extraction, PNG export
    └── crt.glsl             # CRT post-processing shader
```

---

## Build & Run

```bash
# Build
odin build .

# Build optimized
odin build . -o:speed

# Run a game
./nesodin path/to/game.nes

# Run without a ROM (drag and drop onto window)
./nesodin

# Run CPU validation
./nesodin --nestest

# Run unit tests
odin test nes/
```

---

## Controls

**Game:**

| Key | Action |
|-----|--------|
| Arrow keys | D-pad |
| Z | B |
| X | A |
| Enter | Start |
| Right Shift | Select |

**Emulator:**

| Key | Action |
|-----|--------|
| Escape | Toggle menu (pauses game) |
| F1 | Toggle CRT shader |
| F2 | Pattern viewer / sprite extraction |
| F5 | Quick save state |
| F9 | Quick load state |
| F12 | Reset console |
| Tab (hold) | Fast forward (3x speed) |

---

## Supported Mappers

| # | Name | Games | Notes |
|---|------|-------|-------|
| 0 | NROM | SMB, Donkey Kong, Excitebike | |
| 1 | MMC1 | Zelda, Metroid, Mega Man 2, Final Fantasy | Dynamic mirroring, shift register |
| 2 | UxROM | Castlevania, Contra, Life Force, Mega Man | PRG bank switching |
| 3 | CNROM | Arkanoid, Gradius, Solomon's Key | CHR bank switching |
| 4 | MMC3 | SMB3, Kirby, Mega Man 3-6, Batman, TMNT | Scanline IRQ, dynamic mirroring |
| 7 | AxROM | Marble Madness, Wizards & Warriors | Single-screen mirroring |
| 9 | MMC2 | Punch-Out!! | CHR latch mechanism |
| 10 | MMC4 | Fire Emblem (JP) | CHR latch (like MMC2) |
| 11 | Color Dreams | Bible Adventures, Crystal Mines | |
| 66 | GxROM | SMB/Duck Hunt, Dragon Power | |
| 71 | Camerica | Micro Machines, Fire Hawk | |

Covers ~85-90% of the licensed NES library.

---

## CPU

- All 151 official 6502 opcodes, 13 addressing modes
- 10 unofficial opcode families (LAX, SAX, DCP, ISB, SLO, SRE, RLA, RRA, NOP variants, SBC $EB)
- **Nestest: 8991/8991 lines pass** (official + unofficial)
- NMI, IRQ, BRK with correct stack/flag behavior
- OAM DMA with CPU stall (513 cycles)

## PPU

- Background rendering with shift registers, tile fetching, scrolling
- Sprite rendering (8x8 and 8x16) with priority, flipping, sprite 0 hit
- Nametable mirroring (horizontal, vertical, single-screen, four-screen)
- Dynamic mirroring for mappers that control it (MMC1, MMC3, MMC2, AxROM)
- VBlank NMI with edge detection
- Pre-render scanline flag clearing, odd frame skip
- Left-column masking (overscan hiding)
- Mapper scanline counter (MMC3 IRQ)

## APU

- 2 pulse channels (duty cycle, envelope, sweep, length counter)
- Triangle channel (linear counter, 32-step waveform)
- Noise channel (LFSR, short/long mode, envelope)
- DMC channel (delta modulation, DMA sample playback)
- Frame counter (4-step and 5-step modes)
- Non-linear mixer with precalculated lookup tables
- Hardware-accurate filter chain (high-pass 37Hz + 14Hz, low-pass 14kHz)
- Audio streaming via raylib at 44100Hz

## Platform

- Raylib window at 3x scale (768x720)
- Texture streaming from PPU framebuffer
- CRT post-processing shader (barrel distortion, scanlines, shadow mask, vignette)
- Keyboard input mapping
- 60 FPS frame pacing
- Raygui overlay menu (Escape) with save/load slots, volume, settings, controls reference
- Pattern table viewer (F2) with palette selection and PNG export
- Sprite sheet extraction from OAM
- Drag-and-drop ROM loading
- Save states (4 slots, in-memory snapshots)
- Battery saves (SRAM persisted to .sav files, auto-saves every 5 seconds)
- Fast forward (Tab, 3x speed)

---

## Known Issues

- **Battletoads / Cobra Triangle** (Rare, mapper 7): Freeze at gameplay start. Game polls for sprite 0 hit with a transparent sprite tile. Requires cycle-accurate PPU to resolve.
- **Audio artifacts**: Minor remaining artifacts in music. BLEP synthesis and callback-based audio would improve quality.
- **Punch-Out**: Mostly works but some visual glitches remain from MMC2 latch timing.

---

## Key Implementation Details

### CPU-PPU Synchronization
The CPU executes one full instruction, then the PPU catches up (3 PPU cycles per CPU cycle). This is coarse but sufficient for most games. Cycle-exact interleaving would improve compatibility with timing-sensitive titles.

### Mapper Architecture
Mappers use an Odin tagged union (`Mapper :: union { Mapper_000, Mapper_001, ... }`). Dispatch is via `switch &m in mapper`. Each mapper implements cpu_read, cpu_write, ppu_read, ppu_write, and optionally mirror_mode and scanline (for IRQ).

### Cartridge Copy Fix
When the `Cartridge` struct is copied into the `NES` struct, internal slice pointers (CHR RAM, PRG ROM) become dangling. `cartridge_init_mapper()` re-initializes the mapper with corrected pointers after the copy.

### CHR RAM Initialization
CHR RAM is initialized to `$FF` (non-zero) to approximate real NES power-on state, where RAM contains random data.
