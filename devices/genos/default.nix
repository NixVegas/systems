{ pkgs, ... }:
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

  environment.systemPackages = with pkgs; [ nebula ];

  networking = {
    useDHCP = false;
    hostName = "genos";
    vlans = {
      "trunk1.build" = {
        id = 2;
        interface = "enP3p3s0f0";
      };
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
      build.interfaces = [ "trunk1.build" "trunk2.build" ];
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
    mesh = {
      nebula = {
        enable = true;
        networkName = "arena";
      };
      cache = {
        client = {
          enable = true;
          useHydra = false;
          useRecommendedCacheSettings = true;
        };
      };
    };
  };

  # Prefer build (10Gbit)
  services.nebula.networks.arena.settings.preferred_ranges = [ "10.4.1.0/24" ];

  nixpkgs.system = "aarch64-linux";
}
