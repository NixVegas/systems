{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }:
  let
    inherit (nixpkgs) lib;
  in {
    nixosConfigurations = lib.genAttrs [ "bigzam" ] (hostName: nixpkgs.lib.nixosSystem {
      modules = [
        ./devices/${hostName}/default.nix
        ./modules/fs.nix
        ./modules/users.nix
      ];
    });
  };
}
