{ ... }:
{
  imports = [
    ../../modules/desktop.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "vestige";
  nixVegas.zfs = {
    enc = true;
    etc = true;
    rootHome = true;
  };

  # Vertical panel.
  boot.loader.limine.extraConfig = "interface_rotation: 90\n";
}
