{ ... }:
{
  imports = [
    ../../modules/swap.nix
    ../../modules/builder
  ];

  boot = {
    initrd.availableKernelModules = [
      "xhci_pci"
      "nvme"
      "ahci"
      "thunderbolt"
      "usbhid"
    ];
    kernelModules = [ "kvm-amd" ];
  };

  hardware = {
    nvidia.open = true;
    graphics.enable = true;
  };

  services.openssh.openFirewall = false;

  networking = {
    useDHCP = false;
    hostName = "bigzam";
    vlans = {
      "trunk1.build" = {
        id = 2;
        interface = "enp65s0f0";
      };
      "trunk2.build" = {
        id = 2;
        interface = "enp65s0f1";
      };
      "trunk3.build" = {
        id = 2;
        interface = "enp74s0";
      };
    };
    interfaces = {
      build.useDHCP = true;
      noc.useDHCP = true;
    };
    dhcpcd.extraConfig = ''
      # deprioritize noc under build
      interface build
      metric 1000
      interface noc
      metric 1001
    '';
    bridges = {
      build.interfaces = [ "trunk1.build" "trunk2.build" "trunk3.build" ];
      noc.interfaces = [ "eno1" ];
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

  services = {
    desktopManager.cosmic.enable = true;
    displayManager.cosmic-greeter.enable = true;
  };

  nixpkgs.system = "x86_64-linux";
}
