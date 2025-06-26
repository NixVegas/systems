{ config, ... }:
let
  inherit (config.networking) hostName;
in
{
  services = {
    zfs = {
      trim.enable = true;
      autoScrub = {
        enable = true;
        pools = [ hostName ];
      };
    };
  };

  fileSystems = {
    "/" = {
      device = "${hostName}/system/root";
      fsType = "zfs";
    };
    "/boot" = {
      device = "/dev/disk/by-partlabel/${hostName}.boot";
      fsType = "vfat";
      options = [
        "fmask=0022"
        "dmask=0022"
      ];
    };
    "/nix" = {
      device = "${hostName}/local/nix";
      fsType = "zfs";
    };
    "/home" = {
      device = "${hostName}/user/home";
      fsType = "zfs";
    };
    "/var" = {
      device = "${hostName}/system/var";
      fsType = "zfs";
    };
  };

  swapDevices = [
    {
      device = "/dev/disk/by-partlabel/${hostName}.swap";
      randomEncryption.enable = true;
    }
  ];
}
