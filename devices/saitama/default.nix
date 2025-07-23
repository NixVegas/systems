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

  services = {
    hydra = {
      enable = true;
      hydraURL = "http://saitama.local";
      port = 80;
      notificationSender = "nobody@saitama.local";
    };
    openssh.openFirewall = false;
  };

  networking.firewall.interfaces.enP3p3s0f0 = {
    allowedTCPPorts = [ 22 80 ];
    allowedUDPPorts = [ 22 80 ];
  };

  nixpkgs.system = "aarch64-linux";
}
