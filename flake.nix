{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixos-cosmic.url = "github:lilyinstarlight/nixos-cosmic";
  };

  outputs =
    { self, nixpkgs, nixos-cosmic }:
    let
      inherit (nixpkgs) lib;
    in
    {
      nixosConfigurations = lib.genAttrs [ "bigzam" ] (
        hostName:
        nixpkgs.lib.nixosSystem {
          modules = [
            ./devices/${hostName}/default.nix
            ./modules/boot.nix
            ./modules/fs.nix
            ./modules/misc.nix
            ./modules/net.nix
            ./modules/users.nix
            nixos-cosmic.nixosModules.default
          ];
        }
      );
    };
}
