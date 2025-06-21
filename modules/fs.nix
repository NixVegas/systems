{ config }:
let
  inherit (config.networking) hostName;
in
{
  services = {
    zfs = {
      trim.enable = true;
      autoScrub = {
        enable = true;
        pool = [ hostName ];
      };
    };
  };

  fileSystems = {
    "/" = {
      device = "${hostName}/system/root";
      fsType = "zfs";
      options = [ "zfsutil" ];
    };
    "/boot" = {
      device = "/dev/disk/by-partlabel/${hostName}.boot";
      fsType = "vfat";
    };
    "/nix" = {
      device = "${hostName}/local/nix";
      fsType = "zfs";
      options = [ "zfsutil" ];
    };
    "/home" = {
      device = "${hostName}/user/home";
      fsType = "zfs";
      options = [ "zfsutil" ];
    };
    "/var" = {
      device = "${hostName}/system/var";
      fsType = "zfs";
      options = [ "zfsutil" ];
    };
  };

  swapDevices = [
    {
      label = "${hostName}.swap";
      randomEncryption.enable = true;
    }
  ];
}
