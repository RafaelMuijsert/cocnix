{
  config,
  lib,
  pkgs,
  # Provided by the flake wrapper. It is a fetchurl derivation when the flake is
  # fetched from GitHub (which stores the APK through Git LFS, unsupported by
  # Nix), and the real working-tree file for local path flakes.
  clashOfClansDefaultApk ? ../../apk/clash-of-clans.apk,
  ...
}:

let
  cfg = config.programs.clash-of-clans;

  # Waydroid is enabled below, so this option is always defined.
  waydroid = config.virtualisation.waydroid.package;

  appId = "com.supercell.clashofclans";
  playStoreId = "com.android.vending";

  # Signing certificate of the official Supercell release:
  #   CN=Visa Forsten, OU=Supercell, O=Supercell, L=Helsinki, ST=Uusimaa, C=FI
  defaultTrustedSignerSha256 = "9ea146d935c0be2e4b576396e6a5e1de6dcb69a71af4e417b0a5b8fe8e0d4d9c";

  defaultApk = clashOfClansDefaultApk;

  # Verify the APK signer at build time. The resulting path is a symlink to the
  # original APK, so the 900MB+ file is not duplicated in the store.
  verifiedApk =
    if cfg.apk == null then
      null
    else
      pkgs.runCommandLocal "clash-of-clans-verified.apk" {
        nativeBuildInputs = [
          pkgs.apksigner
          pkgs.gnugrep
          pkgs.gnused
        ];
      } ''
        export HOME="$TMPDIR"
        export _JAVA_OPTIONS="-Djava.io.tmpdir=$TMPDIR"

        apksigner verify --print-certs "${cfg.apk}" > certs.txt

        signers="$(grep -c '^Signer #[0-9]* certificate SHA-256 digest:' certs.txt || true)"
        if [ "$signers" -ne 1 ]; then
          echo "clash-of-clans: expected exactly one APK signer, found $signers" >&2
          cat certs.txt >&2
          exit 1
        fi

        actual="$(sed -n 's/^Signer #[0-9]* certificate SHA-256 digest: //p' certs.txt)"
        if [ "$actual" != "${cfg.trustedSignerSha256}" ]; then
          echo "clash-of-clans: refusing to install an APK with an untrusted signer" >&2
          echo "  expected SHA-256: ${cfg.trustedSignerSha256}" >&2
          echo "  actual SHA-256:   $actual" >&2
          exit 1
        fi

        ln -s "${cfg.apk}" "$out"
      '';

  # Install the APK lazily on first launch. Waydroid's app installer needs a
  # running user session, so this cannot be done from a system service at boot.
  installBlock = lib.optionalString (verifiedApk != null) ''
    if ! waydroid app list 2>/dev/null | grep -q "$app_id"; then
      echo "Installing Clash of Clans..."
      waydroid app install "${verifiedApk}"
    fi
  '';

  launcher = pkgs.writeShellApplication {
    name = "clash-of-clans";
    runtimeInputs = [
      waydroid
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.util-linux
    ];
    text = ''
      app_id="${appId}"

      if [ -z "''${WAYLAND_DISPLAY:-}" ]; then
        echo "clash-of-clans: Waydroid requires a Wayland session." >&2
        exit 1
      fi

      session_running() {
        waydroid status 2>/dev/null | grep -q 'Session:.*RUNNING'
      }

      if ! session_running; then
        setsid waydroid session start >/dev/null 2>&1 &
        for _ in $(seq 1 60); do
          if session_running; then
            break
          fi
          sleep 1
        done
      fi

      if ! session_running; then
        echo "clash-of-clans: failed to start the Waydroid session." >&2
        echo "Check 'waydroid status' and that your compositor is Wayland." >&2
        exit 1
      fi

      ${installBlock}

      if waydroid app list 2>/dev/null | grep -q "$app_id"; then
        exec waydroid app launch "$app_id"
      fi

      echo "Clash of Clans is not installed."
      echo "Opening the Play Store. Install the game there, then run 'clash-of-clans' again."
      exec waydroid app launch "${playStoreId}"
    '';
  };

  desktopItem = pkgs.makeDesktopItem {
    name = "clash-of-clans";
    desktopName = "Clash of Clans";
    genericName = "Mobile strategy game";
    exec = "clash-of-clans";
    icon = "applications-games";
    categories = [ "Game" ];
    terminal = false;
  };

  launcherPackage = pkgs.symlinkJoin {
    name = "clash-of-clans";
    paths = [
      launcher
      desktopItem
    ];
  };
in
{
  options.programs.clash-of-clans = {
    enable = lib.mkEnableOption "Clash of Clans through Waydroid";

    androidVariant = lib.mkOption {
      type = lib.types.enum [
        "GAPPS"
        "VANILLA"
      ];
      default = "GAPPS";
      description = ''
        Android image variant used by the automatic Waydroid initialization.
        `GAPPS` includes the Play Store and is required when no {option}`apk`
        is provided.
      '';
    };

    autoInitialize = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Automatically run `waydroid init` on first boot when
        `/var/lib/waydroid` has not been initialized yet.

        Disable this if you prefer to initialize Waydroid manually
        (for example to pass extra arguments).
      '';
    };

    apk = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.path lib.types.package);
      default = defaultApk;
      defaultText = lib.literalMD "the APK bundled with this flake";
      example = lib.literalExpression "./ClashOfClans.apk";
      description = ''
        APK (or derivation producing one) to install into Waydroid. It is
        verified against {option}`trustedSignerSha256` at build time, then
        installed automatically on first launch.

        Set this to `null` to skip the APK and install the game through the
        Play Store instead.
      '';
    };

    trustedSignerSha256 = lib.mkOption {
      type = lib.types.strMatching "[0-9a-fA-F]{64}";
      default = defaultTrustedSignerSha256;
      description = ''
        SHA-256 fingerprint of the certificate that must have signed
        {option}`apk`. Defaults to Supercell's official APK signing
        certificate.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.apk != null || cfg.androidVariant == "GAPPS";
        message = ''
          programs.clash-of-clans: without an `apk`, the Play Store is used to
          install the game, so `androidVariant` must be "GAPPS".
        '';
      }
    ];

    virtualisation.waydroid.enable = true;

    systemd.services.waydroid-init = lib.mkIf cfg.autoInitialize {
      description = "Initialize the Waydroid Android image";
      wantedBy = [ "multi-user.target" ];
      # The image must exist before the container starts.
      before = [ "waydroid-container.service" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      unitConfig.ConditionPathExists = "!/var/lib/waydroid/waydroid.cfg";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${waydroid}/bin/waydroid init -s ${cfg.androidVariant}";
      };
    };

    environment.systemPackages = [ launcherPackage ];
  };
}
