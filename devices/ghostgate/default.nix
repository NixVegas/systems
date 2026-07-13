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
  wwanInterfaces = [ onboardWifi ];
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

  # Trunked sponsored servers.
  build = erlib.mkNet {
    id = 2;
    base = "10.4.1";
    subdomain = "build";
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

  fileSystems."/var/lib/ncps" = {
    device = "ghostgate/local/cache";
    fsType = "zfs";
  };

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
      server = {
        enable = true;
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

      # Prefer build (10Gbit)
      preferred_ranges = [ build.subnet ];

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

  systemd.services."nebula@arena".postStart = ''
    ${erlib.arenaPostStartPreamble {
      ip = lib.getExe' pkgs.iproute2 "ip";
      sleep = lib.getExe' pkgs.coreutils "sleep";
    }}
    _rule_replace from ${arena.subnet} lookup arena
    _rule_replace from ${build.subnet} lookup arena
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
    _ip route replace ${noc.subnet} dev noc table arena
    _ip route replace ${config.networking.mesh.plan.constants.wifi.subnet} dev mesh2 table arena

    # Reach the VP2420 arena LANs over Nebula (full mesh) — in table arena for
    # LAN clients, and in the main table so ghostgate itself can reach them.
    ${erlib.arenaTableRoutes { }}
    ${erlib.arenaTableRoutes { table = "main"; }}
    _ip route replace default dev nebula.arena table arena
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

    vlans = {
      "trunk1.build" = {
        inherit (build) id;
        interface = trunkInterface1;
      };
      "trunk2.build" = {
        inherit (build) id;
        interface = trunkInterface2;
      };
      "trunk1.wwan2" = {
        id = 3;
        interface = trunkInterface1;
      };
      "trunk2.wwan2" = {
        id = 3;
        interface = trunkInterface2;
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

      wwan2.interfaces = [
        "trunk1.wwan2"
        "trunk2.wwan2"
      ];

      noc.interfaces = nocInterfaces;

      build.interfaces = [
        "trunk1.build"
        "trunk2.build"
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
            }

            chain input {
              type filter hook input priority filter; policy drop;

              # Allow trusted networks to access the router
              iifname {
                "lo",
                "noc",
                "build",
                "arena",
                "nebula.arena",
                "mesh2"
              } counter accept

              # Allow returning traffic from WAN, arena, and the mesh
              iifname {"wan1", "${wwan1}", "wwan2", "nebula.arena", "mesh2"} ct state { established, related } counter accept

              # Allow SSH in over the wired WAN uplink so ghostgate can be
              # deployed remotely. The WWAN uplinks stay closed (below).
              iifname "wan1" tcp dport { ${lib.concatMapStringsSep ", " toString config.services.openssh.ports} } counter accept

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

              # Allow only localhost WAN access
              iifname {
                "lo"
              } oifname {
                "wan1",
                "${wwan1}",
                "wwan2",
              } counter accept comment "Allow trusted LAN to WAN"

              iifname { "lo", "arena", "build", "mesh2", "noc" } oifname { "nebula.arena" } counter accept comment "Allow Arena networks to get out"

              # Let mesh clients (2420s falling back through ghostgate) reach the
              # Nebula lighthouses via the clear WAN to bootstrap their own
              # Nebula. Scoped to the lighthouse UDP ports only — all other mesh
              # traffic stays encrypted over Nebula (matching the carve-out in
              # the nebula@arena postStart).
              iifname "mesh2" oifname "wan1" udp dport { ${lib.concatMapStringsSep ", " toString lighthousePorts} } counter accept comment "mesh -> lighthouse (clear bootstrap)"
              iifname "wan1" oifname "mesh2" ct state established,related counter accept comment "lighthouse reply -> mesh"

              # Let NOC get to build.
              iifname { "noc" } oifname { "build" } counter accept
              iifname { "build" } oifname { "noc" } ct state established,related counter accept

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
              iifname {"noc", "build", "arena", "mesh2"} udp dport {53, 123} counter redirect
              iifname {"noc", "build", "arena", "mesh2"} tcp dport {53} counter redirect
            }

            # Setup NAT masquerading on the wan interface
            chain postrouting {
              type nat hook postrouting priority filter; policy accept;
              # Note: no "arena" here — inter-arena traffic delivered to the
              # arena LAN must keep its real source IP (reachable both ways).
              oifname {
                "build",
                "noc",
                "wan1",
                "${wwan1}",
                "wwan2",
                "mesh2"
              } masquerade
              # Masquerade only genuine internet egress over Nebula. Traffic to
              # other arenas OR to Nebula hosts (e.g. a router's own Nebula IP,
              # as when pinging from the box) keeps its real source so replies
              # match conntrack and stay reachable both ways.
              oifname "nebula.arena" ip daddr != { ${lib.concatStringsSep ", " (erlib.arenaCidrs ++ [ config.networking.mesh.plan.constants.nebula.subnet ])} } masquerade
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

  nixpkcs = {
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
    /*radios.${internalM2Wifi} = {
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
    };*/
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
              reservations = [
                (mkReservation noc "10:ff:e0:37:91:ba" 2 "bigzam")
                (mkReservation noc "9c:6b:00:4b:13:38" 3 "saitama")
                (mkReservation noc "9c:6b:00:4b:13:32" 4 "genos")
                (mkReservation noc "9c:6b:00:47:31:fe" 5 "tatsumaki")
              ];
            })
            (erlib.mkDhcp4Subnet {
              net = build;
              reservations = [
                (mkReservation build "10:ff:e0:37:91:bb" 2 "bigzam")
                (mkReservation build "9c:6b:00:4b:13:36" 3 "saitama")
                (mkReservation build "9c:6b:00:4b:13:30" 4 "genos")
                (mkReservation build "9c:6b:00:47:31:fc" 5 "tatsumaki")
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
        www.${baseDomain} CNAME ghostgate.${domain}.
        cache.${baseDomain}. CNAME ghostgate.${domain}.
        ghostgate.${domain}. A ${config.networking.mesh.plan.hosts.ghostgate.nebula.address}

        hydra.saitama.build.${domain}. CNAME saitama.build.${domain}.
        hydra.${baseDomain}. CNAME hydra.saitama.build.${domain}.
      '';
    };

    kresd = {
      # knot resolver daemon
      enable = true;
      package = pkgs.knot-resolver_5.override { extraFeatures = true; };
      listenPlain = [
        "${noc.address}:53"
        "${build.address}:53"
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
          arena.subnet
          config.networking.mesh.plan.constants.wifi.subnet
          config.networking.mesh.plan.constants.nebula.subnet
          "127.0.0.0/8"
        ];
        ourDomains = [
          "nixos.lv."
          "www.nixos.lv."
          "cache.nixos.lv."
          "hydra.nixos.lv."
        ];
        localDomains = [ "${domain}." ];
        upstreams = [ "10.6.6.7@53" ];
      };
    };

    nginx = {
      enable = true;

      upstreams = {
        "cache.dc.nixos.lv" = {
          servers = {
            # NCPS upstreams to saitama and bigzam, comment this and uncomment the below if you want to skip ncps
            #"localhost:8501" = { };
            "${config.networking.mesh.plan.hosts.saitama.nebula.address}:5000" = {
              weight = 100;
              fail_timeout = "30s";
              max_fails = 3;
            };
            "${config.networking.mesh.plan.hosts.bigzam.nebula.address}:5000" = {
              weight = 50;
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
              public = "${pkgs.nix-vegas-site}/public";
              netboot = "${public}/nixos/systems/x86_64-linux/netboot";
            in
            {
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

        "cache.nixos.lv" = {
          http2 = true;
          enableACME = true;
          forceSSL = true;
          locations."/".proxyPass = "http://cache.dc.nixos.lv";
        };
      };
    };

    ncps = {
      # This is actually what is reverse proxied to, as opposed to what MeshOS sets up
      server.addr = lib.mkForce "127.0.0.1:8501";
      # We have ~1 TB of storage, use 3/4 of it for local cache
      cache.maxSize = "750G";
    };
  };

  users = {
    users.tftpd = {
      isSystemUser = true;
      group = "tftpd";
    };
    groups.tftpd = { };
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
