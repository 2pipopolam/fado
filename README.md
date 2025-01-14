# Fado - Terminal MP3 Player

A lightweight terminal-based MP3 player written in Zig. Fado provides a simple interface for playing MP3 files directly from your terminal.

## Features

- Simple terminal interface
- MP3 playback with basic controls (play, pause, stop)
- Proper stereo audio handling
- Automatic sample rate detection
- Low memory footprint
- Built with Zig and PortAudio

## Requirements

- Zig 0.11.0 or later
- PortAudio v19
- pkg-config
- A C compiler (for linking)

### On Nix/NixOS:
```bash
nix develop
```

### On Ubuntu/Debian:
```bash
sudo apt install zig portaudio19-dev pkg-config build-essential
```

### On Fedora:
```bash
sudo dnf install zig portaudio-devel pkgconfig gcc
```

### On Arch Linux:
```bash
sudo pacman -S zig portaudio pkg-config base-devel
```

## Building

Clone the repository:
```bash
git clone https://github.com/2pipopolam/fado.git
cd fado
```

Build the project:
```bash
zig build
```

## Usage

Run Fado:
```bash
zig build run
```

Or after installation:
```bash
./zig-out/bin/fado
```

### Commands

- `load <file>` - Load an MP3 file
- `play` - Start playback
- `pause` - Pause playback
- `stop` - Stop playback
- `quit` - Exit the program
