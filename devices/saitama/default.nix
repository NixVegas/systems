{ lib, config, ... }:

let
  inherit (config.networking) hostName;

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

  networking = {
    hostName = "saitama";
  };

  services = {
    ncps = {
      enable = true;
      server.addr = "localhost:8501";
      cache = {
        inherit hostName;
      };
      upstream = {
        caches = [ "https://cache.nixos.org" ];
        publicKeys = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
      };
    };
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
        "${cacheDomain}" = {
          default = true;
          locations."/" = {
            proxyPass = "http://${config.services.ncps.server.addr}";
            proxyWebsockets = true;
          };
        };
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
  };

  nixpkgs.system = "aarch64-linux";
}
