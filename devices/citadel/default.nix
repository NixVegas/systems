{
  pkgs,
  lib,
  config,
  ...
}:

let
  nocInterface1 = "enp200s0";
  nocInterface2 = "enp201s0";

  trunkInterface1 = "enp10s0f0np0";
  trunkInterface2 = "enp10s0f1np1";

  erlib = import ../../modules/event-router/lib.nix { inherit lib pkgs; };

  baseDomain = "nixos.lv";
  domain = "ctf.${baseDomain}";

  # Build machines.
  build = erlib.mkNet {
    id = 2;
    base = "10.4.1";
    subdomain = "build";
    inherit domain;
  };

  # CTF machines
  ctf = erlib.mkNet {
    id = 3;
    base = "10.4.2";
    subdomain = "ctf";
    inherit domain;
  };

  # Remote-build clients: hosts allowed to offload to citadel. Their SSH *host*
  # public keys (from the mesh plan) go straight into the build user's
  # authorized_keys — the clients authenticate with /etc/ssh/ssh_host_ed25519_key
  # (see modules/citadel-builder.nix). seht has no hostKey in the plan yet, so
  # the filter drops it until it's provisioned.
  planHosts = config.networking.mesh.plan.hosts;
  buildClients = [
    "ghostgate"
    "ayem"
    "vehk"
  ];
  buildClientKeys = map (n: planHosts.${n}.ssh.hostKey) (
    lib.filter (n: (planHosts.${n}.ssh.hostKey or null) != null) buildClients
  );
