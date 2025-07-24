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
      port = 3000;
      notificationSender = "nobody@saitama.local";
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
      virtualHosts."hydra.saitama.local".locations."/" = {
        proxyPass = "http://localhost:3000";
        proxyWebsockets = true;
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
    }
  ];

  networking.firewall.interfaces.enP3p3s0f0 = {
    allowedTCPPorts = [
      22
      80
    ];
    allowedUDPPorts = [
      22
      80
    ];
  };

  nixpkgs.system = "aarch64-linux";
}
