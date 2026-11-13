# mac-display-input-follow

When an external monitor with several inputs is switched away from your Mac, macOS can't tell: the cable is still connected, so your windows stay on a screen you can no longer see.

`display-follow` watches each external monitor's **active input over DDC/CI** and, by default:

- **Monitor switched to another input:** turns the external display off in software, as if it were unplugged, so macOS moves every window to the laptop screen.
- **Monitor switched back to the Mac:** turns the display back on, and macOS moves the windows back.

Each monitor can instead be mirrored onto the laptop screen, or left alone, and can run your own commands on each switch.

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

### With Homebrew

The formula lives in this repository, so tap it directly:

```bash
brew tap joaoestrela/display-follow https://github.com/joaoestrela/mac-display-input-follow
brew install --HEAD display-follow
display-follow setup                   # while each monitor shows the Mac
brew services start display-follow     # logs to $(brew --prefix)/var/log/display-follow.log
```

`brew upgrade --fetch-HEAD display-follow` picks up new commits. Use either Homebrew or `make install`, not both: two watchers would fight.

### From a release

Each `v*` tag builds an arm64 binary and attaches `display-follow-<tag>-macos-arm64.tar.gz` (with a `.sha256`) to a GitHub release. The binary is ad-hoc signed, not notarized: after downloading, clear the quarantine flag with `xattr -d com.apple.quarantine display-follow`.

To cut a release, set the version in `Sources/DisplayFollowCore/Version.swift`, commit, then push a matching tag (`v0.2.0` for `0.2.0`); the workflow fails if they differ.

## Configure

`display-follow setup` records each external monitor and the input it is showing right now, so run it while the Mac is on screen. Monitors that don't answer over DDC are skipped. It writes `~/.config/display-follow/config.json` (or `$XDG_CONFIG_HOME/display-follow/config.json`):

```json
{
  "confirmReads" : 2,
  "ddcLossTimeout" : 30,
  "interval" : 1,
  "monitors" : [
    {
      "name" : "MSI MAG322UPF", "vendor" : 13929, "model" : 19911, "serial" : 16843009,
      "macInput" : 17,
      "action" : "disable",
      "onAway" : "osascript -e 'set volume output muted true'",
      "onBack" : "osascript -e 'set volume output muted false'"
    }
  ],
  "wakeGrace" : 5
}
```

- `interval`: seconds between DDC reads.
- `confirmReads`: how many reads in a row must agree before acting, so one bad reading can't turn a monitor off. With the defaults, a switch takes effect in about 2 seconds.
- `wakeGrace`: seconds to wait after the Mac or its displays wake before acting. Polling pauses while the Mac or its displays sleep, so DDC traffic can't keep a monitor awake.
- `ddcLossTimeout`: seconds without a DDC reply after which a monitor that was turned off is turned back on (for example, when it was powered off). `0` disables this.
- `macInput`: the input value the monitor reports while showing this Mac. Run `setup` again if you move the Mac to another port; it keeps the monitor's `action` and hooks.
- `action`: what to do while the monitor shows another input.
  - `disable` (default): turn the display off in software; windows move to the remaining displays.
  - `mirror`: mirror it onto the built-in display (or another active one); windows gather there. Window positions on the external display are not restored afterwards.
  - `none`: leave the display alone and only run the hooks. Works with the laptop lid closed.
- `onAway` / `onBack` (optional): shell commands run with `/bin/sh -c` after the monitor switches away from or back to the Mac. They get `DISPLAY_FOLLOW_EVENT` (`away`/`back`), `DISPLAY_FOLLOW_MONITOR`, `DISPLAY_FOLLOW_PORT` and `DISPLAY_FOLLOW_INPUT`. The watcher doesn't wait for them; non-zero exits are logged.

The watcher reloads the file when it changes; no restart needed. `display-follow status` shows the config next to what the monitor reports now.

## Safety

A display turned off in software isn't listed by macOS any more, so `display-follow` records each display it turns off or mirrors in `~/.local/state/display-follow/state.json` (or `$XDG_STATE_HOME`) and undoes that when:

- the watcher stops (`make stop`, `make uninstall`, logout, Ctrl-C);
- the monitor stops answering over DDC for `ddcLossTimeout` seconds;
- you run `display-follow restore`.

A monitor unplugged while off is forgotten; macOS turns it on again when it is reconnected. After a crash, the restarted watcher picks up the state file and keeps following those displays.

## Commands

| Command | What it does |
|---|---|
| `display-follow setup` | Save each external monitor and the Mac's current input to the config |
| `display-follow status` | Show each external monitor, its config and its current input |
| `display-follow run [--dry-run]` | Watch the monitors. `--dry-run` logs decisions without changing displays |
| `display-follow list` | List online displays with ID, vendor, model, serial and port |
| `display-follow input` | Read each external monitor's input source (VCP `0x60`). Works while a display is disabled |
| `display-follow restore` | Undo every display `display-follow` turned off or mirrored |
| `display-follow off <id>` | Turn a display off in software |
| `display-follow on <id>` | Turn it back on |

## Caveats

- A display is never turned off or mirrored away if it is the only active one (for example, with the laptop lid closed). Hooks still run.
- Uses private Apple APIs: `CGSConfigureDisplayEnabled` to turn the display on and off, `IOAVServiceReadI2C`/`IOAVServiceWriteI2C` for DDC, and `CoreDisplay_DisplayCreateInfoDictionary` to match monitors to displays. Mirroring uses the public `CGConfigureDisplayMirrorOfDisplay`. A macOS update could break them. If that happens, the display just stays on as normal.
- Monitors are told apart by their EDID vendor, model and serial number. Identical monitors that report the same serial (many use a placeholder) share one config entry, so they must be connected to the same input number.
- Each monitor's DDC service is matched to its display through the Apple Silicon port name (`dispextN`) in the IORegistry, which appears in both the DDC service's path and the display's `IODisplayLocation`.
- If the monitor auto-scans inputs when it sees no signal, it may jump away from the Mac before the Mac turns the display back on. Turn off auto input-select on the monitor.
- If a display ever stays off, run `display-follow restore`, or unplug and replug the cable.

## Development

```bash
make build check                  # build and run the offline logic checks (Sources/selfcheck)
.build/display-follow run --dry-run
```

The build calls `swiftc` directly instead of using SwiftPM, so it only needs the compiler from the Command Line Tools: `swift test` needs a full Xcode install, and SwiftPM's manifest library can be out of step with the compiler in some Command Line Tools installs. CI (`.github/workflows/ci.yml`) runs `make build check` on an Apple Silicon runner for pushes to `main` and pull requests that touch the code.

## License

[MIT](LICENSE)
