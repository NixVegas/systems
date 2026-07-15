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
  ghostgate = {
    version = "26.05";
    modules = [
      ./devices/ghostgate
    ]
    ++ commonModules;
    address = "ghostgate";
  };

  citadel = {
    version = "26.05";
    modules = [
      ./devices/citadel
    ]
    ++ commonModules;
    address = "citadel";
  };

  ayem = {
    version = "26.05";
    modules = [
      ./devices/ayem
    ]
    ++ commonModules;
    address = "ayem";
  };

  seht = {
    version = "26.05";
    modules = [
      ./devices/seht
    ]
    ++ commonModules;
    address = "seht";
  };

  vehk = {
    version = "26.05";
    modules = [
      ./devices/vehk
    ]
    ++ commonModules;
    address = "vehk";
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
      # 22 is gitea
      sshOpts = [
        "-t"
        "-p42070"
      ];
    };
  };
}
