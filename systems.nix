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
  };

  vivec = {
    version = "26.05";
    modules = [
      ./devices/vivec
    ]
    ++ commonModules;
  };

  adamantia = {
    version = "26.05";
    modules = [
      ./devices/adamantia
    ]
    ++ commonModules;
    address = "adamantia.arena.nixos.lv";
    profile = {
      sshUser = "numinit";
    };
  };

  crystal = {
    version = "26.05";
    modules = [
      ./devices/crystal
    ]
    ++ commonModules;
    address = "crystal.arena.nixos.lv";
    profile = {
      sshUser = "numinit";
    };
  };

  dagoth = {
    version = "26.05";
    modules = [
      ./devices/dagoth
    ]
    ++ commonModules;
    address = "dagoth.arena.nixos.lv";
    profile = {
      sshUser = "numinit";
      sshOpts = [ "-t" "-p42070" ];
    };
  };
}
