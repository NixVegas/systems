{ ... }:
{
  imports = [
    ../../modules/desktop.nix
    ../../modules/swap.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "talin";
  nixVegas.zfs = {
    enc = true;
    etc = true;
    rootHome = true;
  };
}
