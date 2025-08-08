{ pkgs, lib, ... }:
{
  imports = [
    ../../modules/swap.nix
    ../../modules/builder
  ];

  nixpkgs.config.allowUnfree = true;

  programs.obs-studio = {
    enable = true;
    package = pkgs.obs-studio.override {
      cudaSupport = true;
    };
    plugins = with pkgs.obs-studio-plugins; [
      wlrobs
      obs-webkitgtk
    ];
  };

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
    nvidia.open = false;
    graphics.enable = true;
  };

  environment.systemPackages = with pkgs; [ nebula ];

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
      build.interfaces = [
        "trunk1.build"
        "trunk2.build"
        "trunk3.build"
      ];
      noc.interfaces = [ "eno1" ];
    };
    firewall.interfaces = rec {
      build = {
        allowedTCPPorts = [
          22
          # harmonia
          5000
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
          useHydra = true;
          trustHydra = true;
          useRecommendedCacheSettings = true;
        };
      };
    };
  };

  services = {
    # Prefer build (10Gbit)
    xserver.videoDrivers = [ "nvidia" ];
    nebula.networks.arena.settings.preferred_ranges = [ "10.4.1.0/24" ];
    desktopManager.cosmic.enable = true;
    displayManager.cosmic-greeter.enable = true;
    harmonia.enable = true;
  };

  systemd.services."nebula@arena".postStart = ''
    # This route should just go through the router instead of Nebula, since it can route it
    ${lib.getExe' pkgs.iproute2 "ip"} route replace 10.6.6.6 via 10.4.1.1 dev build
  '';

  nixpkgs.system = "x86_64-linux";
}
