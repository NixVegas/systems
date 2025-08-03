{ lib, pkgs, config, ... }:

let
  hydraDomain = "hydra.saitama.build.dc.nixos.lv";
  cacheDomain = "saitama.noc.dc.nixos.lv";
in
{
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "nvme"
    "ahci"
    "usbhid"
  ];

  fileSystems."/var/lib/ncps" = {
    device = "onepunch/local/cache";
    fsType = "zfs";
  };

  fileSystems."/nix" = lib.mkForce {
    device = "onepunch/local/nix";
    fsType = "zfs";
  };

  hardware = {
    nvidia.open = true;
    graphics.enable = true;
  };

  environment.systemPackages = with pkgs; [ nebula ];

  services = {
    desktopManager.cosmic.enable = true;
    displayManager.cosmic-greeter.enable = true;
    hydra = {
      enable = true;
      hydraURL = "http://${hydraDomain}";
      port = 3000;
      notificationSender = "nobody@${hydraDomain}";
      useSubstitutes = true;
    };
    openssh.openFirewall = false;
    nginx = {
      enable = true;
      clientMaxBodySize = "2000M";
      recommendedTlsSettings = true;
      recommendedOptimisation = true;
      recommendedGzipSettings = true;
      recommendedProxySettings = true;
      virtualHosts = {
        "${hydraDomain}" = {
          locations."/" = {
            proxyPass = "http://localhost:${builtins.toString config.services.hydra.port}";
            proxyWebsockets = true;
          };
        };
      };
    };
  };

  nix.buildMachines = [
    {
      hostName = "tatsumaki.build.dc.nixos.lv";
      system = "aarch64-linux";
      supportedFeatures = [
        "kvm"
        "nixos-test"
        "big-parallel"
        "benchmark"
      ];
      maxJobs = 12;
      publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUJNeXFScWRzUlZneUJIUkZLWmV4ZlFZbnpOM2l1VWM1ZEtmVkt0RkVFdGoK";
      sshKey = "/etc/ssh/id_tatsumaki_builder";
      sshUser = "builder";
    }
    {
      hostName = "genos.build.dc.nixos.lv";
      system = "aarch64-linux";
      supportedFeatures = [
        "kvm"
        "nixos-test"
        "big-parallel"
        "benchmark"
      ];
      maxJobs = 12;
      publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSVB0bnVpSUZGVFdNYlFPVFgxa3BaS01HWU5aNjdQQ1VSNkxxZG96WWVUTGUK";
      sshKey = "/etc/ssh/id_genos_builder";
      sshUser = "builder";
    }
  ];

  networking = {
    hostName = "saitama";
    useDHCP = false;
    vlans = {
      "trunk1.build" = {
        id = 2;
        interface = "enP3p3s0f0";
      };
      "trunk2.build" = {
        id = 2;
        interface = "enP3p3s0f1";
      };
      "trunk1.wan" = {
        id = 3;
        interface = "enP3p3s0f0";
      };
    };
    interfaces = {
      build.useDHCP = true;
      noc.useDHCP = true;
      wan.useDHCP = true;
      usb0.useDHCP = true;
    };
    dhcpcd.extraConfig = ''
      # deprioritize noc under build
      interface build
      metric 1000
      interface noc
      metric 1001
      interface wan
      metric 1500
      interface usb0
      metric 2000
    '';
    bridges = {
      build.interfaces = [ "trunk1.build" "trunk2.build" ];
      wan.interfaces = [ "trunk1.wan" ];
      noc.interfaces = [ "enP3p6s0" ];
    };
    firewall.interfaces = {
      build = {
        allowedTCPPorts = [
          22
          80
          # harmonia
          5000
        ];
        allowedUDPPorts = [
          22
          80
        ];
      };
      noc = {
        allowedTCPPorts = [
          22
          80
        ];
        allowedUDPPorts = [
          22
          80
        ];
      };
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
        };
      };
    };
  };

  services.harmonia = {
    enable = true;
  };

  nixpkgs.system = "aarch64-linux";
}
