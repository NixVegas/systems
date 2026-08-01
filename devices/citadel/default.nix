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

    # Reserve one 1GB hugepage per Tenstorrent p150 (four in the mesh) for the
    # UMD sysmem buffer. Without these tt-metal falls back to 4K pages and warns
    # "Sysmem using regular pages", which slows host-device DMA and, for a mesh,
    # the per-layer fabric collectives. The pages must be reserved at boot
    # because 1GB pages need contiguous physical memory.
    kernelParams = [
      "hugepagesz=1G"
      "hugepages=4"
    ];
  };

  # tt-metal's UMD maps its 1GB sysmem buffers from a hugetlbfs mounted at
  # /dev/hugepages-1G (the default /dev/hugepages is 2MB). mode=1777 lets the
  # unprivileged serving user create its hugepage files.
  systemd.mounts = [
    {
      description = "Tenstorrent 1G hugepages";
      what = "hugetlbfs";
      where = "/dev/hugepages-1G";
      type = "hugetlbfs";
      options = "pagesize=1G,mode=1777";
      wantedBy = [ "multi-user.target" ];
    }
  ];

  networking = {
    useDHCP = false;
    hostName = "citadel";

    # Bond bifurcated (ghostgate split its 2x10G): citadel now takes a single 10G
    # link on its higher SFP (trunkInterface2) carrying the build+ctf VLANs.
    # Cable ghostgate's higher SFP (enp2s0f1np1) to this port; the lower SFP
    # (trunkInterface1) is now free.
    vlans = {
      "trunk.build" = {
        inherit (build) id;
        interface = trunkInterface2;
      };

      "trunk.ctf" = {
        inherit (ctf) id;
        interface = trunkInterface2;
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

    # OpenAI serving on the four-card mesh, replacing the single-stream llama-cpp
    # service. Serves Qwen3.6-27B (a reasoning model, gated-delta-net attention)
    # through tt-metal's in-tree qwen36 model, tensor-parallel across the four
    # p150s. The served id is advertised as the Llama name the console's frontend
    # expects. The qwen36 model is registered with the vLLM plugin via an
    # EXTRA_MODELS_DIR bundle, and needs the l1_small_size / trace_region_size
    # device params for its GDN path on a mesh.
    vllm = {
      enable = true;
      model = "Qwen/Qwen3.6-27B";
      hfModel = "Qwen/Qwen3.6-27B";
      # Advertise the real model id. The console's frontend must send the same id
      # (set via services.tt-studio.frontend below), or vLLM 404s the request.
      servedModelName = "Qwen/Qwen3.6-27B";
      meshDevice = "P150x4";
      maxNumSeqs = 1;
      reasoningParser = "qwen3";
      additionalConfig = {
        sample_on_device_mode = "decode_only";
        l1_small_size = 24576;
        trace_region_size = 1073741824;
      };
      extraModelsDir = pkgs.writeTextDir "qwen36/vllm_metadata.json" (
        builtins.toJSON {
          arch = "Qwen3_5ForConditionalGeneration";
          main_class = "models.demos.blackhole.qwen36.tt.qwen36_vllm:Qwen36ForCausalLM";
          hf_weights = "Qwen/Qwen3.6-27B";
        }
      );
    };
  };

  # The native tt-studio web console, chatting through the vLLM server above. The
  # frontend is rebuilt to send the same model id the vLLM server advertises.
  services.tt-studio = {
    enable = true;
    cloudChatUrl = "http://127.0.0.1:8000/v1/chat/completions";
    frontend = pkgs.tt-studio-frontend.override {
      servedModelName = "Qwen/Qwen3.6-27B";
    };
  };

  services = {
    nginx = {
      enable = true;

      upstreams = {
        "nixctf" = {
          servers = {
            "127.0.0.1:4000" = {
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
            proxyPass = "http://nixctf";
            proxyWebsockets = true;
          };
        };

        # The tt-studio console (the "clanker box", nixie). Routed exactly like
        # nixc.tf: onsite attendees resolve nixie.nixos.lv straight here via
        # split-horizon DNS, and brass forwards ONLY the ACME HTTP-01 challenge
        # (its onsiteBackends maps nixie.nixos.lv -> citadel's ctf address), so
        # this vhost mints and renews its own Let's Encrypt cert. Proxies to the
        # tt-studio module's own nginx on :3000, which serves the frontend and
        # fans the /*-api/ paths to the Django backend. Buffering is off and the
        # read timeout is long so the chat token stream is not held back.
        "nixie.${baseDomain}" = {
          http2 = true;
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString config.services.tt-studio.port}";
            proxyWebsockets = true;
            extraConfig = ''
              proxy_buffering off;
              proxy_read_timeout 1200s;
            '';
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

      # Allow everything out ctf
      egressAllowSubnets = [ "0.0.0.0/0" ];
      egressInterface = "ctf";
    };
    postgresql.ensureDatabases = [
      "ctf-server"
    ];
  };

  # The CTF is reached by attendees over the arena -> ctf path and by brass's
  # public front, so open the web ports (the challenge-VM SSH range is opened by
  # openVmFirewall above).
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  services.hydra-queue-builder-dev.maxJobs = 1;

  # Required by the nginx `enableACME` on ctf.nixos.lv (matches the other hosts).
  security.acme = {
    acceptTerms = true;
    defaults.email = "noc@nix.vegas";
  };

  nixpkgs.system = "x86_64-linux";
}
