{ config, ... }:
let
  inherit (config.networking) hostName;
  domainName = "${hostName}.${config.services.avahi.domainName}";
in
{
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "nvme"
    "ahci"
    "usbhid"
  ];

  fileSystems."/var/lib/ncps" = {
    device = "${hostName}/local/cache";
    fsType = "zfs";
  };

  networking = {
    hostName = "saitama";
    hostId = "6e2e597d";
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
      hydraURL = "http://cache.${domainName}.local";
      port = 3000;
      notificationSender = "nobody@${domainName}.local";
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
        "${domainName}" = {
          default = true;
          locations."/" = {
            proxyPass = "http://${config.services.ncps.server.addr}";
            proxyWebsockets = true;
          };
        };
        "hydra.${domainName}" = {
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
      hostName = "tatsumaki.local";
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
      hostName = "genos.local";
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

  networking.firewall.interfaces.enP3p3s0f0 = {
    allowedTCPPorts = [
      22
      config.services.hydra.port
      80
    ];
    allowedUDPPorts = [
      22
      config.services.hydra.port
      80
    ];
  };

  nixpkgs.system = "aarch64-linux";
}
