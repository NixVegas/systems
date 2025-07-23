{ ... }:
{
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "nvme"
    "ahci"
    "usbhid"
  ];

  networking = {
    hostName = "genos";
    hostId = "d4af12b1";
  };

  nixpkgs.system = "aarch64-linux";
}
