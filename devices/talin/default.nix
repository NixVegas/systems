{ ... }:
{
  imports = [
    ../../modules/desktop.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "talin";
  nixVegas.zfs = {
    enc = true;
    etc = true;
    rootHome = true;
  };
}