in
{
  imports = [
    ../../modules/hydra-builder.nix
  ];

  # citadel is the shared remote builder (the "huge box"). nix.sshServe sets up
  # the nix-ssh user restricted to the nix protocol only: protocol = "ssh-ng"
  # force-commands `nix-daemon --stdio` (no shell, no forwarding — see the
  # `Match User nix-ssh` block it emits), write = true + trusted = true let
  # offloaded builds write to the store. Auth is the clients' SSH host keys from
  # the mesh plan (no new secrets); clients connect as nix-ssh (citadel-builder).
  nix.sshServe = {
    enable = true;
    protocol = "ssh-ng";
    write = true;
    trusted = true;
    keys = buildClientKeys;
  };

  nixVegas.alloy.nebulaCollector = false;

  boot = {
    initrd.availableKernelModules = [
      "nvme"
      "xhci_pci"
      "ahci"
      "usbhid"
      "uas"
      "usb_storage"
      "sd_mod"
    ];
    kernelModules = [ "kvm-amd" ];
  };

  networking = {
    useDHCP = false;
    hostName = "citadel";

    bonds = {
      trunk = {
        interfaces = [
          trunkInterface1
          trunkInterface2
        ];
        # LACP over the 2x10G backbone to ghostgate. Both ends must match.
        driverOptions = {
          mode = "802.3ad";
          lacp_rate = "fast";
          xmit_hash_policy = "layer3+4";
          miimon = "100";
        };
      };
    };

    vlans = {
      "trunk.build" = {
        inherit (build) id;
        interface = "trunk";
      };

      "trunk.ctf" = {
        inherit (ctf) id;
        interface = "trunk";
      };
    };

    bridges = {
      noc.interfaces = [
        nocInterface1
        nocInterface2
      ];
      build.interfaces = [ "trunk.build" ];
      ctf.interfaces = [ "trunk.ctf" ];
    };

    # Explicit per-bridge DHCP (all served by ghostgate). Only ctf carries the
    # default route, so CTF traffic stays symmetric (in and out the same
    # backbone); noc and build get addresses but must not install competing
    # default routes (the multi-default asymmetric-routing footgun).
    interfaces = {
      noc.useDHCP = true;
      build = {
        useDHCP = true;
        # Pinned so ghostgate's build DHCP reservation is stable (-> 10.4.1.2 /
        # citadel.build.dc.nixos.lv, the remote-build target) regardless of
        # which bond member's MAC the LACP bond adopts.
        macAddress = "02:ca:fe:c7:f0:01";
      };
      ctf = {
        useDHCP = true;
        # Pinned so ghostgate's DHCP reservation is stable regardless of which
        # bond member's MAC the LACP bond happens to adopt.
        macAddress = "02:ca:fe:c7:f0:02";
      };
    };

    dhcpcd.extraConfig = ''
      interface noc
      nogateway
      interface build
      nogateway
    '';

    # ghostgate's cache endpoint, pinned to its ctf-side address so cache
    # traffic rides the 20G LACP backbone regardless of DNS (the knot answer
    # is ghostgate's Nebula address). TLS stays valid: the cert matches the
    # SNI name, not the IP. The substituter itself comes from the mesh plan
    # (cnl cache client set in mesh.nix); harmonia pulls through from upstream
    # on a miss, so citadel needs no separate mirror endpoint.
    hosts.${ctf.address} = [ "cache.nixos.lv" ];

    # Consume the cnl cache set (-> https://cache.nixos.lv:443, see mesh.nix).
    # useHydra = false: don't let the module inject cache.nixos.org?priority=10
    # ahead of the local cache; the nixpkgs default cache.nixos.org/ (40)
    # remains as the last-resort fallback.
    mesh.cache.client = {
      enable = true;
      useHydra = false;
      trustHydra = true;
      useRecommendedCacheSettings = true;
    };
  };

  hardware.tenstorrent = {
    enable = true;
    meshName = "p150_x4";
  };

  services = {
    nginx = {
      enable = true;

      upstreams = {
        "ctf-app" = {
          servers = {
            "localhost:4000" = {
              weight = 100;
              fail_timeout = "30s";
              max_fails = 3;
            };
          };
        };
      };

      virtualHosts = {
        # Front-facing: terminate TLS + serve the CTF app. Onsite-only — attendees
        # resolve nixc.tf straight here via split-horizon DNS; brass refuses public
        # :443 for it and only forwards the ACME HTTP-01 challenge so the cert
        # renews. PHX_HOST is nixc.tf, so Origin matches.
        "nixc.tf" = {
          http2 = true;
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://ctf-app";
            proxyWebsockets = true;
          };
        };

        # www + canonical + legacy -> redirect to the front.
        "www.nixc.tf" = {
          enableACME = true;
          forceSSL = true;
          globalRedirect = "nixc.tf";
        };
        "ctf.nixos.lv" = {
          enableACME = true;
          forceSSL = true;
          globalRedirect = "nixc.tf";
        };
        "ctf.nix.vegas" = {
          enableACME = true;
          forceSSL = true;
          globalRedirect = "nixc.tf";
        };
      };
    };

    llama-cpp = {
      enable = true;
      package = pkgs.llama-cpp-metalium;
      extraFlags = [
        "-hf"
        "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF:Q4_K_M"
        "-nkvo"
      ];
      openFirewall = false;
    };
    ctf-server = {
      enable = true;
      openFirewall = false;
      openVmFirewall = true; # open the challenge-VM SSH range (below)
      # Front-facing domain the app presents (Phoenix PHX_HOST): nixc.tf. The
      # nginx vhost + cert stay ctf.nixos.lv (canonical) — brass proxies with
      # Host: ctf.nixos.lv, so citadel needn't be on the nixc.tf cert.
      host = "nixc.tf";
      vmSshHost = "nixc.tf";
      # 1024 per-challenge-VM SSH forwarding ports, anchored on id Software's
      # Quake (IANA 26000 = "quake"). On the way up it also squats FlexLM license
      # servers (27000-27009), Steam (27015), and MongoDB (27017-19) — a CTF host
      # will run none of them in a million years, and none bind these ports here.
      vmPortRange = {
        from = 26000;
        to = 27023;
      };
    };
    postgresql.ensureDatabases = [
      "ctf-server"
    ];
  };

  systemd.services.llama-cpp = {
    serviceConfig = {
      MemoryDenyWriteExecute = lib.mkForce false;
      ProcSubset = lib.mkForce "all";
    };

    environment = {
      inherit (config.environment.variables) TT_MESH_GRAPH_DESC_PATH GGML_METALIUM_MESH_SHAPE;
    };
  };

  environment.variables.GGML_METALIUM_MESH_SHAPE = "2x2";

  # The CTF is reached by attendees over the arena -> ctf path and by brass's
  # public front, so open the web ports (the challenge-VM SSH range is opened by
  # openVmFirewall above).
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  # Required by the nginx `enableACME` on ctf.nixos.lv (matches the other hosts).
  security.acme = {
    acceptTerms = true;
    defaults.email = "noc@nix.vegas";
  };

  nixpkgs.system = "x86_64-linux";
}
