{
  description = "OpenRCT2 in Tern: a WebAssembly game pane, a live park block, and an agent API";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        openrct2-web = pkgs.callPackage ./openrct2-web/package.nix { };
        tern-openrct2 = pkgs.callPackage ./plugin/package.nix { };
        default = tern-openrct2;
      });

      homeManagerModules.default = import ./module.nix self;

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
