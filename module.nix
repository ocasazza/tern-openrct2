self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.tern-openrct2;
  packages = self.packages.${pkgs.stdenv.hostPlatform.system};
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  # Tern reads plugins from its config directory: the app support directory on
  # darwin, the XDG config directory elsewhere.
  ternDir =
    if isDarwin then
      "${config.home.homeDirectory}/Library/Application Support/Tern"
    else
      "${config.xdg.configHome}/tern";
  serve = "${cfg.serverPackage}/bin/openrct2-web";
in
{
  options.programs.tern-openrct2 = {
    enable = lib.mkEnableOption "the OpenRCT2 blocks for Tern and the openrct2-web game server";

    package = lib.mkOption {
      type = lib.types.package;
      default = packages.tern-openrct2.override { inherit (cfg) port; };
      defaultText = lib.literalExpression "tern-openrct2.packages.\${system}.tern-openrct2.override { inherit (cfg) port; }";
      description = "The tern-openrct2 plugin to link into Tern's plugin directory.";
    };

    serverPackage = lib.mkOption {
      type = lib.types.package;
      default = packages.openrct2-web;
      defaultText = lib.literalExpression "tern-openrct2.packages.\${system}.openrct2-web";
      description = "The openrct2-web package: the wasm game, its server and the orct2 CLI.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8737;
      description = "Loopback port of the openrct2-web server; the plugin and the orct2 CLI use the same one.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        home.file."${ternDir}/plugins/openrct2".source = "${cfg.package}/share/tern/plugins/openrct2";

        # openrct2-setup writes ~/.config/openrct2/game-path, which the server reads.
        home.packages = [
          cfg.package
          cfg.serverPackage
        ];

        home.sessionVariables.ORCT2_URL = "http://127.0.0.1:${toString cfg.port}";
      }

      (lib.mkIf isDarwin {
        launchd.agents.openrct2-web = {
          enable = true;
          config = {
            Label = "local.openrct2-web";
            ProgramArguments = [
              serve
              "--port"
              (toString cfg.port)
            ];
            RunAtLoad = true;
            KeepAlive = true;
            StandardOutPath = "${config.home.homeDirectory}/Library/Logs/openrct2-web.log";
            StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/openrct2-web.log";
          };
        };
      })

      (lib.mkIf (!isDarwin) {
        systemd.user.services.openrct2-web = {
          Unit.Description = "OpenRCT2 web game server";
          Service = {
            ExecStart = "${serve} --port ${toString cfg.port}";
            Restart = "always";
          };
          Install.WantedBy = [ "default.target" ];
        };
      })
    ]
  );
}
