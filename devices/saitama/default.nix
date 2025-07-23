{ ... }:
{
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "nvme"
    "ahci"
    "usbhid"
  ];

  networking = {
    hostName = "saitama";
    hostId = "6e2e597d";
  };

  services.hydra.enable = true;

  nixpkgs.system = "aarch64-linux";
}
