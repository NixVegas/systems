{ pkgs, ... }:
{
  imports = [
    ../../modules/builder
    ../../modules/arm-perf.nix
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "nvme"
    "ahci"
    "usbhid"
  ];

  services.openssh.openFirewall = false;

  environment.systemPackages = with pkgs; [ nebula ];

  networking = {
    useDHCP = false;
    hostName = "genos";
    interfaces = {
      build.useDHCP = true;
      noc.useDHCP = true;
      usb0.useDHCP = true;
    };
    dhcpcd.extraConfig = ''
      # deprioritize noc under build
      interface build
      metric 1000
      interface noc
      metric 1001
      interface usb0
      metric 2000
    '';
    bridges = {
      build.interfaces = [
        "enP3p3s0f0"
        "enP3p3s0f1"
      ];
      noc.interfaces = [ "enP3p5s0" ];
    };
    firewall.interfaces = rec {
      build = {
        allowedTCPPorts = [
          22
        ];
      };
      arena = build;
      noc = build;
    };
  };

  nixpkgs.system = "aarch64-linux";
}
