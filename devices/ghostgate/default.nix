# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{
  config,
  pkgs,
  lib,
  modulesPath,
  meshos,
  ...
}:

let
  hostName = "ghostgate";
  baseDomain = "nixos.lv";
  domain = "dc.${baseDomain}";

  onboardWifi = "wlp7s0";
  wwan1 = onboardWifi;
  internalM2Wifi = "wlp0s13f0u1";
  internalUSBWifi = "wlp0s20f0u4";

  wanInterface = "enp3s0";
  wanInterfaces = [ wanInterface ];
  nocInterfaces = [
    "enp4s0"
    "enp5s0"
  ];
  arenaInterface = "enp6s0";
  arenaInterfaces = [ arenaInterface ];
  trunkInterface1 = "enp2s0f0np0";
  trunkInterface2 = "enp2s0f1np1";

  # Shared event-router helpers (kea/knot/kresd builders).
  erlib = import ../../modules/event-router/lib.nix { inherit lib pkgs; };

  # NOC management network.
  noc = erlib.mkNet {
    id = 1;
    base = "10.4.0";
    subdomain = "noc";
    inherit domain;
  };

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

  # Attendee network.
  arena = erlib.mkArena {
    self = "ghostgate";
    inherit domain;
  };

  # Nebula lighthouse/relay UDP ports (the cloud nodes' entry ports). Mesh
  # clients' traffic to these bypasses ghostgate's encrypted arena routing, so a
  # 2420 falling back through ghostgate can bootstrap its own Nebula in the
  # clear — the underlay can't be tunneled inside ghostgate's Nebula (circular).
  lighthousePorts = lib.unique (
    map (n: config.networking.mesh.plan.hosts.${n}.nebula.port) [
      "adamantia"
      "brass"
      "crystal"
      "dagoth"
    ]
  );

  # Public IPv4 underlay endpoints of the cloud Nebula nodes (same hosts as
  # lighthousePorts). ghostgate's full-tunnel egress (below) must NEVER route
  # traffic to these into the Nebula table, or it would tunnel the underlay
  # through itself. Derived from the plan so it can't drift.
  nebulaUnderlayV4 = lib.unique (
    lib.concatMap (
      n:
      builtins.filter (
        a: lib.strings.hasInfix "." a
      ) config.networking.mesh.plan.hosts.${n}.nebula.entryAddresses
    ) [ "adamantia" "brass" "crystal" "dagoth" ]
  );

  # The Nebula service user's uid, pinned below. The full-tunnel rules match
  # Nebula's own underlay by owner, but must do so numerically: the build-time
  # `nft --check` runs in a sandbox with no user database, so it cannot resolve
  # the name. See erlib.nebulaServiceUser for the full write-up of this gotcha.
  nebulaServiceUser = erlib.nebulaServiceUser "arena";
  nebulaUserUid = config.users.users.${nebulaServiceUser}.uid;

