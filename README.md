# ExeStart

Run Windows apps (`.exe`, `.msi`, `.bat`, `.lnk`) directly on macOS. **No virtual machine, no Windows license.**

ExeStart manages [Wine](https://www.winehq.org/) for you. It downloads a prebuilt Wine for macOS, creates "bottles" (each bottle is its own Windows `C:` drive), runs programs, installs Windows libraries through winetricks, and creates `.app` shortcuts so Windows programs open like Mac apps.

`exestart build` also **compiles source code into Windows `.exe` files right on your Mac** (Go, Rust, C/C++, .NET, Python) and can test-run the result with Wine. No Windows machine required.

Two front ends share one core library (`ExeStartKit`):

- **ExeStart.app**: a SwiftUI app. Drag and drop `.exe` files, browse installed programs, install libraries, adjust settings.
- **`exestart`**: a CLI for Terminal users and scripts.

> Unofficial project. Not affiliated with Microsoft, WineHQ or CodeWeavers.

## Requirements

- macOS 14 or later, Apple Silicon or Intel
- Apple Silicon needs Rosetta 2: `softwareupdate --install-rosetta --agree-to-license`
- Building from source: Xcode 16+ / Swift 6
- For winetricks: `cabextract`. ExeStart offers to install it through Homebrew when needed (`exestart doctor --fix`, or the **Install cabextract** button in the Libraries tab)

## Install

```bash
git clone https://github.com/huutq88/exestart.git && cd exestart
./scripts/build-app.sh --install
```

This installs `~/Applications/ExeStart.app` and `~/.local/bin/exestart`. Leave out `--install` to only build into `dist/`.

## Using the app

1. Open **ExeStart** and click **Download and Install Wine** (about 185 MB, one time only). The app creates a `Default` bottle.
2. Drag an `.exe`/`.msi` file onto the window, or click **Run .exe File…** in the toolbar (or File → **Run Windows Program…**, ⌘O).
3. Installed programs appear in the **Programs** tab. Double-click to open; right-click → **Add to Launchpad** to create a Mac shortcut.
4. In Finder: right-click an `.exe` file → **Open With → ExeStart**.

## Using the CLI

```bash
exestart doctor                                  # check Rosetta, Wine, cabextract
exestart doctor --fix                            # install what's missing (Wine, cabextract via Homebrew)
exestart runtime install                         # download the latest stable Wine
exestart bottle create Office --windows win10
exestart run ~/Downloads/setup.exe -b Office
exestart programs -b Office                      # list installed programs
exestart shortcut "~/Library/Application Support/ExeStart/Bottles/Office/prefix/drive_c/Program Files/App/App.exe" -b Office
exestart tricks corefonts vcrun2022 -b Office
exestart tool winecfg -b Office                  # winecfg, regedit, taskmgr, control, uninstaller, explorer, cmd
exestart bottle set Office --retina on --dpi 144
exestart kill --all                              # stop every running Windows program
```

Pass arguments to the program after `--`: `exestart run app.exe -- /silent`.
Debugging: add `-v` for verbose Wine logs. Every run writes a log to the bottle's `logs/` folder.

## Building .exe files on a Mac

```bash
exestart build                          # build the current folder (language is auto-detected)
exestart build ./my-app --run           # build, then test-run it with Wine
exestart build ./hello.c --gui          # windowed app, no console window
exestart build ./tool --arch x86 -o dist/tool32.exe
exestart build --dry-run                # only print the commands and any missing tools
```

Output goes to `<project>/build/windows/` by default.

| Project | Detected by | How it builds | Requires |
|---|---|---|---|
| Go | `go.mod`, `*.go` | `GOOS=windows go build` | `brew install go` |
| Rust | `Cargo.toml` | `cargo xwin build` (MSVC target); otherwise the GNU target with MinGW | `rustup target add x86_64-pc-windows-gnu` + `brew install mingw-w64`, or `cargo install cargo-xwin` |
| C / C++ | `*.c`, `*.cpp` | MinGW-w64, statically linked | `brew install mingw-w64` |
| CMake | `CMakeLists.txt` | CMake with a MinGW-w64 toolchain | `brew install cmake mingw-w64` |
| .NET | `*.csproj`, `*.sln` | `dotnet publish -r win-x64` as a single file | `brew install --cask dotnet-sdk` |
| Python | `*.py`, `requirements.txt` | PyInstaller running in **Windows** Python under Wine | Only Wine. The first build downloads Python 3.12 from python.org (~27 MB) into a "Python Build" bottle |

Python can't be cross-compiled: PyInstaller on macOS only produces Mac executables. ExeStart therefore runs the Windows build of Python inside Wine to produce a real `.exe`.

## Where data lives

```
~/Library/Application Support/ExeStart/
├── Runtimes/wine-stable-11.0_1/   # Wine versions
├── Bottles/<name>/
│   ├── bottle.json                # settings
│   ├── prefix/drive_c/            # the Windows C: drive
│   └── logs/
├── Cache/                         # winetricks, partial downloads
└── settings.json                  # default runtime
~/Applications/ExeStart/*.app      # shortcuts you created
```

Set `EXESTART_HOME=/some/path` to use a different folder (handy for testing).

## How it works

- **Wine** translates Windows API calls into macOS calls. It is not an emulator or a virtual machine: programs run as normal processes. On Apple Silicon, x86 code runs through Rosetta 2.
- Wine builds come from [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds), the same builds Homebrew's `wine-stable` cask used before Homebrew disabled that cask on 2026-09-01.
- Each bottle is a separate `WINEPREFIX`, so programs in one bottle don't affect another.

## Limitations

- Not every app works. Check compatibility on the [Wine AppDB](https://appdb.winehq.org/).
- Software with kernel-level anti-cheat, device drivers, or deep dependencies on Windows services (recent Office 365, Visual Studio) usually won't run.
- DirectX 10–12 games need D3DMetal or DXVK, which this version doesn't integrate yet.
- `exestart build` only wraps existing cross-compilers. Projects that need Visual Studio/MSBuild on Windows (C++ with MFC/ATL, drivers, `.vcxproj` files) can't be built yet.
- Python builds are x64 only. Packages with native code need Windows wheels on PyPI.

## Development

```bash
swift build                 # build everything
swift test                  # unit tests for ExeStartKit
swift run exestart --help
swift run ExeStartApp       # run the app without packaging
```

```
Sources/
├── ExeStartKit/   # core: Runtime, Bottle, Wine, Winetricks, Shortcut, Builder, PythonBuilder, Homebrew
├── exestart/      # CLI (swift-argument-parser)
└── ExeStartApp/   # SwiftUI app
scripts/build-app.sh
```

## License

[MIT](LICENSE). Wine (LGPL) is not part of this repository: ExeStart downloads Wine at runtime and invokes it as a separate program, so Wine's license applies to Wine itself, not to ExeStart.
