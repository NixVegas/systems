{ ... }:

let
  commonModules = [
    ./modules/boot.nix
    ./modules/fs.nix
    ./modules/misc.nix
    ./modules/net.nix
    ./modules/users.nix
    ./modules/zones.nix
    ./mesh.nix
  ];
in
{
  bigzam = {
    version = "26.05";
    modules = [
      ./devices/bigzam
    ]
    ++ commonModules;
  };

  tatsumaki = {
    version = "26.05";
    modules = [
      ./devices/tatsumaki
    ]
    ++ commonModules;
  };

  genos = {
    version = "26.05";
    modules = [
      ./devices/genos
    ]
    ++ commonModules;
  };

  saitama = {
    version = "26.05";
    modules = [
      ./devices/saitama
    ]
    ++ commonModules;
  };

  ghostgate = {
    version = "26.05";
    modules = [
      ./devices/ghostgate
    ]
    ++ commonModules;
    address = "10.3.7.174";
  };

  vehk = {
    version = "26.05";
    modules = [
      ./devices/vehk
    ]
    ++ commonModules;
    address = "10.3.7.170";
  };

  ayem = {
    version = "26.05";
    modules = [
      ./devices/ayem
    ]
    ++ commonModules;
    address = "10.3.7.168";
  };

  seht = {
    version = "26.05";
    modules = [
      ./devices/seht
    ]
    ++ commonModules;
    # TODO: add deploy `address` once seht is installed (local-only for now).
  };

  adamantia = {
    version = "26.05";
    modules = [
      ./devices/adamantia
    ]
    ++ commonModules;
    address = "adamantia.arena.nixos.lv";
  };

  brass = {
    version = "26.05";
    modules = [
      ./devices/brass
    ]
    ++ commonModules;
    address = "brass.arena.nixos.lv";
  };

  crystal = {
    version = "26.05";
    modules = [
      ./devices/crystal
    ]
    ++ commonModules;
    address = "crystal.arena.nixos.lv";
  };

  dagoth = {
    version = "26.05";
    modules = [
      ./devices/dagoth
    ]
    ++ commonModules;
    address = "dagoth.arena.nixos.lv";
    profile = {
      sshOpts = [ "-t" "-p42070" ];
    };
  };

  citadel = {
    version = "26.05";
    modules = [
      ./devices/citadel
    ]
    ++ commonModules;
  };
}
