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
    in
    {
      nixosModules.default = import ./modules/nixos/clash-of-clans.nix;
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
