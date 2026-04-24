# GazeWinHost

`GazeWinHost` is a Windows host demo for the iPhone `GazeDemoApp` LAN stream.

It listens for the existing Gaze wire protocol on TCP `9000`, decodes provider samples, and renders a transparent gaze beam overlay. The overlay is designed to match the macOS host visual behavior: topmost, click-through, non-activating, 60 Hz animation, glow, lead circle, and trailing beam transition.

## Build

Requirements:

- Windows 10 or later
- Visual Studio 2022 Build Tools or a compatible MSVC toolchain
- CMake 3.20 or later

```powershell
cd demo/windows
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
```

## Run

```powershell
.\build\Release\GazeWinHost.exe 9000
```

Then run `GazeDemoApp` on a Face ID capable iPhone, choose LAN mode, and set the host IP to the Windows machine's LAN address with port `9000`.

## UI Behavior

- Topmost transparent overlay above all windows.
- Mouse click-through via `WS_EX_TRANSPARENT`.
- Non-activating tool window via `WS_EX_NOACTIVATE`.
- 60 Hz timer-driven beam animation.
- Glow/fill/stroke passes matching the macOS beam style.
- Lead/trail transition when gaze moves quickly.

The console also prints periodic diagnostics:

- confidence
- face distance
- heuristic screen coordinate

The mapping currently uses the same uncalibrated `lookAtPointFM` heuristic as the macOS host fallback. Full calibrated Windows overlay support should be built on top of the shared core C ABI and this stream decoder.
