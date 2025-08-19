{
  lib,
  pkgs,
  config,
  ...
}:

let
  hydraDomain = "hydra.saitama.build.dc.nixos.lv";
  cacheDomain = "saitama.noc.dc.nixos.lv";

  supportedFeatures = [
    "kvm"
    "nixos-test"
    "big-parallel"
    "benchmark"
  ];
  sshUser = "builder";
in
{
  imports = [
    ../../modules/arm-perf.nix
  ];

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

  nix.buildMachines =
    let
      mkMachine =
        {
          host,
          system,
          publicHostKey,
          maxJobs,
        }:
        {
          hostName = "${host}.local";
          inherit
            supportedFeatures
            sshUser
            system
            publicHostKey
            maxJobs
            ;
          sshKey = "/etc/ssh/id_${host}_${sshUser}";
        };
    in
    [
      (mkMachine {
        host = "tatsumaki";
        system = "aarch64-linux";
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUJNeXFScWRzUlZneUJIUkZLWmV4ZlFZbnpOM2l1VWM1ZEtmVkt0RkVFdGoK";
        maxJobs = 12;
      })
      (mkMachine {
        host = "genos";
        system = "aarch64-linux";
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSVB0bnVpSUZGVFdNYlFPVFgxa3BaS01HWU5aNjdQQ1VSNkxxZG96WWVUTGUK";
        maxJobs = 12;
      })
      (mkMachine {
        host = "bigzam";
        system = "x86_64-linux";
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUlNcG1ZemNGaW5ISUdUUi9uR1M4MHZoVHgxWFFOcS8ycWVQeXNydGlrUkggcm9zc0BzYWl0YW1hCg==";
        maxJobs = 16;
      })
    ];

  networking = {
    hostName = "saitama";
    useDHCP = false;
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
      build.interfaces = [
        "enP3p3s0f0"
        "enP3p3s0f1"
      ];
      wan.interfaces = [ "enP3p3s0f0" ];
      noc.interfaces = [ "enP3p6s0" ];
    };
    firewall.interfaces = rec {
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
      arena = build;
      noc = build;
    };
  };

  services.harmonia = {
    enable = true;
  };

  nixpkgs.system = "aarch64-linux";
}
