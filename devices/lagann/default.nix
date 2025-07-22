{ ... }:
{
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "nvme"
    "ahci"
    "usbhid"
  ];

  networking = {
    hostName = "lagann";
    hostId = "d4af12b1";
  };

  nixpkgs.system = "aarch64-linux";
}
