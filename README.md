# mac-display-input-follow

When an external monitor with several inputs is switched away from your Mac, macOS can't tell: the cable is still connected, so your windows stay on a screen you can no longer see.

This tool watches the monitor's **active input over DDC/CI** and:

- **Monitor switched to another input:** turns the external display off in software, as if it were unplugged, so macOS moves every window to the laptop screen.
- **Monitor switched back to the Mac:** turns the display back on, and macOS moves the windows back.

It runs as a `launchd` login item and checks the monitor once a second.

## Requirements

- Apple Silicon Mac. DDC goes through `IOAVService`, which is Apple Silicon only.
- Monitor with DDC/CI enabled in its on-screen menu.
- Xcode Command Line Tools (`swiftc`).

## Install

```bash
make install     # builds extdisplay, installs to ~/.local/bin, loads the login item
```

Other targets: `make stop`, `make start`, `make restart`, `make logs`, `make uninstall`.

## Configure for your monitor

The defaults are for an MSI MAG322UPF with the Mac on HDMI 1. Find your values:

```bash
build/extdisplay list    # vendor= / model= of your external display
build/extdisplay input   # run while the Mac's input is showing -> MAC_INPUT
```

Then edit the defaults at the top of `bin/display-follow` (or set `MAC_INPUT`, `VENDOR` and `MODEL` in the plist's `EnvironmentVariables`) and run `make install` again.

## `extdisplay`

A small helper in `src/extdisplay.swift`:

| Command | What it does |
|---|---|
| `extdisplay list` | List online displays with ID, vendor and model |
| `extdisplay input` | Read the external monitor's input source (VCP `0x60`). Works while the display is disabled |
| `extdisplay off <id>` | Turn a display off in software |
| `extdisplay on <id>` | Turn it back on |

## Caveats

- The display is never turned off if it is the only active one (for example, with the laptop lid closed).
- Uses private Apple APIs: `CGSConfigureDisplayEnabled` to turn the display on and off, and `IOAVServiceReadI2C`/`IOAVServiceWriteI2C` for DDC. A macOS update could break them. If that happens, the display just stays on as normal.
- Only one external display is supported. The DDC reader talks to the first `External` AV service.
- If the monitor auto-scans inputs when it sees no signal, it may jump away from the Mac before the Mac turns the display back on. Turn off auto input-select on the monitor.
- If the display ever stays off, run `extdisplay on <id>` (the ID is cached in `~/.local/share/display-follow/display-id`), or unplug and replug the cable.
