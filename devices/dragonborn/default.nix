{ ... }:
{
  imports = [
    ../../modules/desktop.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "dragonborn";
  nixVegas.zfs = {
    enc = true;
    etc = true;
    rootHome = true;
  };
}
