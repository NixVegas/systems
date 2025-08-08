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
  externalUSBAWifi = "wlp0s13f0u2";
  externalUSBCWifi = "wlp0s13f0u3";

  modemInterfaces = [ "enp0s20f0u3" ];
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

  # NOC managment network
  noc = rec {
    id = 1;
    prefix = 24;
    subnet = "10.4.0.0/${builtins.toString prefix}";
    address = "10.4.0.1";
    dhcpStart = "10.4.0.128";
    dhcpEnd = "10.4.0.254";
    dhcpDomain = "noc.${domain}";
  };

  # Trunked sponsored servers
  build = rec {
    id = 2;
    prefix = 24;
    subnet = "10.4.1.0/${builtins.toString prefix}";
    address = "10.4.1.1";
    dhcpStart = "10.4.1.128";
    dhcpEnd = "10.4.1.254";
    dhcpDomain = "build.${domain}";
  };

  # Attendee network.
  arena = rec {
    id = 4;
    prefix = 24;
    subnet = "10.33.0.0/${builtins.toString prefix}";
    address = "10.33.0.1";
    dhcpStart = "10.33.0.128";
    dhcpEnd = "10.33.0.254";
    dhcpDomain = "arena.${domain}";
  };
in
{
  imports = [
    ./hardware-configuration.nix
  ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.memtest86.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.kernelParams = [
    "console=ttyS1,115200n8"
  ];
  boot.kernelPackages = pkgs.linuxKernel.packages.linux_xanmod_stable;

  boot.kernel.sysctl = {
    "net.ipv4.conf.all.forwarding" = true;
    "net.ipv6.conf.all.forwarding" = true;

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

  hardware.enableRedistributableFirmware = true;

  networking.mesh = {
    nebula = {
      enable = true;
      networkName = "arena";
      tpm2Key = true;
    };
    wifi = {
      enable = true;
      countryCode = "US";
      dedicatedWifiDevices = [ externalUSBAWifi ];
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
        # 10.6.6.6 is an internet gateway
        unsafe_routes = [
          {
            route = "0.0.0.0/0";
            via = "10.6.6.6";
            install = false;
          }
        ];
      };

      # Prefer build (10Gbit)
      preferred_ranges = [ build.subnet ];
    };
  };

  systemd.services."nebula@arena".postStart = ''
    _ip() {
      ${lib.getExe' pkgs.iproute2 "ip"} "$@"
    }

    _rule_replace() {
      if [ -z "$(_ip rule show "$@" || true)" ]; then
        _ip rule add "$@"
      fi
    }
    _rule_replace from ${arena.subnet} lookup arena
    _rule_replace from ${build.subnet} lookup arena
    _rule_replace from ${noc.subnet} lookup arena
    _rule_replace from ${config.networking.mesh.plan.constants.wifi.subnet} lookup arena
    _rule_replace from ${config.networking.mesh.plan.constants.nebula.subnet} lookup arena
    _ip route replace ${arena.subnet} dev arena table arena
    _ip route replace ${build.subnet} dev build table arena
    _ip route replace ${noc.subnet} dev noc table arena
    _ip route replace ${config.networking.mesh.plan.constants.wifi.subnet} dev mesh2 table arena
    _ip route replace default via ${config.networking.mesh.plan.hosts.adamantia.nebula.address} table arena
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
      # deprioritize modem
      interface wan1
      metric 1000
      interface ${wwan1}
      metric 1001
      interface wwan2
      metric 1002
      interface modem
      metric 2000
    '';

    nat.enable = lib.mkForce false;
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 53 69 80 443 5355 ];
      allowedUDPPorts = [ 53 67 68 69 123 5355 ];
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

      # And the WWAN interface.
      modem.useDHCP = true;

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

      modem.interfaces = modemInterfaces;

      noc.interfaces = nocInterfaces;

      build.interfaces = [
        "trunk1.build"
        "trunk2.build"
      ];

      arena.interfaces = arenaInterfaces;
      "arena.wlan".interfaces = [];
    };

    nftables = {
      enable = true;
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

              # Allow only localhost WAN access
              iifname {
                "lo"
              } oifname {
                "wan1",
                "${wwan1}",
                "wwan2",
              } counter accept comment "Allow trusted LAN to WAN"

              iifname { "lo", "arena", "build", "mesh2", "noc" } oifname { "nebula.arena" } counter accept comment "Allow Arena networks to get out"

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
              oifname {
                "build",
                "noc",
                "arena",
                "wan1",
                "${wwan1}",
                "wwan2",
                "nebula.arena",
                "mesh2"
              } masquerade
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
    userControlled.enable = true;
    secretsFile = "/etc/meshos/dc33/wireless.env";
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
    radios.${externalUSBCWifi} = {
      countryCode = "US";
      band = "2g";
      channel = 4;
      wifi6.enable = true;
      networks = {
        ${externalUSBCWifi} = {
          ssid = "NixVegas";
          authentication = {
            mode = "wpa3-sae-transition";
            saePasswordsFile = "/etc/meshos/dc33/nixvegas.wpa3.keys";
            wpaPskFile = "/etc/meshos/dc33/nixvegas.wpa2.keys";
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

    acpid = {
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
            #next-server = arena.address;
            boot-file-name = "${pkgs.ipxe}/undionly.kpxe";
          }
        ];

        subnet4 = let
          inherit ((pkgs.callPackage "${meshos}/lib/net.nix" { }).lib) net;
          mkReservation = network: mac: ip: hostname:
            {
              hw-address = mac;
              ip-address = net.ip.add ip (lib.head (lib.split "/" network.subnet));
              inherit hostname;
            };

        in [
          {
            inherit (noc) subnet id;
            pools = [
              {
                pool = "${noc.dhcpStart} - ${noc.dhcpEnd}";
              }
            ];
            reservations = [
              (mkReservation noc "10:ff:e0:37:91:ba" 2 "bigzam")
              (mkReservation noc "9c:6b:00:4b:13:38" 3 "saitama")
              (mkReservation noc "9c:6b:00:4b:13:32" 4 "genos")
              (mkReservation noc "9c:6b:00:47:31:fe" 5 "tatsumaki")
            ];
            ddns-qualifying-suffix = "${noc.dhcpDomain}.";
            option-data = [
              {
                name = "routers";
                data = noc.address;
                always-send = true;
              }
              {
                name = "domain-name-servers";
                data = noc.address;
                always-send = true;
              }
              {
                name = "domain-name";
                data = noc.dhcpDomain;
                always-send = true;
              }
              {
                name = "ntp-servers";
                data = noc.address;
                always-send = true;
              }
            ];
          }
          {
            inherit (build) subnet id;
            pools = [
              {
                pool = "${build.dhcpStart} - ${build.dhcpEnd}";
              }
            ];
            reservations = [
              (mkReservation build "10:ff:e0:37:91:bb" 2 "bigzam")
              (mkReservation build "9c:6b:00:4b:13:36" 3 "saitama")
              (mkReservation build "9c:6b:00:4b:13:30" 4 "genos")
              (mkReservation build "9c:6b:00:47:31:fc" 5 "tatsumaki")
            ];
            ddns-qualifying-suffix = "${build.dhcpDomain}.";
            option-data = [
              {
                name = "routers";
                data = build.address;
                always-send = true;
              }
              {
                name = "domain-name-servers";
                data = build.address;
                always-send = true;
              }
              {
                name = "domain-name";
                data = build.dhcpDomain;
                always-send = true;
              }
              {
                name = "ntp-servers";
                data = build.address;
                always-send = true;
              }
            ];
          }
          {
            inherit (arena) subnet id;
            pools = [
              {
                pool = "${arena.dhcpStart} - ${arena.dhcpEnd}";
              }
            ];
            ddns-qualifying-suffix = "${arena.dhcpDomain}.";
            option-data = [
              {
                name = "routers";
                data = arena.address;
                always-send = true;
              }
              {
                name = "domain-name-servers";
                data = arena.address;
                always-send = true;
              }
              {
                name = "domain-name";
                data = arena.dhcpDomain;
                always-send = true;
              }
              {
                name = "ntp-servers";
                data = arena.address;
                always-send = true;
              }
            ];
          }
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
      settings = {
        forward-ddns = {
          ddns-domains = [
            {
              name = "${baseDomain}.";
              key-name = "nixos-lv-key";
              dns-servers = [
                {
                  ip-address = "127.0.0.1";
                  port = 53535;
                }
              ];
            }
          ];
        };
        tsig-keys = [
          {
            name = "nixos-lv-key";
            algorithm = "HMAC-SHA256";
            secret-file = "/etc/kea/tsig.key";
          }
        ];
      };
    };

    knot =
      let
        # nameserver A ${config.networking.mesh.plan.hosts.ghostgate.nebula.address}
        zone = pkgs.writeTextDir "${baseDomain}.zone" ''
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
        zonesDir = pkgs.buildEnv {
          name = "knot-zones";
          paths = [ zone ];
        };
      in
      {
        enable = true;
        extraArgs = [
          "-v"
        ];
        keyFiles = [ "/etc/knot/tsig.conf" ];
        settings = {
          server = {
            listen = "127.0.0.1@53535";
          };
          log = {
            syslog = {
              any = "debug";
            };
          };
          acl = {
            nixos-lv-acl = {
              key = "nixos-lv-key";
              action = "update";
            };
          };
          template = {
            default = {
              storage = zonesDir;
              zonefile-sync = -1;
              zonefile-load = "difference-no-serial";
              journal-content = "all";
            };
          };
          zone = {
            ${baseDomain} = {
              file = "${baseDomain}.zone";
              acl = [ "nixos-lv-acl" ];
            };
          };
        };
      };

    kresd = {
      # knot resolver daemon
      enable = true;
      package = pkgs.knot-resolver.override { extraFeatures = true; };
      listenPlain = [
        "${noc.address}:53"
        "${build.address}:53"
        "${arena.address}:53"
        "${lib.head (lib.split "/" config.networking.mesh.plan.hosts.${config.networking.hostName}.wifi.address)}:53"
        "127.0.0.1:53"
        "[::1]:53"
      ];
      extraConfig = ''
        cache.size = 32 * MB
        -- verbose(true)

        modules = {
          'policy',
          'view',
          'hints',
          'serve_stale < cache',
          'workarounds < iterate',
          'stats',
          'predict'
        }

        -- Accept all requests from these subnets
        subnets = {
          '${noc.subnet}',
          '${build.subnet}',
          '${arena.subnet}',
          '${config.networking.mesh.plan.constants.wifi.subnet}',
          '${config.networking.mesh.plan.constants.nebula.subnet}',
          '127.0.0.0/8'
        }
        for i, v in ipairs(subnets) do
          view:addr(v, function(req, qry) return policy.PASS end)
        end

        -- Drop everything that hasn't matched
        view:addr('0.0.0.0/0', function (req, qry) return policy.DROP end)

        -- We are responsible for these.
        our_domains = {
          'nixos.lv.',
          'www.nixos.lv.',
          'cache.nixos.lv.',
          'hydra.nixos.lv.'
        }
        policy:add(policy.domains(policy.STUB('127.0.0.1@53535'), policy.todnames(our_domains)))

        -- Forward requests for the local DHCP domains.
        local_domains = { '${domain}.' }
        for i, v in ipairs(local_domains) do
          policy:add(policy.suffix(policy.STUB('127.0.0.1@53535'), {todname(v)}))
        end

        -- Stub everything else over Nebula
        policy:add(policy.suffix(policy.STUB('10.6.6.6@53'), {todname('.')}))

        -- Uncomment one of the following stanzas in case you want to forward all requests to 1.1.1.1 or 9.9.9.9 via DNS-over-TLS.
        --policy:add(policy.all(policy.TLS_FORWARD({
        --  { '9.9.9.9', hostname='dns.quad9.net', ca_file='/etc/ssl/certs/ca-certificates.crt' },
        --  { '2620:fe::fe', hostname='dns.quad9.net', ca_file='/etc/ssl/certs/ca-certificates.crt' },
        --  { '1.1.1.1', hostname='cloudflare-dns.com', ca_file='/etc/ssl/certs/ca-certificates.crt' },
        --  { '2606:4700:4700::1111', hostname='cloudflare-dns.com', ca_file='/etc/ssl/certs/ca-certificates.crt' },
        --})))

        -- Prefetch learning (20-minute blocks over 24 hours)
        predict.config({ window = 20, period = 72 })
      '';
    };

    nginx = {
      enable = true;
      recommendedTlsSettings = true;
      recommendedGzipSettings = true;
      recommendedZstdSettings = true;
      recommendedBrotliSettings = true;
      recommendedProxySettings = true;
      recommendedUwsgiSettings = true;
      recommendedOptimisation = true;

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
          locations = let
            public = "${pkgs.nix-vegas-site-onsite}/public";
            netboot = "${public}/nixos/systems/x86_64-linux/netboot";
          in {
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

  # Set your time zone.
  time.timeZone = lib.mkOverride 10 "America/Los_Angeles";

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = "25.05"; # Did you read the comment?
}
