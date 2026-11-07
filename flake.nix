{
  description = "Declarative Clash of Clans on NixOS using Waydroid";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # The APK is stored in Git LFS, which Nix does not understand: a GitHub
      # flake source contains only the 134-byte LFS pointer. Fetch the real
      # blob from GitHub's LFS media endpoint instead. `self.rev` pins it to
      # the exact flake revision. For local `path:` flakes the working-tree
      # file is used directly.
      apkHash = "sha256-bcywwKSU+cXgovVD38Iwn5idwhXD8j11jYf6nHc/f5k=";

      clashOfClansModule =
        { pkgs, ... }@args:
        import ./modules/nixos/clash-of-clans.nix (
          args
          // {
            clashOfClansDefaultApk =
              if self ? rev then
                pkgs.fetchurl {
                  url = "https://media.githubusercontent.com/media/RafaelMuijsert/cocnix/${self.rev}/apk/clash-of-clans.apk";
                  hash = apkHash;
                }
              else
                ./apk/clash-of-clans.apk;
          }
        );
    in
    {
      nixosModules.default = clashOfClansModule;
      nixosModules.clash-of-clans = self.nixosModules.default;

      checks = forAllSystems (
        system:
        let
          inherit (nixpkgs) lib;
          pkgs = nixpkgs.legacyPackages.${system};
          evaluated = lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.default
              {
                programs.clash-of-clans.enable = true;
                system.stateVersion = "25.05";
              }
            ];
          };
          # Building the launcher forces the APK signer verification and
          # shellcheck for both the launcher and the desktop entry.
          launcher = lib.findFirst (
            p: (p.name or "") == "clash-of-clans"
          ) null evaluated.config.environment.systemPackages;
        in
        {
          default = launcher;
        }
      );
    };
}
