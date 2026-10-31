{
  description = "udiskie-style automounting for phones, built on gio/gvfs";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      # Pure bash: nothing here is architecture specific, but gvfs is, and so
      # is systemd — Linux only.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # ───────────────────────────────────────────────────────────────────────
      # The package.  Written as a callPackage-style function so that the
      # overlay below can feed it the *host's* nixpkgs rather than ours.
      # ───────────────────────────────────────────────────────────────────────
      mkPhoneAutomounter =
        {
          lib,
          stdenvNoCC,
          makeWrapper,
          bash,
          coreutils,
          gawk,
          glib,
          gnugrep,
          util-linux,
          libnotify,
          # notify-send is optional: without it the script falls back to gdbus,
          # which ships with glib.  Set to false for a slightly smaller closure.
          withLibnotify ? true,
        }:
        let
          # Everything automounter.sh shells out to.  gvfs itself is
          # deliberately not here: the fuse daemon is a system/session service,
          # not something a CLI wrapper should pull into its PATH.
          runtimeDeps = [
            coreutils # timeout, readlink, unlink, ln, sleep, test, id, install
            gawk # the gio mount --list parser
            glib # gio, gdbus
            gnugrep # gvfs_root_is_mounted
            util-linux # flock, for the single-instance lock
          ]
          ++ lib.optional withLibnotify libnotify;
        in
        stdenvNoCC.mkDerivation (finalAttrs: {
          pname = "phone-automounter";
          version = "1.0.0"; # keep in sync with APP_VERSION in automounter.sh

          src = ./.;

          strictDeps = true;
          nativeBuildInputs = [ makeWrapper ];
          buildInputs = [ bash ];

          dontConfigure = true;
          dontBuild = true;

          # tests.sh builds its own sandbox under $TMPDIR and stubs out
          # everything that would talk to real hardware, so it runs fine inside
          # the Nix build sandbox.
          doCheck = true;
          checkPhase = ''
            runHook preCheck
            ${bash}/bin/bash tests.sh
            runHook postCheck
          '';

          installPhase = ''
            runHook preInstall

            install -Dm755 automounter.sh "$out/bin/phone-automounter"
            patchShebangs "$out/bin/phone-automounter"
            wrapProgram "$out/bin/phone-automounter" \
              --prefix PATH : ${lib.makeBinPath runtimeDeps}

            install -Dm644 README.md -t "$out/share/doc/${finalAttrs.pname}"
            install -Dm644 LICENSE -t "$out/share/licenses/${finalAttrs.pname}"

            runHook postInstall
          '';

          meta = {
            description = "udiskie-style automounting for phones, built on gio/gvfs";
            longDescription = ''
              Watches gio/gvfs for phone volumes (MTP, PTP/gphoto2 and AFC), mounts them
              as soon as the device actually shares storage, and publishes each one as a
              symlink in /media.  The links disappear again when the phone is unplugged,
              locked, or switched back to charging-only mode.
            '';
            homepage = "https://github.com/pillowbanana/phone-automounter";
            license = lib.licenses.unlicense;
            mainProgram = "phone-automounter";
            platforms = lib.platforms.linux;
          };
        });

      # ───────────────────────────────────────────────────────────────────────
      # The NixOS module.  A *user* service on purpose: gvfs mounts live inside
      # a user's session ($XDG_RUNTIME_DIR/gvfs) and are not visible to root,
      # so a system-wide daemon would publish links nobody could follow.
      # ───────────────────────────────────────────────────────────────────────
      nixosModule =
        {
          config,
          pkgs,
          lib,
          ...
        }:
        let
          cfg = config.services.phone-automounter;
        in
        {
          options.services.phone-automounter = {
            enable = lib.mkEnableOption "the phone-automounter user service";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
              defaultText = lib.literalExpression "phone-automounter.packages.\${system}.default";
              description = "Package providing the phone-automounter binary.";
            };

            mediaDir = lib.mkOption {
              type = lib.types.path;
              default = "/media";
              description = "Where the phone symlinks are published.";
            };

            manageMediaDir = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Create {option}`services.phone-automounter.mediaDir` as
                `root:users` with mode `0775`, so the user service can write to
                it.  Turn this off if you manage that directory yourself.
              '';
            };

            schemes = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [
                "mtp"
                "gphoto2"
                "afc"
              ];
              description = "gvfs URI schemes treated as a phone.";
            };

            resyncInterval = lib.mkOption {
              type = lib.types.ints.unsigned;
              default = 30;
              description = "Watchdog reconcile interval in seconds; `0` means events only.";
            };

            notify = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Send desktop notifications on mount and unmount.";
            };

            remountAlways = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Mount a phone straight back even after it was explicitly ejected
                from a file manager.
              '';
            };

            extraArgs = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "--debug" ];
              description = "Extra command line arguments.";
            };

            environment = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              example = {
                PENDING_WINDOW = "300";
              };
              description = ''
                Extra environment variables for the service — handy for the
                tunables that have no command line flag.
              '';
            };
          };

          config = lib.mkIf cfg.enable {
            environment.systemPackages = [ cfg.package ];

            # The whole thing is a front-end to gvfs, and specifically to its
            # fuse daemon: without gvfsd-fuse a phone has no filesystem path.
            services.gvfs.enable = true;

            systemd.tmpfiles.rules = lib.mkIf cfg.manageMediaDir [
              "d ${cfg.mediaDir} 0775 root users -"
            ];

            systemd.user.services.phone-automounter = {
              description = "udiskie-style automounting for phones (gio/gvfs)";
              documentation = [ "https://github.com/pillowbanana/phone-automounter" ];
              wantedBy = [ "default.target" ];
              after = [ "dbus.socket" ];

              # gio mount --monitor talks to gvfs over the session bus, and a
              # user unit started outside a login session has no address for it.
              environment = {
                DBUS_SESSION_BUS_ADDRESS = "unix:path=%t/bus";
              }
              // cfg.environment;

              serviceConfig = {
                Type = "simple";
                ExecStart = lib.escapeShellArgs (
                  [
                    "${cfg.package}/bin/phone-automounter"
                    "--media-dir"
                    cfg.mediaDir
                    "--schemes"
                    (lib.concatStringsSep " " cfg.schemes)
                    "--resync"
                    (toString cfg.resyncInterval)
                  ]
                  ++ lib.optional (!cfg.notify) "--no-notify"
                  ++ lib.optional cfg.remountAlways "--remount-always"
                  ++ cfg.extraArgs
                );
                Restart = "on-failure";
                RestartSec = 5;
              };
            };
          };
        };
    in
    {
      # Adds pkgs.phone-automounter.
      overlays.default = final: _prev: {
        phone-automounter = final.callPackage mkPhoneAutomounter { };
      };

      packages = forAllSystems (pkgs: rec {
        phone-automounter = pkgs.callPackage mkPhoneAutomounter { };
        default = phone-automounter;
      });

      nixosModules.default = nixosModule;
      nixosModules.phone-automounter = nixosModule;

      apps = forAllSystems (pkgs: rec {
        phone-automounter = {
          type = "app";
          program = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.default;
          meta.description = "Run the phone-automounter daemon";
        };
        default = phone-automounter;
      });

      # nix flake check: the package (which runs tests.sh) plus shellcheck.
      checks = forAllSystems (pkgs: {
        package = self.packages.${pkgs.stdenv.hostPlatform.system}.default;

        shellcheck =
          pkgs.runCommand "phone-automounter-shellcheck"
            {
              nativeBuildInputs = [ pkgs.shellcheck ];
            }
            ''
              cd ${./.}

              # Warnings and errors fail the build; style and info notes do
              # not.  The two exclusions are false positives:
              #
              #   SC1007  `C_RESET= C_DIM= …` deliberately clears the colour
              #           variables to the empty string, all on one line.
              #   SC2034  the parser fills in every field of
              #           `gio mount --list -i` (VOL_TYPE, VOL_DEV); the test
              #           suite asserts on them even where the daemon itself
              #           never reads them back.
              shellcheck --severity=warning -e SC1007,SC2034 automounter.sh tests.sh

              touch "$out"
            '';
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            bashInteractive
            shellcheck
            shfmt
            glib # gio, gdbus
            gvfs # gvfsd-fuse, the mtp/gphoto2/afc backends
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
