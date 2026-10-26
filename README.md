# tern-openrct2

OpenRCT2 in [Tern](https://docs.stencil.so/tern/): upstream OpenRCT2 built to
WebAssembly and played in a Tern browser pane, a live park block beside it, a
park renderer block, and a JSON API agents can drive. No game art ships; every
block uses the player's own RollerCoaster Tycoon 2 data.

- `openrct2-web/` — the wasm build, its web shell, the loopback server and the
  `orct2` agent CLI ([README](openrct2-web/README.md): API, verbs, examples).
- `plugin/` — the Tern plugin (`openrct2.game` and `openrct2.park` blocks).
- `module.nix` — the Home Manager module; `flake.nix` exposes everything.

## What it does

- **OpenRCT2: Play** (`cmd+alt+o`) opens the `openrct2.game` block and docks a
  browser pane on `http://127.0.0.1:<port>/` to its right, or focuses the pane
  that already shows it. The tab reads "OpenRCT2", and the browser address bar
  is hidden while the game pane has focus.
- The game block polls the agent API every 2 s and shows date, cash, guests,
  park rating, rides, scenario objective and status, paused/speed, and whether
  the server is down or the game page is not connected. Dock buttons and keys:
  pause/resume (`space`), speed 1-4 (`1`-`4`), save as `tern` (`s`), game pane
  (`g`).
- **OpenRCT2: Park** / **OpenRCT2: Choose Park** open the park renderer
  (`openrct2.park`): `openrct2 screenshot <park> <out.png> giant <zoom>
  <rotation>`, shown in a Tern surface. Keys: `z`/`x` zoom, `r` rotate, `p`
  picker, `g` render again. `TERN_OPENRCT2_BIN` overrides the packaged binary;
  `TERN_OPENRCT2_PARK` names a park to open.

## Setup

Nix is required: the plugin has the packaged OpenRCT2 binary and the server
port substituted at build time.

```nix
# flake inputs
tern-openrct2.url = "github:ocasazza/tern-openrct2";

# a home module list
inputs.tern-openrct2.homeManagerModules.default

# home configuration
programs.tern-openrct2 = {
  enable = true;
  port = 8737; # default; the plugin and ORCT2_URL follow it
};
```

The module runs `openrct2-web` as a launchd agent (a systemd user service on
Linux), links the plugin into Tern, puts `orct2` and `openrct2-setup` on
`PATH`, and exports `ORCT2_URL`.

The server reads the RCT2 data directory from `~/.config/openrct2/game-path`.
Write it once with `openrct2-setup <installer.exe | folder with Data/g1.dat>`.
Server logs: `~/Library/Logs/openrct2-web.log`.

`openrct2-web` builds with emscripten 6.0.9 from the pinned nixpkgs; its
emscripten port hashes are tied to that version, so do not make this flake's
`nixpkgs` input follow another one.

The park renderer finds its game data through `TERN_RCT2_PATH`, `config.ini`'s
`game_path`, or the usual Steam/GOG directories.

## Licence

`plugin/` and `module.nix`: MIT (`LICENSE`). `openrct2-web/`: GPL-3.0-or-later,
as its patches modify OpenRCT2. RollerCoaster Tycoon 2 is © Atari; none of its
data is redistributed here.
