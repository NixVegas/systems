{ ... }:
{
  imports = [
    ../../modules/builder
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "nvme"
    "ahci"
    "usbhid"
  ];

  services.openssh.openFirewall = false;

  networking = {
    useDHCP = false;
    hostName = "tatsumaki";
    vlans = {
      "trunk2.build" = {
        id = 2;
        interface = "enP3p3s0f1";
      };
    };
    interfaces = {
      build.useDHCP = true;
      noc.useDHCP = true;
      usb0.useDHCP = true;
    };
    bridges = {
      build.interfaces = [ "enP3p3s0f0" "trunk2.build" ];
      noc.interfaces = [ "enP3p5s0" ];
    };
    firewall.interfaces = {
      build = {
        allowedTCPPorts = [
          22
        ];
        allowedUDPPorts = [
          22
        ];
      };
      noc = {
        allowedTCPPorts = [
          22
        ];
        allowedUDPPorts = [
          22
        ];
      };
    };
  };

  nixpkgs.system = "aarch64-linux";
}
