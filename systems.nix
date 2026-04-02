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
    version = "25.11";
    modules = [
      ./devices/bigzam
    ]
    ++ commonModules;
  };

  tatsumaki = {
    version = "25.11";
    modules = [
      ./devices/tatsumaki
    ]
    ++ commonModules;
  };

  genos = {
    version = "25.11";
    modules = [
      ./devices/genos
    ]
    ++ commonModules;
  };

  saitama = {
    version = "25.11";
    modules = [
      ./devices/saitama
    ]
    ++ commonModules;
  };

  ghostgate = {
    version = "25.11";
    modules = [
      ./devices/ghostgate
    ]
    ++ commonModules;
  };

  vivec = {
    version = "25.11";
    modules = [
      ./devices/vivec
    ]
    ++ commonModules;
  };

  adamantia = {
    version = "25.11";
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
    version = "25.11";
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
    version = "25.11";
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
