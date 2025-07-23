{ ... }:
{
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "nvme"
    "ahci"
    "usbhid"
  ];

  networking = {
    hostName = "tatsumaki";
    hostId = "7144d96e";
  };

  nixpkgs.system = "aarch64-linux";
}