in
{
  imports = [
    ../../modules/event-router/common.nix
    ./hardware-configuration.nix
  ];

  boot.kernelParams = [
    "console=ttyS1,115200n8"
  ];
  boot.kernel.sysctl = {
    "net.ipv6.conf.all.accept_ra" = 0;
    "net.ipv6.conf.all.autoconf" = 0;
    "net.ipv6.conf.all.use_tempaddr" = 0;

    "net.ipv6.conf.${wanInterface}.accept_ra" = 2;
    "net.ipv6.conf.${wanInterface}.autoconf" = 1;
  };
  boot.extraModprobeConfig = ''
    # Feed the L2ARC at 256 MB/s until it's full
    options zfs l2arc_noprefetch=0 l2arc_write_boost=${toString (256 * 1024 * 1024)}
  '';

  networking.mesh = {
    nebula = {
      enable = true;
      networkName = "arena";
      tpm2Key = true;
    };
    wifi = {
      enable = true;
      countryCode = "US";
      dedicatedWifiDevices = [ internalM2Wifi ];
      useForFallbackInternetAccess = false;
      sharedInternetDevice = "nebula.arena";
    };
    cache = {
      # ncps used to serve here and fought nginx for :443; nginx now owns the
      # cache endpoints (cache.nixos.lv -> harmonia, upstream.cache.nixos.lv ->
      # the study mirror). The mesh.nix plan entry stays: the 2420s' cnl set
      # reads it to find https://cache.nixos.lv:443.
      server = {
        enable = false;
      };
      client = {
        enable = true;
        useHydra = false;
        trustHydra = true;
        useRecommendedCacheSettings = true;
      };
    };
  };

  services.nebula.networks.arena = {
    tun.device = lib.mkForce "nebula.arena";
    settings = {
      tun = {
        unsafe_routes = [
          # Default route for arena traffic sent into Nebula: exit via the
          # fleet gateway (brass).
          (erlib.arenaDefaultRoute { planHosts = config.networking.mesh.plan.hosts; })
        ]
        # Full-mesh inter-arena routing: reach every other router's arena LAN
        # over Nebula (cert-authorized). Kernel routes live in the postStart
        # below (table arena), so install = false.
        ++ erlib.arenaUnsafeRoutes {
          self = "ghostgate";
          planHosts = config.networking.mesh.plan.hosts;
        };
      };

      # Prefer build and ctf (10Gbit)
      preferred_ranges = [
        build.subnet
        ctf.subnet
      ];

      # Constrain Nebula underlay address discovery. ghostgate is a multi-homed
      # router; by default Nebula advertises every local interface to the
      # lighthouses and will try peers on all of theirs. The overlay (10.6) and
      # the arena LANs (10.7/10.8) are routed *over* Nebula, so a handshake
      # aimed at such an address routes back into the tun and never completes;
      # stale private ranges just waste handshake attempts. Exclude those; keep
      # the WiFi mesh (10.5, a real low-latency underlay), the 10Gbit build net
      # (10.4.1) and the real uplink / any public address.
      lighthouse =
        let
          routed = [
            config.networking.mesh.plan.constants.nebula.subnet # 10.6/16 overlay
            "10.3.0.0/16" # deploy/mgmt LAN — collides with ghostgate's own roamed WAN
            "192.168.0.0/16" # stale roamed private nets
          ]
          ++ erlib.arenaAggregates; # 10.7/16, 10.8/16 (routed over Nebula)
          deny = builtins.listToAttrs (map (c: lib.nameValuePair c false) routed);
        in
        {
          # Also drop ghostgate's mgmt net from advertisements (peers can't
          # reach it); the arena LAN is already covered by the routed aggregates.
          local_allow_list = deny // {
            "${noc.subnet}" = false;
            "0.0.0.0/0" = true;
          };
          # Roaming: ghostgate is off the WiFi mesh, so the 2420s' mesh (10.5)
          # addresses are dead to it — trying them just wastes handshake attempts
          # and delays the relay fallback. Deny the mesh for *remote* peers so
          # ghostgate goes straight to the relay (which rides the lighthouses'
          # public addresses, unaffected by this).
          remote_allow_list = deny // {
            "${config.networking.mesh.plan.constants.wifi.subnet}" = false; # 10.5/16 mesh
            "0.0.0.0/0" = true;
          };
        };
    };
  };

  # Pin the Nebula service user's uid so the full-tunnel nftables rules can
  # match Nebula's own underlay traffic by a fixed number (see nebulaUserUid).
  # This one was what it autogenerated as, we don't feel like changing it
  users.users.${nebulaServiceUser}.uid = 989;

  systemd.services."nebula@arena".postStart = ''
    ${erlib.arenaPostStartPreamble {
      ip = lib.getExe' pkgs.iproute2 "ip";
      sleep = lib.getExe' pkgs.coreutils "sleep";
    }}
    _rule_replace from ${arena.subnet} lookup arena
    _rule_replace from ${build.subnet} lookup arena
    _rule_replace from ${ctf.subnet} lookup arena
    _rule_replace from ${noc.subnet} lookup arena
    _rule_replace from ${config.networking.mesh.plan.constants.wifi.subnet} lookup arena
    _rule_replace from ${config.networking.mesh.plan.constants.nebula.subnet} lookup arena

    # Carve-out: a 2420 falling back through ghostgate needs a *clear* path to
    # the Nebula lighthouses to bootstrap its own Nebula (the underlay can't be
    # tunneled inside ghostgate's). Route mesh-sourced traffic to the lighthouse
    # UDP ports via the main table (real WAN) at high priority, ahead of the
    # `from <wifi.subnet> lookup arena` rule above. All other mesh traffic still
    # egresses encrypted over Nebula, so attendee data is unaffected.
    for _lhport in ${lib.concatMapStringsSep " " toString lighthousePorts}; do
      _ip rule del from ${config.networking.mesh.plan.constants.wifi.subnet} ipproto udp dport "$_lhport" lookup main priority 100 2>/dev/null
      _ip rule add from ${config.networking.mesh.plan.constants.wifi.subnet} ipproto udp dport "$_lhport" lookup main priority 100
    done

    _ip route replace ${arena.subnet} dev arena table arena
    _ip route replace ${build.subnet} dev build table arena
    _ip route replace ${ctf.subnet} dev ctf table arena
    _ip route replace ${noc.subnet} dev noc table arena
    _ip route replace ${config.networking.mesh.plan.constants.wifi.subnet} dev mesh2 table arena

    # Reach the VP2420 arena LANs over Nebula (full mesh) — in table arena for
    # LAN clients, and in the main table so ghostgate itself can reach them.
    ${erlib.arenaTableRoutes { }}
    ${erlib.arenaTableRoutes { table = "main"; }}
    _ip route replace default dev nebula.arena table arena

    # Full-tunnel egress: ghostgate's own marked traffic (fwmark 0x1, set by the
    # nebula_egress nftables chain) uses table arena, so it exits over Nebula via
    # brass. Priority 300: after the lighthouse main-table carve-out (100), well
    # ahead of main (32766). Marked packets never include the underlay itself
    # (the chain returns on skuid arena + the underlay IPs), so no loop.
    _ip rule del fwmark 0x1 lookup arena priority 300 2>/dev/null
    _ip rule add fwmark 0x1 lookup arena priority 300
  '';

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    wget
    curl
    tmux
    psmisc
    man-pages
    speedtest-cli
    zip
    unzip
    iw

    hdparm
    sdparm
    smartmontools
    gptfdisk
    dosfstools
    usbutils

    iproute2
    traceroute
    unbound
    bind
    bridge-utils
    ethtool
    tcpdump
    conntrack-tools
    sanoid
    pv
    mbuffer
    lzop
    nebula

    ipxe
    tftp-hpa
    wol

    great-value-hydra.cachePkgs
    great-value-hydra.cacheUnstablePkgs
    great-value-hydra.cachePrevPkgs
  ];

  networking = {
    inherit hostName;

    nameservers = [ "127.0.0.1" ];

    iproute2 = {
      enable = true;
      rttablesExtraConfig = ''
        200 arena
      '';
    };

    dhcpcd.extraConfig = ''
      interface wan1
      metric 1000
      interface ${wwan1}
      metric 1001
      interface wwan2
      metric 1002
    '';

    nat.enable = lib.mkForce false;
    firewall = {
      enable = true;
      allowedTCPPorts = [
        22
        53
        69
        80
        443
        5355
      ];
      allowedUDPPorts = [
        53
        67
        68
        69
        123
        5355
      ];
    };

    useDHCP = false;

    bonds = {
      trunk = {
        interfaces = [
          trunkInterface1
          trunkInterface2
        ];
        # LACP over the 2x10G backbone to citadel. Both ends must match.
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

    interfaces = {
      # DHCP on the WAN interface.
      wan1.useDHCP = true;
      ${wwan1}.useDHCP = true;
      wwan2.useDHCP = true;

      noc = {
        ipv4.addresses = [
          {
            inherit (noc) address;
            prefixLength = noc.prefix;
          }
        ];
      };

      build = {
        ipv4.addresses = [
          {
            inherit (build) address;
            prefixLength = build.prefix;
          }
        ];
      };

      ctf = {
        ipv4.addresses = [
          {
            inherit (ctf) address;
            prefixLength = ctf.prefix;
          }
        ];
      };

      arena = {
        ipv4.addresses = [
          {
            inherit (arena) address;
            prefixLength = arena.prefix;
          }
        ];
      };
    };

    bridges = {
      wan1.interfaces = wanInterfaces;

      noc.interfaces = nocInterfaces;

      build.interfaces = [
        "trunk.build"
      ];

      ctf.interfaces = [
        "trunk.ctf"
      ];

      arena.interfaces = arenaInterfaces;
      "arena.wlan".interfaces = [ ];
    };

    nftables = {
      enable = true;
      flushRuleset = true;
      tables = {
        filter = {
          family = "inet";
          content = ''
            chain output {
              type filter hook output priority 100; policy accept;

              # IPv6 leak guard: the Nebula overlay is IPv4-only, so ghostgate
              # has no tunnelled path for IPv6. Reject its own NEW global v6
              # egress out the physical WAN so nothing bypasses the tunnel over
              # v6 (a rejected v6 makes clients fall straight back to the
              # tunnelled v4). Exempt Nebula's own v6 underlay (user `arena`),
              # established replies (incl. inbound management sessions), and
              # loopback/link-local/ULA/multicast so ND, DHCPv6, RA survive.
              meta nfproto ipv6 meta skuid ${toString nebulaUserUid} accept
              meta nfproto ipv6 ct state { established, related } accept
              meta nfproto ipv6 ip6 daddr { ::1, fe80::/10, fc00::/7, ff00::/8 } accept
              oifname { "wan1", "${wwan1}", "wwan2" } meta nfproto ipv6 ct state new counter reject with icmpv6 type admin-prohibited
            }

            # Full-tunnel egress for ghostgate's OWN traffic: default-deny
            # toward the event WAN. Everything ghostgate originates is marked
            # for the `arena` routing table (default dev nebula.arena -> brass),
            # so it exits from brass's VPS and nothing leaks onto the DEF CON
            # WAN. `type route` so the kernel re-routes after the mark is set.
            # LAN/forwarded traffic is already Nebula-only (forward chain), so
            # this only governs host-originated packets.
            chain nebula_egress {
              type route hook output priority mangle; policy accept;

              # Replies to inbound connections must leave the way they arrived
              # (remote SSH deploys land on wan1) — redirecting them would go
              # asymmetric and drop the session. This keeps management alive.
              ct direction reply return

              # Local delivery, loopback, broadcast/multicast: main table.
              fib daddr type { local, broadcast, multicast, anycast } return

              # Loop guard: never send the Nebula underlay endpoints into the
              # tunnel, whoever originates the packet.
              ip daddr { ${lib.concatStringsSep ", " nebulaUnderlayV4} } return

              # Nebula's own underlay (owned by the nebula-arena service user),
              # including hole-punched peers, stays on the real WAN. Matched by
              # numeric uid so the sandboxed build-time nft check can resolve it.
              meta skuid ${toString nebulaUserUid} return

              # Everything else ghostgate originates over IPv4 -> Nebula.
              meta nfproto ipv4 meta mark set 0x1
            }

            chain input {
              type filter hook input priority filter; policy drop;

              # Allow trusted networks to access the router
              iifname {
                "lo",
                "noc",
                "build",
                "ctf",
                "arena",
                "nebula.arena",
                "mesh2"
              } counter accept

              # Allow returning traffic from WAN, arena, and the mesh
              iifname {"wan1", "${wwan1}", "wwan2", "nebula.arena", "mesh2"} ct state { established, related } counter accept

              # Allow SSH in over the wired WAN uplink so ghostgate can be
              # deployed remotely. The WWAN uplinks stay closed (below).
              iifname "wan1" tcp dport { ${
                lib.concatMapStringsSep ", " toString config.services.openssh.ports
              } } counter accept

              # Allow some ICMP by default
              ip protocol icmp icmp type { destination-unreachable, echo-request, time-exceeded, parameter-problem } accept
              ip6 nexthdr icmpv6 icmpv6 type { destination-unreachable, echo-request, time-exceeded, parameter-problem, packet-too-big } accept

              # Drop everything else from WAN
              iifname "wan1" drop
              iifname "${wwan1}" drop
              iifname "wwan2" drop
            }

            chain forward {
              type filter hook forward priority filter; policy drop;

              # Route between arena LANs over Nebula (cert-authorized, no NAT).
              iifname "arena" oifname "nebula.arena" counter accept comment "arena -> nebula (inter-arena)"
              iifname "nebula.arena" oifname "arena" counter accept comment "nebula -> arena (inter-arena)"

              # Attendees reach the CTF backbone with real source IPs (no NAT):
              # ghostgate's own arena LAN directly, and remote arenas over Nebula.
              # citadel's default gateway is ghostgate, so replies route back the
              # same way.
              iifname "arena" oifname "ctf" counter accept comment "arena -> ctf"
              iifname "nebula.arena" oifname "ctf" counter accept comment "nebula -> ctf (remote arena)"
              iifname "ctf" oifname { "arena", "nebula.arena" } counter accept comment "ctf -> arena (replies)"

              # Allow only localhost WAN access
              iifname {
                "lo"
              } oifname {
                "wan1",
                "${wwan1}",
                "wwan2",
              } counter accept comment "Allow trusted LAN to WAN"

              iifname { "lo", "arena", "build", "ctf", "mesh2", "noc" } oifname { "nebula.arena" } counter accept comment "Allow Arena networks to get out"

              # Let mesh clients (2420s falling back through ghostgate) reach the
              # Nebula lighthouses via the clear WAN to bootstrap their own
              # Nebula. Scoped to the lighthouse UDP ports only — all other mesh
              # traffic stays encrypted over Nebula (matching the carve-out in
              # the nebula@arena postStart).
              iifname "mesh2" oifname "wan1" udp dport { ${
                lib.concatMapStringsSep ", " toString lighthousePorts
              } } counter accept comment "mesh -> lighthouse (clear bootstrap)"
              iifname "wan1" oifname "mesh2" ct state established,related counter accept comment "lighthouse reply -> mesh"

              # Let NOC get to build and ctf.
              iifname { "noc" } oifname { "build", "ctf" } counter accept
              iifname { "build", "ctf" } oifname { "noc" } ct state established,related counter accept

              # Allow established WAN to return
              iifname {
                "wan1",
                "${wwan1}",
                "wwan2"
              } oifname {
                "lo"
              } ct state established,related counter accept comment "Allow established back to LANs"

              iifname {
                "nebula.arena"
              } oifname {
                "lo",
                "arena",
                "build",
                "ctf",
                "mesh2",
                "noc"
              } ct state established,related counter accept comment "Allow established back to LANs"
            }
          '';
        };

        nat = {
          family = "ip";
          content = ''
            chain prerouting {
              type nat hook prerouting priority filter; policy accept;

              # Redirect DNS, TFTP, and NTP queries to us
              iifname {"noc", "build", "ctf", "arena", "mesh2"} udp dport {53, 123} counter redirect
              iifname {"noc", "build", "ctf", "arena", "mesh2"} tcp dport {53} counter redirect
            }

            # Setup NAT masquerading on the wan interface
            chain postrouting {
              type nat hook postrouting priority filter; policy accept;
              # Note: no "arena" or "ctf" here — traffic delivered to the arena
              # LANs and the CTF backbone keeps its real source IP (so the CTF
              # sees real attendee IPs; reachable both ways).
              oifname {
                "build",
                "noc",
                "wan1",
                "${wwan1}",
                "wwan2",
                "mesh2"
              } masquerade
              # NOC (management) reaching the CTF backbone: citadel is multi-homed
              # onto noc, so a real-source noc packet arriving on its ctf interface
              # fails citadel's strict reverse-path filter (its route back to noc is
              # the noc interface, not ctf). Masquerade noc->ctf so citadel replies
              # to us symmetrically. Arena traffic keeps its real source (attendee
              # IPs) because this only matches the noc subnet.
              oifname "ctf" ip saddr ${noc.subnet} masquerade
              # NOC is a management network with no presence in Nebula, so hosts
              # reached over the overlay (the builders at 10.6.9.x, other arenas)
              # can't route back to it. Masquerade its Nebula egress so they reply
              # to us; this must come before the real-source rule below.
              oifname "nebula.arena" ip saddr ${noc.subnet} masquerade
              # Masquerade only genuine internet egress over Nebula. Traffic to
              # other arenas OR to Nebula hosts (e.g. a router's own Nebula IP,
              # as when pinging from the box) keeps its real source so replies
              # match conntrack and stay reachable both ways.
              oifname "nebula.arena" ip daddr != { ${
                lib.concatStringsSep ", " (
                  erlib.arenaCidrs ++ [ config.networking.mesh.plan.constants.nebula.subnet ]
                )
              } } masquerade
            }
          '';
        };

        tftp = {
          family = "ip";
          content = ''
            ct helper helper-tftp {
                type "tftp" protocol udp
            }

            chain sethelper {
                type filter hook forward priority 0; policy accept;
                udp dport 69 ct helper set "helper-tftp"
            }
          '';
        };

        gremlinmode = {
          name = "gremlinmode";
          family = "ip";
          content = ''
            chain raw {
              type filter hook postrouting priority 0; policy accept;
              ip dscp cs1  ip dscp set cs0  return
              ip dscp af22 ip dscp set af21 return
              ip dscp af23 ip dscp set af21 return
              ip dscp af32 ip dscp set af31 return
              ip dscp af33 ip dscp set af31 return
              ip dscp af42 ip dscp set af41 return
              ip dscp af43 ip dscp set af41 return
            };
          '';
        };
      };
    };
  };

  security.pkcs11 = {
    enable = true;
    pcsc = {
      enable = true;
      users = [ "numinit" ];
    };
    tpm2.enable = true;
    keypairs = {
      nixos-lv-core = {
        enable = true;
        inherit (pkgs.yubico-piv-tool) pkcs11Module;
        token = "YubiKey PIV #6460026";
        id = 13; # Retired Key Management #8a
        debug = true;
        keyOptions = {
          algorithm = "EC";
          type = "secp256r1";
          usage = [ "sign" ];
          soPinFile = "/etc/nixpkcs/yubikeys/6460026/so.pin";
          loginAsUser = false;
          softFail = true;
        };
        certOptions = {
          digest = "SHA256";
          subject = "C=US/ST=California/L=Carlsbad/O=nixos.lv/OU=Arena/CN=Core";
          validityDays = 365 * 3;
          extensions = [
            "v3_ca"
            "keyUsage=critical,nonRepudiation,keyCertSign,digitalSignature,cRLSign"
            "crlDistributionPoints=URI:http://keymaster.nixos.lv/ca.crl"
          ];
          pinFile = "/etc/nixpkcs/yubikeys/6460026/user.pin";
          writeTo = "/etc/nixpkcs/yubikeys/6460026/nixos-lv-core-ca.crt";
        };
      };
      nixos-lv-aux = {
        enable = true;
        inherit (pkgs.yubico-piv-tool) pkcs11Module;
        token = "YubiKey PIV #6460026";
        id = 14; # Retired Key Management #8b
        debug = true;
        keyOptions = {
          algorithm = "EC";
          type = "secp256r1";
          usage = [ "sign" ];
          soPinFile = "/etc/nixpkcs/yubikeys/6460026/so.pin";
          loginAsUser = false;
          softFail = true;
        };
        certOptions = {
          digest = "SHA256";
          subject = "C=US/ST=California/L=Carlsbad/O=nixos.lv/OU=Arena/CN=Aux";
          validityDays = 365 * 3;
          extensions = [
            "v3_ca"
            "keyUsage=critical,nonRepudiation,keyCertSign,digitalSignature,cRLSign"
            "crlDistributionPoints=URI:http://keymaster.nixos.lv/ca.crl"
          ];
          pinFile = "/etc/nixpkcs/yubikeys/6460026/user.pin";
          writeTo = "/etc/nixpkcs/yubikeys/6460026/nixos-lv-aux-ca.crt";
        };
      };
    };
  };

  networking.wireless = {
    enable = true;
    interfaces = [ onboardWifi ];
    fallbackToWPA2 = false;
    allowAuxiliaryImperativeNetworks = true;
    userControlled = true;
    secretsFile = "/etc/meshos/dc34/wireless.env";
    networks."DefCon" = {
      priority = 5;
      authProtocols = lib.singleton "WPA-EAP";
      auth = ''
        proto=RSN
        pairwise=CCMP
        auth_alg=OPEN
        eap=PEAP
        identity="Nix"
        password=ext:dc_wifi_pass
        phase1="peaplabel=0"
        phase2="auth=MSCHAPV2"
        ca_cert="${../hellenic-academic-root-ca.crt}"
        subject_match="CN=wifireg.defcon.org"
        altsubject_match="DNS:wifi.defcon.org;DNS:wifireg.defcon.org"
      '';
    };
  };

  services.hostapd = {
    enable = true;
    /*
      radios.${internalM2Wifi} = {
        countryCode = "US";
        band = "2g";
        channel = 4;
        wifi6.enable = true;
        networks = {
          ${internalM2Wifi} = {
            ssid = "NixVegas";
            authentication = {
              mode = "wpa3-sae-transition";
              saePasswordsFile = "/etc/meshos/dc34/nixvegas.wpa3.keys";
              wpaPskFile = "/etc/meshos/dc34/nixvegas.wpa2.keys";
              enableRecommendedPairwiseCiphers = true;
            };
            settings = {
              bridge = "arena";
            };
          };
        };
      };
    */
    radios.${internalUSBWifi} = {
      countryCode = "US";
      band = "5g";
      channel = 36;
      wifi6.enable = true;
      networks = {
        ${internalUSBWifi} = {
          ssid = "NixVegas_5";
          authentication = {
            mode = "wpa3-sae-transition";
            saePasswordsFile = "/etc/meshos/dc34/nixvegas.wpa3.keys";
            wpaPskFile = "/etc/meshos/dc34/nixvegas.wpa2.keys";
            enableRecommendedPairwiseCiphers = true;
          };
          settings = {
            bridge = "arena";
          };
        };
      };
    };
  };

  # Restart it if it fails
  systemd.services.hostapd.unitConfig.StartLimitIntervalSec = 0;

  services = {
    openssh = {
      enable = true;
    };

    ntp = {
      enable = true;
      servers = [ "time.nist.gov" ];
    };

    kea.dhcp4 = {
      enable = true;
      settings = {
        valid-lifetime = 3600;
        renew-timer = 900;
        rebind-timer = 1800;

        lease-database = {
          type = "memfile";
          persist = true;
          name = "/var/lib/kea/dhcp4.leases";
        };

        interfaces-config = {
          dhcp-socket-type = "raw";
          interfaces = [
            "noc"
            "build"
            "ctf"
            "arena"
          ];

          # A bridge may have no carrier at boot ("interface isn't running"), so
          # the raw socket can't open. Don't require all sockets up front, and
          # keep retrying effectively forever so kea binds each interface as
          # soon as it's running instead of giving up and needing a restart.
          service-sockets-require-all = false;
          service-sockets-max-retries = 1000000;
          service-sockets-retry-wait-time = 5000;
        };

        client-classes = [
          {
            name = "XClient_iPXE";
            test = "substring(option[77].hex,0,4) == 'iPXE'";
            boot-file-name = "http://${baseDomain}/boot/netboot.ipxe";
          }

          {
            name = "UEFI-64-1";
            test = "substring(option[60].hex,0,20) == 'PXEClient:Arch:00007'";
            boot-file-name = "${pkgs.ipxe}/ipxe.efi";
          }

          {
            name = "UEFI-64-2";
            test = "substring(option[60].hex,0,20) == 'PXEClient:Arch:00008'";
            boot-file-name = "${pkgs.ipxe}/ipxe.efi";
          }

          {
            name = "UEFI-64-3";
            test = "substring(option[60].hex,0,20) == 'PXEClient:Arch:00009'";
            boot-file-name = "${pkgs.ipxe}/ipxe.efi";
          }

          {
            name = "Legacy";
            test = "substring(option[60].hex,0,20) == 'PXEClient:Arch:00000'";
            boot-file-name = "${pkgs.ipxe}/undionly.kpxe";
          }
        ];

        subnet4 =
          let
            inherit ((pkgs.callPackage "${meshos}/lib/net.nix" { }).lib) net;
            mkReservation = network: mac: ip: hostname: {
              hw-address = mac;
              ip-address = net.ip.add ip (lib.head (lib.split "/" network.subnet));
              inherit hostname;
            };
          in
          [
            (erlib.mkDhcp4Subnet {
              net = noc;
            })
            (erlib.mkDhcp4Subnet {
              net = build;
            })
            (erlib.mkDhcp4Subnet {
              net = ctf;
              # Pin citadel (the CTF server) to a stable ctf address so the
              # `ctf -> citadel.ctf` CNAME resolves consistently. The MAC is
              # pinned on citadel's ctf bridge; .2 sits just outside the pool.
              reservations = [
                (mkReservation ctf "02:ca:fe:c7:f0:02" 2 "citadel")
              ];
            })
            (erlib.mkDhcp4Subnet {
              net = arena;
            })
          ];

        # Enable communication between dhcp4 and a local dhcp-ddns
        # instance.
        # https://kea.readthedocs.io/en/kea-2.2.0/arm/dhcp4-srv.html#ddns-for-dhcpv4
        dhcp-ddns = {
          enable-updates = true;
        };

        ddns-send-updates = true;
        ddns-qualifying-suffix = "${domain}.";
        ddns-update-on-renew = true;
        ddns-replace-client-name = "when-not-present";
        hostname-char-set = "[^A-Za-z0-9.-]";
        hostname-char-replacement = "";
      };
    };

    kea.dhcp-ddns = {
      enable = true;
      settings = erlib.mkDhcpDdns {
        keyName = "nixos-lv-key";
        zoneName = baseDomain;
      };
    };

    knot = erlib.mkKnot {
      inherit baseDomain;
      aclName = "nixos-lv-acl";
      keyName = "nixos-lv-key";
      zoneText = ''
        @ SOA ns noc.${baseDomain} 10 86400 7200 3600000 172800
        @ NS nameserver
        nameserver A 127.0.0.1
        ${baseDomain}. A ${config.networking.mesh.plan.hosts.ghostgate.nebula.address}
        www.${baseDomain}. CNAME ghostgate.${domain}.
        cache.${baseDomain}. CNAME ghostgate.${domain}.
        git.${baseDomain}. CNAME ghostgate.${domain}.
        ghostgate.${domain}. A ${config.networking.mesh.plan.hosts.ghostgate.nebula.address}

        ; ghostgate on each of its LANs, so clients resolve it by its local
        ; gateway address — both the FQDN and bare `ghostgate` (which a client
        ; expands via its DHCP search domain, e.g. noc.dc.nixos.lv).
        ; NB: zone file comments are `;` — a `#` line is parsed as a record
        ; ("owner is invalid") and kills the whole zone load.
        ghostgate.${noc.dhcpDomain}. A ${noc.address}
        ghostgate.${build.dhcpDomain}. A ${build.address}
        ghostgate.${ctf.dhcpDomain}. A ${ctf.address}

        ctf.${domain}. CNAME citadel.ctf.${domain}.

        ; ctf.nixos.lv resolves internally straight to citadel (the direct
        ; arena -> ctf path) while public DNS points it at brass, which fronts
        ; TLS and proxies back in.
        ctf.${baseDomain}. CNAME citadel.ctf.${domain}.
      '';
    };

    kresd = {
      # knot resolver daemon
      enable = true;
      package = pkgs.knot-resolver_5.override { extraFeatures = true; };
      listenPlain = [
        "${noc.address}:53"
        "${build.address}:53"
        "${ctf.address}:53"
        "${arena.address}:53"
        "${
          lib.head (
            lib.split "/" config.networking.mesh.plan.hosts.${config.networking.hostName}.wifi.address
          )
        }:53"
        "127.0.0.1:53"
        "[::1]:53"
      ];
      extraConfig = erlib.mkKresdExtraConfig {
        subnets = [
          noc.subnet
          build.subnet
          ctf.subnet
          arena.subnet
          config.networking.mesh.plan.constants.wifi.subnet
          config.networking.mesh.plan.constants.nebula.subnet
          "127.0.0.0/8"
        ];
        ourDomains = [
          # NB: policy.domains matches these names EXACTLY (not as suffixes) —
          # every split-horizon name under nixos.lv must be listed here or
          # kresd forwards it upstream and answers with brass.
          "nixos.lv."
          "www.nixos.lv."
          "cache.nixos.lv."
          "git.nixos.lv."
          "hydra.nixos.lv."
          # Split-horizon: hand ctf.nixos.lv to our knot (-> citadel) instead of
          # the public upstream (-> brass), so ghostgate's arena reaches the CTF
          # directly.
          "ctf.nixos.lv."
        ];
        localDomains = [ "${domain}." ];
        upstreams = [ "10.6.6.7@53" ];
        # nixc.tf isn't under the nixos.lv knot zone, so answer it here (-> the
        # CTF server) for ghostgate's own arena; public DNS still points to brass.
        hints = {
          "nixc.tf" = erlib.ctfServer;
          "www.nixc.tf" = erlib.ctfServer;
        };
      };
    };

    nginx = {
      enable = true;

      upstreams = {
        "cache.dc.nixos.lv" = {
          servers = {
            "localhost:5000" = {
              weight = 100;
              fail_timeout = "30s";
              max_fails = 3;
            };
          };
        };
      };

      virtualHosts = {
        "nixos.lv" = {
          http2 = true;
          enableACME = true;
          addSSL = true;
          locations =
            let
              # The onsite flavor: artifacts under public/nixos (which the
              # netboot aliases below reach into) + /2026/onsite rendered.
              public = "${pkgs.nix-vegas-site-onsite}/public";
              netboot = "${public}/nixos/systems/x86_64-linux/netboot";
            in
            {
              # Land attendees straight on the onsite page; the rest of the
              # site stays reachable at its usual paths.
              "= /".return = "302 /2026/onsite";

              "= /boot/bzImage" = {
                alias = "${netboot}/bzImage";
              };

              "= /boot/initrd" = {
                alias = "${netboot}/initrd";
              };

              "= /boot/netboot.ipxe" = {
                alias = "${netboot}/netboot.ipxe";
              };

              "/".root = public;
            };
        };

        # Plain proxy to harmonia. On a miss harmonia itself 302-redirects the
        # client to cache.nixos.org (and warms the path in the background), so
        # nginx needs no fall-through and no resolver listener.
        "cache.nixos.lv" = {
          http2 = true;
          enableACME = true;
          forceSSL = true;
          locations."/".proxyPass = "http://cache.dc.nixos.lv";
        };

        # ghostgate is now the passthrough backend for cache.nix.vegas too.
        "cache.nix.vegas" = {
          http2 = true;
          enableACME = true;
          forceSSL = true;
          globalRedirect = "cache.nixos.lv";
        };

        # git.nix.vegas -> the canonical git.nixos.lv (Forgejo's DOMAIN), same
        # as cache.nix.vegas -> cache.nixos.lv. Public via brass passthrough.
        "git.nix.vegas" = {
          http2 = true;
          enableACME = true;
          forceSSL = true;
          globalRedirect = "git.${baseDomain}";
        };

        # Forgejo (git.nixos.lv). Public via brass SNI-passthrough; ghostgate
        # terminates TLS with its own ACME cert (brass forwards the HTTP-01
        # token). Proxies to the loopback-bound forgejo on :3000.
        "git.${baseDomain}" = {
          http2 = true;
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://127.0.0.1:3000";
            proxyWebsockets = true; # live UI / actions log streaming
            # git http-backend pushes and LFS uploads dwarf the 1m nginx
            # default; nixpkgs mirror syncs stream for a long time.
            extraConfig = ''
              client_max_body_size 0;
              proxy_request_buffering off;
              proxy_read_timeout 1800s;
              proxy_send_timeout 1800s;
            '';
          };
        };

      };
    };

    # Local Postgres for Forgejo. The forgejo module creates the db/user
    # (database.createDatabase, default true) over the unix socket; enable the
    # server explicitly so it's unambiguous on a box that had no Postgres.
    postgresql.enable = true;

    forgejo = {
      enable = true;
      database.type = "postgres";
      # Git LFS for large blobs (and nixpkgs-adjacent repos that use it).
      lfs.enable = true;
      settings = {
        DEFAULT.APP_NAME = "Nix Vegas Git";

        server = {
          DOMAIN = "git.${baseDomain}";
          ROOT_URL = "https://git.${baseDomain}/";
          # Bind the web app to loopback only — nginx terminates TLS and
          # proxies in (see the git.nixos.lv vhost). :3000 is never on an
          # uplink, so it's not in the firewall either.
          HTTP_ADDR = "127.0.0.1";
          HTTP_PORT = 3000;
          # Built-in SSH server for git push/pull. Reachable onsite and over
          # Nebula, NOT publicly: brass only SNI-passes :443, so 2222 never
          # crosses the public ingress. Public users clone read-only over
          # HTTPS; SSH is for admins/mirrors.
          START_SSH_SERVER = true;
          SSH_LISTEN_PORT = 2222;
          SSH_PORT = 2222; # advertised in clone URLs
          SSH_DOMAIN = "git.${baseDomain}";
        };

        # Open registration so attendees can make accounts. git.nixos.lv is
        # public (brass passthrough), so signups are reachable from the whole
        # internet — guard against bots with the built-in image captcha, which
        # works offline (no external captcha/reCAPTCHA dependency). Anonymous
        # browse/clone stays allowed (REQUIRE_SIGNIN_VIEW = false).
        service = {
          DISABLE_REGISTRATION = false;
          REQUIRE_SIGNIN_VIEW = false;
          ENABLE_CAPTCHA = true;
          CAPTCHA_TYPE = "image";
        };
        session.COOKIE_SECURE = true;

        # Actions (CI), pulling action definitions from github by default.
        actions = {
          ENABLED = true;
          DEFAULT_ACTIONS_URL = "github";
        };

        # nixpkgs is a very large repo (multi-GB, tens of thousands of refs):
        # give migration/mirror/gc operations room so the initial import and
        # periodic pull-mirror syncs don't time out.
        "git.timeout" = {
          MIGRATE = 1800;
          MIRROR = 1800;
          CLONE = 1800;
          PULL = 1800;
          GC = 1800;
        };
        # Global git config Forgejo applies to its git operations. Tuned for
        # serving a repo as large as nixpkgs to many clients without pegging
        # ghostgate (which is also the router + binary cache):
        #   - writeBitmaps: reachability bitmaps so `git upload-pack` reuses a
        #     precomputed pack instead of recomputing the whole graph per clone
        #     (bare repos default this on, but set it explicitly so every gc
        #     keeps it). The initial mirror still needs one `repack -adb`.
        #   - allowFilter: let clients do cheap partial clones
        #     (`--filter=blob:none` / `tree:0`).
        #   - allowAnySHA1InWant: let clients fetch an arbitrary commit by SHA,
        #     e.g. a flake input pinned with `?rev=`.
        "git.config" = {
          "repack.writeBitmaps" = true;
          "uploadpack.allowFilter" = true;
          "uploadpack.allowAnySHA1InWant" = true;
        };
        # Pull-mirror refresh cadence and generous push/upload limits.
        mirror.DEFAULT_INTERVAL = "8h";
        "repository.upload" = {
          FILE_MAX_SIZE = 2048; # MiB per file
          MAX_FILES = 20;
        };

        # Sending emails is completely optional
        # You can send a test email from the web UI at:
        # Profile Picture > Site Administration > Configuration >  Mailer Configuration
        mailer = {
          ENABLED = true;
          SMTP_ADDR = "mail.nix.vegas";
          FROM = "noreply@nix.vegas";
          USER = "noreply@nix.vegas";
        };
      };
      secrets = {
        mailer.PASSWD = "/var/lib/forgejo/data/mail.pass";
      };
    };
  };

  # Forgejo git-over-SSH (built-in server on :2222) — admin/mirror pushes from
  # the management LAN and over Nebula only. The WAN firewall
  # (allowedTCPPorts above) deliberately omits 2222, so it's never public;
  # public users clone read-only over HTTPS. Not opened on arena — attendees
  # don't push.
  networking.firewall.interfaces =
    let
      forgejoSsh = { allowedTCPPorts = [ 2222 ]; };
    in
    {
      noc = forgejoSsh;
      "nebula.arena" = forgejoSsh;
    };

  users = {
    users.tftpd = {
      isSystemUser = true;
      group = "tftpd";
    };
    groups.tftpd = { };
  };

  services.harmonia = {
    # substitute-on-miss patch (pkgs/harmonia/substitute-on-miss.patch; spec:
    # docs/superpowers/specs/2026-07-16-harmonia-substitute-on-miss-design.md).
    # On a narinfo miss harmonia asks the nix daemon to substitute the path in
    # the background so the next request is served locally. Upstream PR to
    # nix-community/harmonia planned post-event.
    package =
      let
        # Patch the source, then vendor from the patched Cargo.lock via
        # cargoLock.lockFile (importCargoLock). The default cargoHash path
        # (fetchCargoVendor) normalizes workspace-internal path deps out of the
        # vendored Cargo.lock, so its consistency check can never match a lock
        # that adds harmonia-store-remote/harmonia-protocol to harmonia-cache
        # ("Cargo.lock is not the same in vendor"). importCargoLock vendors
        # straight from the lockfile with no such diff — and needs no hash,
        # since the patch adds only in-tree path deps, no new registry crates.
        patchedSrc = pkgs.applyPatches {
          name = "harmonia-substitute-on-miss-src";
          inherit (pkgs.harmonia) src;
          patches = [ ../../pkgs/harmonia/substitute-on-miss.patch ];
        };
      in
      pkgs.harmonia.overrideAttrs (prev: {
        src = patchedSrc;
        cargoDeps = pkgs.rustPlatform.importCargoLock {
          lockFile = "${patchedSrc}/Cargo.lock";
        };
      });
    cache = {
      enable = true;
      settings = {
        # Serve raw NARs: harmonia 3.x otherwise zstd-encodes on the fly for
        # Accept-Encoding: zstd clients. Serve the dedup'd store as-is.
        enable_compression = false;
        # Stream-through cache: on a narinfo miss harmonia serves upstream's
        # narinfo rewritten to point at its own NAR endpoint; on the NAR
        # request it fetches the upstream .nar.xz once (over its own HTTPS),
        # decodes it, and fans the bytes to the client(s) AND into the store
        # via the nix daemon — one uplink fetch, no amplification, no stall.
        substitute_on_miss = true;
        miss_upstream_url = "https://cache.nixos.org";
        # In-flight narinfo LRU (low + self-cleaning; entries drop when their
        # NAR job completes).
        miss_narinfo_cache_size = 1024;
        miss_narinfo_cache_ttl = 600;
      };
    };
  };

  # Stock harmonia is serve-only (it only accepts on a socket-activated fd and
  # talks to the nix daemon over AF_UNIX), so its unit is network-sandboxed:
  # PrivateNetwork = true, RestrictAddressFamilies = [ "AF_UNIX" ],
  # IPAddressDeny = "any". The stream-through substitute-on-miss makes outbound
  # HTTPS to cache.nixos.org — reqwest can't even socket(AF_INET) under that
  # sandbox, so every miss silently fell back to a stock 404. Open the unit up
  # just enough to reach upstream. (The daemon socket stays AF_UNIX.)
  systemd.services.harmonia.serviceConfig = {
    PrivateNetwork = lib.mkForce false;
    RestrictAddressFamilies = lib.mkForce [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
    ];
    IPAddressDeny = lib.mkForce "";
  };

  systemd.services = {
    tftpd = {
      after = [ "nftables.service" ];
      description = "TFTP server";
      serviceConfig = rec {
        User = "tftpd";
        Group = "tftpd";
        Restart = "always";
        RestartSec = 5;
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = AmbientCapabilities;
        Type = "exec";
        RuntimeDirectory = "tftpd";
        PIDFile = "${RuntimeDirectory}/tftpd.pid";
        ExecStart = "${pkgs.tftp-hpa}/bin/in.tftpd -v -l -a 0.0.0.0:69 -P /run/${PIDFile} ${pkgs.ipxe}";
        TimeoutStopSec = 20;
      };
      wantedBy = [ "multi-user.target" ];
    };
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "noc@nix.vegas";
  };

  systemd.services.kea-dhcp4-server.partOf = [ "hostapd.service" ];
}
