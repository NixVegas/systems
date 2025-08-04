{ ... }:

let
  commonModules = [
    ./modules/boot.nix
    ./modules/fs.nix
    ./modules/misc.nix
    ./modules/net.nix
    ./modules/users.nix
    ./mesh.nix
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

  vivec = {
    version = "25.05";
    modules = [
      ./devices/vivec
    ] ++ commonModules;
  };

  adamantia = {
    version = "25.05";
    modules = [
      ./devices/adamantia
    ] ++ commonModules;
    address = "adamantia.arena.nixos.lv";
    profile = {
      sshUser = "numinit";
    };
  };
}
