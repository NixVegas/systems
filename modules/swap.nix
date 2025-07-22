{ ... }:
{
  swapDevices = [
    {
      device = "/dev/disk/by-partlabel/${hostName}.swap";
      randomEncryption.enable = true;
    }
  ];
}
