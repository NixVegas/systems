{ config, ... }:
let
  inherit (config.networking) hostName;
in
{
  swapDevices = [
    {
      device = "/dev/disk/by-partlabel/${hostName}.swap";
      randomEncryption.enable = true;
    }
  ];
}
