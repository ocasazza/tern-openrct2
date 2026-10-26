{
  lib,
  runCommand,
  innoextract,
  openrct2,
  # Loopback port of the openrct2-web server; the module option feeds it.
  port ? 8737,
}:

# A Tern plugin is a directory: manifest, host half, window half and
# stylesheets. The park block renders parks with the packaged OpenRCT2 and
# redistributes no game artwork; the game block drives the openrct2-web server
# and its browser pane. `bin/openrct2-setup` records where the player's RCT2
# data lives.
runCommand "tern-openrct2-0.2.0"
  {
    meta = {
      description = "Tern plugin: an OpenRCT2 park block and a game block for the openrct2-web pane";
      homepage = "https://github.com/ocasazza/tern-openrct2";
      license = lib.licenses.mit;
      mainProgram = "openrct2-setup";
      platforms = lib.platforms.darwin ++ lib.platforms.linux;
    };
  }
  ''
    plugin=$out/share/tern/plugins/openrct2
    mkdir -p "$plugin" $out/bin
    cp ${./plugin.toml} "$plugin/plugin.toml"
    cp ${./park.css} "$plugin/park.css"
    cp ${./game.css} "$plugin/game.css"

    # One command to turn an installer or a folder into a configured game path.
    cat > $out/bin/openrct2-setup <<'SH'
    #!/bin/sh
    set -eu
    target="''${1:-}"
    if [ -z "$target" ]; then
      echo "usage: openrct2-setup <RCT2 installer.exe | folder containing Data/g1.dat>"
      exit 2
    fi
    if [ -f "$target" ]; then
      dest="$HOME/Games/RCT2"
      mkdir -p "$dest"
      echo "Unpacking $target into $dest"
      ${innoextract}/bin/innoextract -s -d "$dest" "$target" >/dev/null
      search="$dest"
    else
      search="$target"
    fi
    found=$(find "$search" -maxdepth 6 -name g1.dat -print 2>/dev/null | head -n 1)
    if [ -z "$found" ]; then
      echo "No g1.dat under $search"
      exit 1
    fi
    case "$found" in
      */RCT\ Classic.app/Contents/Resources/g1.dat | */RCT\ Classic+.app/Contents/Resources/g1.dat)
        dir=$(dirname "$(dirname "$(dirname "$(dirname "$found")")")") ;;
      *)
        dir=$(dirname "$(dirname "$found")") ;;
    esac
    mkdir -p "$HOME/.config/openrct2"
    printf '%s\n' "$dir" > "$HOME/.config/openrct2/game-path"
    echo "RCT2 data: $dir"
    echo "Reload the game page (or restart openrct2-web) to pick it up."
    SH
    chmod +x $out/bin/openrct2-setup

    # Tern resolves these by name, and a single-file store path carries a hash
    # prefix, so each copy names its destination.
    substitute ${./window.luau} "$plugin/window.luau" \
      --replace-fail '@PORT@' '${toString port}'
    substitute ${./host.luau} "$plugin/host.luau" \
      --replace-fail '@OPENRCT2@' '${openrct2}/bin/openrct2' \
      --replace-fail '@PORT@' '${toString port}'
  ''
