# mac-display-input-follow

When an external monitor with several inputs is switched away from your Mac, macOS can't tell: the cable is still connected, so your windows stay on a screen you can no longer see.

`display-follow` watches the monitor's **active input over DDC/CI** and:

- **Monitor switched to another input:** turns the external display off in software, as if it were unplugged, so macOS moves every window to the laptop screen.
- **Monitor switched back to the Mac:** turns the display back on, and macOS moves the windows back.

It runs as a `launchd` login item and checks the monitor once a second.

## Requirements

- Apple Silicon Mac. DDC goes through `IOAVService`, which is Apple Silicon only.
- Monitor with DDC/CI enabled in its on-screen menu.
- Xcode Command Line Tools (`swiftc`). The build uses plain `swiftc`, not SwiftPM.

## Install

Run this while the monitor is showing the Mac:

```bash
make install     # builds display-follow, installs to ~/.local/bin, runs setup if needed, loads the login item
```

Other targets: `make check` (offline logic checks), `make stop`, `make start`, `make restart`, `make logs`, `make uninstall`.

## Configure

`display-follow setup` records the external monitor and the input it is showing right now, so run it while the Mac is on screen. It writes `~/.config/display-follow/config.json` (or `$XDG_CONFIG_HOME/display-follow/config.json`):

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
| `display-follow setup` | Save the external monitor and the Mac's current input to the config |
| `display-follow status` | Show the config and the monitor's current input |
| `display-follow run [--dry-run]` | Watch the monitor. `--dry-run` logs decisions without changing displays |
| `display-follow list` | List online displays with ID, vendor, model and serial |
| `display-follow input` | Read the external monitor's input source (VCP `0x60`). Works while the display is disabled |
| `display-follow off <id>` | Turn a display off in software |
| `display-follow on <id>` | Turn it back on |

## Caveats

- The display is never turned off if it is the only active one (for example, with the laptop lid closed).
- Uses private Apple APIs: `CGSConfigureDisplayEnabled` to turn the display on and off, and `IOAVServiceReadI2C`/`IOAVServiceWriteI2C` for DDC. A macOS update could break them. If that happens, the display just stays on as normal.
- Only one external display is supported. The DDC reader talks to the first `External` AV service.
- If the monitor auto-scans inputs when it sees no signal, it may jump away from the Mac before the Mac turns the display back on. Turn off auto input-select on the monitor.
- If the display ever stays off, run `display-follow on <id>` with the ID it had in `display-follow list` (usually `2`), or unplug and replug the cable.
