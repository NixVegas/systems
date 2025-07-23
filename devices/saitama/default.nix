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

  services.hydra = {
    enable = true;
    hydraURL = "http://saitama.local";
    port = 80;
    notificationSender = "nobody@saitama.local";
  };

  nixpkgs.system = "aarch64-linux";
}
