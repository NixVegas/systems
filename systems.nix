{ nixos-cosmic, ... }:

let
  commonModules = [
    ./modules/boot.nix
    ./modules/fs.nix
    ./modules/misc.nix
    ./modules/net.nix
    ./modules/users.nix
    nixos-cosmic.nixosModules.default
  ];
in
{
  bigzam = {
    version = "25.05";
    modules = [
      ./devices/bigzam
    ] ++ commonModules;
  };

  tatsumaki = {
    version = "25.05";
    modules = [
      ./devices/tatsumaki
    ] ++ commonModules;
  };

  genos = {
    version = "25.05";
    modules = [
      ./devices/genos
    ] ++ commonModules;
  };

  saitama = {
    version = "25.05";
    modules = [
      ./devices/saitama
    ] ++ commonModules;
  };
  
  ghostgate = {
    version = "25.05";
    modules = [
      ./devices/ghostgate
    ] ++ commonModules;
  };
}
