{ nixos-hardware, ... }:

let
  commonModules = [
    ./modules/alloy.nix
    ./modules/boot.nix
    ./modules/fs.nix
    ./modules/misc.nix
    ./modules/net.nix
    ./modules/ntp.nix
    ./modules/users.nix
    ./modules/zones.nix
    ./mesh.nix
  ];

  # Personal desktops (dragonborn/vestige/talin). Curated set, NOT commonModules:
  # net.nix mkForce-disables NetworkManager (which these need), and mesh/alloy/
  # zones/ntp are fleet/router-only. desktop.nix carries the shared profile.
  desktopModules = [
    ./modules/alloy.nix
    ./modules/boot.nix
    ./modules/fs.nix
    ./modules/misc.nix
    ./modules/net.nix
    ./modules/users.nix
    ./modules/zones.nix
    ./modules/desktop.nix
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
    address = "ghostgate.dc.nixos.lv";

    # forgejo ssh runs on 22
    profile.sshOpts = [
      "-t"
      "-p42070"
    ];
  };

  citadel = {
    version = "26.05";
    modules = [
      ./devices/citadel
    ]
    ++ commonModules;
    address = "citadel.noc.dc.nixos.lv";
  };

  ayem = {
    version = "26.05";
    modules = [
      ./devices/ayem
    ]
    ++ commonModules;
    address = "ayem.mesh.dc.nixos.lv";
  };

  seht = {
    version = "26.05";
    modules = [
      ./devices/seht
    ]
    ++ commonModules;

    address = "seht.mesh.dc.nixos.lv";
  };

  vehk = {
    version = "26.05";
    modules = [
      ./devices/vehk
    ]
    ++ commonModules;

    address = "vehk.mesh.dc.nixos.lv";
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
  };

  dragonborn = {
    version = "26.05";
    modules = [
      ./devices/dragonborn
      nixos-hardware.nixosModules.framework-16-amd-ai-300-series
    ]
    ++ desktopModules;
    address = "localhost";
  };

  vestige = {
    version = "26.05";
    modules = [
      ./devices/vestige
      nixos-hardware.nixosModules.gpd-pocket-4
    ]
    ++ desktopModules;
  };

  talin = {
    version = "26.05";
    modules = [
      ./devices/talin
      nixos-hardware.nixosModules.lenovo-thinkpad-x1-10th-gen
    ]
    ++ desktopModules;
  };
}
