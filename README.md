# mac-display-input-follow

When an external monitor with several inputs is switched away from your Mac, macOS can't tell: the cable is still connected, so your windows stay on a screen you can no longer see.

`display-follow` watches each external monitor's **active input over DDC/CI** and:

- **Monitor switched to another input:** turns the external display off in software, as if it were unplugged, so macOS moves every window to the laptop screen.
- **Monitor switched back to the Mac:** turns the display back on, and macOS moves the windows back.

It runs as a `launchd` login item and checks the monitors once a second. Each external monitor is followed on its own.

## Requirements

- Apple Silicon Mac. DDC goes through `IOAVService`, which is Apple Silicon only.
- Monitor with DDC/CI enabled in its on-screen menu.
- Xcode Command Line Tools (`swiftc`). The build uses plain `swiftc`, not SwiftPM.

## Install

Run this while the monitors are showing the Mac:

```bash
make install     # builds display-follow, installs to ~/.local/bin, runs setup if needed, loads the login item
```

Other targets: `make check` (offline logic checks), `make stop`, `make start`, `make restart`, `make logs`, `make uninstall`.

## Configure

`display-follow setup` records each external monitor and the input it is showing right now, so run it while the Mac is on screen. Monitors that don't answer over DDC are skipped. It writes `~/.config/display-follow/config.json` (or `$XDG_CONFIG_HOME/display-follow/config.json`):

```json
{
  "interval" : 1,
  "monitors" : [
    { "name" : "MSI MAG322UPF", "vendor" : 13929, "model" : 19911, "serial" : 16843009, "macInput" : 17 }
  ]
}
```

- `interval`: seconds between DDC reads.
- `macInput`: the input value the monitor reports while showing this Mac. Run `setup` again if you move the Mac to another port.

The watcher reloads the file when it changes; no restart needed. `display-follow status` shows the config next to what the monitor reports now.

## Commands

| Command | What it does |
|---|---|
| `display-follow setup` | Save each external monitor and the Mac's current input to the config |
| `display-follow status` | Show each external monitor, its config and its current input |
| `display-follow run [--dry-run]` | Watch the monitors. `--dry-run` logs decisions without changing displays |
| `display-follow list` | List online displays with ID, vendor, model, serial and port |
| `display-follow input` | Read each external monitor's input source (VCP `0x60`). Works while a display is disabled |
| `display-follow off <id>` | Turn a display off in software |
| `display-follow on <id>` | Turn it back on |

## Caveats

- The display is never turned off if it is the only active one (for example, with the laptop lid closed).
- Uses private Apple APIs: `CGSConfigureDisplayEnabled` to turn the display on and off, and `IOAVServiceReadI2C`/`IOAVServiceWriteI2C` for DDC. A macOS update could break them. If that happens, the display just stays on as normal.
- Monitors are told apart by their EDID vendor, model and serial number. Identical monitors that report the same serial (many use a placeholder) share one config entry, so they must be connected to the same input number.
- Each monitor's DDC service is matched to its display through the Apple Silicon port name (`dispextN`) in the IORegistry, which appears in both the DDC service's path and the display's `IODisplayLocation`.
- If the monitor auto-scans inputs when it sees no signal, it may jump away from the Mac before the Mac turns the display back on. Turn off auto input-select on the monitor.
- If a display ever stays off, run `display-follow on <id>` with the ID it had in `display-follow list` (usually `2`), or unplug and replug the cable.
