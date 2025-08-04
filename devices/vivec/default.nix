# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).
{ config, pkgs, lib, modulesPath, ... }:

let
  baseDomain = "nixos.lv";
  domain = "dc.${baseDomain}";

  thisHost = config.networking.mesh.plan.hosts.${config.networking.hostName};

  # WWAN
  wwan = "wlp0s20f0u3";

  # WLAN
  wlan = "wlp0s20f0u8";

  # Monitor
  mon = "wlp0s20f0u2";

  # Attendee network.
  arena = rec {
    id = 1;
    prefix = 24;
    subnet = "10.33.1.0/${builtins.toString prefix}";
    address = "10.33.1.1";
    dhcpStart = "10.33.1.128";
    dhcpEnd = "10.33.1.254";
    dhcpDomain = "arena.${domain}";
  };
in
{
  imports =
    [ (modulesPath + "/installer/scan/not-detected.nix")
    ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "usbhid" "usb_storage" "sd_mod" "sdhci_pci" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" "option" ];
  boot.extraModulePackages = [ ];

  fileSystems."/nix" = lib.mkForce
    { device = "vehk/local/nix";
      fsType = "zfs";
    };

  fileSystems."/home" = lib.mkForce
    { device = "vehk/user/home";
      fsType = "zfs";
    };

  fileSystems."/var/lib/ncps" = {
    device = "vehk/local/cache";
    fsType = "zfs";
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200n8" ];
  boot.kernelPackages = pkgs.linuxKernel.packages.linux_xanmod_stable;

  services.gpsd = let
    nmeaDevice = "/dev/serial/by-id/usb-Qualcomm_MDG200-if02-port0";
  in {
    enable = true;
    nowait = true;
    devices = lib.singleton nmeaDevice;
    # 9600-8-N-1
    extraArgs = [ "-s" "9600" "-f" "8N1" ];
  };

  boot.kernelPatches = [{
    name = "tremont-march";
    patch = ./0001-arch-x86-Kconfig.cpu-Add-Tremont-support.patch;
    extraStructuredConfig.MTREMONT = lib.kernel.yes;
  }];

  boot.kernel.sysctl = {
    "net.ipv4.conf.all.forwarding" = true;
    "net.ipv6.conf.all.forwarding" = true;
  };

  # Try to save power since these machines are usually on battery
  powerManagement.cpuFreqGovernor = "powersave";

  hardware.enableRedistributableFirmware = true;

  networking.hosts = {
    # We get to lv over 802.11s
    "10.5.0.1" = [ "cache.nixos.lv" ];
  };

  networking.mesh = {
    wifi = {
      enable = true;
      countryCode = "US";
      dedicatedWifiDevices = lib.mkDefault [ "wlp0s20f0u4" ];
      useForFallbackInternetAccess = true;
      # 20/30 under ideal conditions over 4G, hotel wifi limited to
      # 50, let's just call it 50 for BATMAN throughput estimation purposes
      advertisedUploadMbps = 50;
      advertisedDownloadMbps = 50;
    };
    nebula = {
      enable = true;
      networkName = "arena";
      tpm2Key = true;
    };
    cache = {
      server = {
        enable = true;
      };
      client = {
        enable = true;
        useHydra = false;
        useRecommendedCacheSettings = true;
      };
    };
    ieee80211s.networks.mesh2.metric = 1001;
  };

  services.nebula.networks.arena = {
    tun.device = lib.mkForce "nebula.arena";
  };

  # These commands will let users on DHCP get out over the LAN ports.
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

    _ip route flush table arena

    # Let them get to the local network
    _ip route replace ${arena.subnet} dev arena table arena

    # Let them get to the mesh peers
    _ip route replace ${config.networking.mesh.plan.constants.wifi.subnet} dev mesh2 via ${lib.head (lib.split "/" config.networking.mesh.plan.hosts.ghostgate.wifi.address)} table arena

    # If there's a wan port, route through that
    # Left commented for now since linkdown behaves weirdly.
    #_ip route replace default dev wan metric 1000 table arena

    # Otherwise route them through our wifi.
    # TODO: Maybe actually go nebula with the router as a gateway; Nebula will be more resilient
    # but BATMAN will work here too.
    _ip route replace default via ${lib.head (lib.split "/" config.networking.mesh.plan.hosts.ghostgate.wifi.address)} metric 1001 table arena
    _ip route replace default via ${lib.head (lib.split "/" config.networking.mesh.plan.hosts.ghostgate.wifi.address)} metric 1001
  '';

  services.kismet = {
    enable = true;
    httpd.enable = true;
    serverName = config.networking.hostName;
    settings = {
      source = {
        ${mon} = {
          name = "panda2";
        };
      };
      gps.gpsd = { host = "localhost"; port = 2947; };
    };
  };

  # List packages installed in system profile. To search, run:/
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    wget vim curl git tmux psmisc man-pages
    htop linuxPackages.perf iftop
    speedtest-cli
    zip unzip
    usbutils
    gpsd iw

    openssl
    firefox

    iproute2 traceroute unbound bind
    bridge-utils ethtool tcpdump conntrack-tools
    nebula
  ];

  networking = {
    hostName = "vivec";
    nameservers = [ "127.0.0.1" ];

    nat.enable = lib.mkForce false;
    firewall.enable = false;

    iproute2 = {
      enable = true;
      rttablesExtraConfig = ''
        200 arena
      '';
    };

    dhcpcd = {
      allowInterfaces = [ "wan" wwan "modem" ];
      extraConfig = ''
        interface wan
        metric 1000

        # This is handled by BATMAN
        #interface mesh2
        #metric 1001

        interface arena
        metric 1002

        interface ${wwan}
        metric 1003

        interface modem
        metric 1004
      '';
    };

    interfaces = {
      wan.useDHCP = true;
      ${wwan}.useDHCP = true;
      modem.useDHCP = true;
      arena = {
        ipv4.addresses = [{
          inherit (arena) address;
          prefixLength = arena.prefix;
        }];
      };
    };

    bridges = {
      arena = {
        interfaces = [ "eth0" "enp2s0" "enp3s0" ];
      };

      wan = {
        interfaces = [ "enp4s0" ];
      };

      modem = {
        interfaces = [ "enp0s20f0u5" ];
      };
    };

    wireless = {
      enable = true;
      interfaces = [ wwan ];
      fallbackToWPA2 = false;
      allowAuxiliaryImperativeNetworks = true;
      userControlled.enable = true;
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
                "arena",
                "mesh2"
              } counter accept

              # Allow returning traffic from WAN, WWAN, the modem, arena, and the mesh
              iifname {"wan", "${wwan}", "modem", "arena", "mesh2"} ct state { established, related } counter accept

              # Allow Nebula traffic from external interfaces.
              iifname {"wan", "${wwan}", "modem", "mesh2"} udp dport ${toString (config.networking.mesh.plan.nebula.portFor thisHost)} counter accept

              # Allow some ICMP by default
              ip protocol icmp icmp type { destination-unreachable, echo-request, time-exceeded, parameter-problem } accept
              ip6 nexthdr icmpv6 icmpv6 type { destination-unreachable, echo-request, time-exceeded, parameter-problem, packet-too-big } accept

              # Drop everything else from untrusted external interfaces
              iifname {"${wwan}", "modem"} drop
            }

            chain forward {
              type filter hook forward priority filter; policy drop;

              # Allow trusted networks access to arena or the mesh
              iifname {
                "lo",
                "arena"
              } oifname {
                "mesh2",
                "wan"
              } counter accept comment "Allow trusted LAN to Arena or the mesh"

              # Allow less trusted networks to get internet access without being able to hit LAN
              iifname {
                "mesh2"
              } oifname {
                "arena"
              } counter accept comment "Allow less trusted LAN to hit default routers"

              # Allow localhost access to untrusted public networks
              iifname {
                "lo"
              } oifname {
                "${wwan}",
                "modem"
              } counter accept comment "Allow localhost to WAN/WWAN/modem";

              # Allow established WAN to return
              iifname {
                "mesh2",
                "wan",
                "${wwan}",
                "modem"
              } oifname {
                "lo",
                "arena",
              } ct state established,related counter accept comment "Allow established back to LANs"
            }
          '';
        };

        nat = {
          family = "ip";
          content = ''
            chain prerouting {
              type nat hook prerouting priority filter

              # Redirect DNS and NTP queries to us
              iifname {"arena"} udp dport {53, 123} counter redirect
              iifname {"arena"} tcp dport {53} counter redirect
            }

            # Setup NAT masquerading on the Arena interface
            chain postrouting {
              type nat hook postrouting priority filter; policy accept;
              oifname {"wan", "arena", "mesh2"} masquerade
            }
          '';
        };
      };
    };
  };

  systemd = {
    network.wait-online.enable = false;

    extraConfig = ''
      # Make boot snappier.
      DefaultDeviceTimeoutSec=15
    '';

    services = {
      # HACK to support pluggable devices: https://github.com/NixOS/nixpkgs/pull/155017
      "wpa_supplicant-${wwan}" = {
        serviceConfig = {
          Restart = "always";
          RestartSec = 15;
        };
      };

      # Allow this to exist independently of device status
      "network-addresses-${wwan}".bindsTo = lib.mkForce [];

      # Protectli devices have a serial console, enable it despite being otherwise headless.
      "serial-getty@ttyS0".enable = true;

      # Initialize the GPS using AT commands on the modem.
      "gpsd".serviceConfig.ExecStartPre = let
        atCommandDevice = "/dev/serial/by-id/usb-Qualcomm_MDG200-if03-port0";

        # https://web.ics.purdue.edu/~aai/tcl8.4a4/html/TclCmd/fconfigure.htm#M20
        atCommandMode = "9600,n,8,1";

        modemInitExpectScript = pkgs.writeText "modem.exp" ''
          #!/usr/bin/env expect
          log_user 0
          set timeout 3
          set dev [lindex $argv 0]
          set mode [lindex $argv 1]
          set portId [open $dev r+]

          # Configure the port with the baud rate.
          # Don't block on read, don't buffer output.
          fconfigure $portId -mode $mode -blocking 0
          spawn -noecho -open $portId

          # Escapes regex chars.
          proc reEscape {str} {
            regsub -all {\W} $str {\\&}
          }

          # Runs an AT command.
          proc AT args {
            set cmd "AT"

            foreach arg $args {
              if {$arg != ""} {
                set cmd "$cmd$arg"
              }
            }

            set escaped [reEscape $cmd]
            set result "<TIMEOUT>"

            send_user -- "-> $cmd\n"
            send -- "$cmd\r"
            expect {
              -re "$escaped\r\r\n(.+)\r\n" {
                set result [string trim $expect_out(1,string)]
              }
              timeout {}
            }

            # Format the output.
            set formatted $result
            if {[regexp {\r|\n} $formatted]} {
              set formatted [regsub -all {(?n)^} $formatted {  }]
              set formatted "\[\n$formatted\n\]"
            }
            set formatted [regsub -all {(?n)^} $formatted {<- }]
            send_user -- "$formatted\n"
            return $result
          }

          # Startup procedure in `https://sixfab.com/wp-content/uploads/2020/11/Quectel_LTE_Standard_GNSS_Application_Note_V1.2.pdf`:
            AT
          # End any GPS sessions
            AT {+QGPSEND}
          # Query config
            AT {+QGPSCFG=?}
          # Output over USB
            AT {+QGPSCFG="outport","usbnmea"}
          # Should be default, all NMEA sentences for GPS
            AT {+QGPSCFG="gpsnmeatype",31}
          # 1 Hz fix frequency
            AT {+QGPSCFG="fixfreq",1}
          # Start GPS
            AT {+QGPS=1}
        '';

        modemInitWrapper = pkgs.writeShellScript "modem-init" ''
          set -euo pipefail
          if [ $# -ne 2 ]; then
            echo "$0: usage: $0 [AT serial device] [mode]" >&2
            exit 1
          fi

          device="$1"
          mode="$2"

          # We need to activate the USB serial drivers on the modem first:
          tries=0
          max_tries=3
          while [ ! -c "$device" ] && [ $tries -lt $max_tries ]; do
            ${pkgs.kmod}/bin/modprobe option
            echo 0x5c6 0x90b3 > /sys/bus/usb-serial/drivers/option1/new_id
            tries=$((tries+1))
            sleep 1
          done
          exec ${pkgs.expect}/bin/expect ${modemInitExpectScript} "$device" "$mode"
        '';
      in "+${modemInitWrapper} ${atCommandDevice} ${atCommandMode}";
    };
  };

  services = {
    udev.extraRules = ''
      # Restart the supplicant and network-addresses if we get a hotplug.
      SUBSYSTEM=="net", KERNEL=="${wlan}", TAG+="systemd", \
        ENV{SYSTEMD_WANTS}+="hostapd.service", ENV{SYSTEMD_WANTS}+="network-addresses-${wlan}.service"
      SUBSYSTEM=="net", KERNEL=="${wwan}", TAG+="systemd", \
        ENV{SYSTEMD_WANTS}+="wpa_supplicant-${wwan}.service", ENV{SYSTEMD_WANTS}+="network-addresses-${wwan}.service"
    '';

    acpid = {
      enable = true;
    };

    ntp = {
      enable = true;
      servers = [ "10.6.0.1" ];
      extraConfig = ''
        # GPS Serial data reference
        server 127.127.28.0 minpoll 4 maxpoll 4
        fudge 127.127.28.0 time1 0.0 refid GPS

        # GPS PPS reference
        server 127.127.28.1 minpoll 4 maxpoll 4 prefer
        fudge 127.127.28.1 refid PPS
      '';
    };

    hostapd = {
      enable = true;
      radios.${wlan} = {
        countryCode = "US";
        band = "2g";
        channel = 8;
        wifi6.enable = true;
        networks.${wlan} = {
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
            "arena"
          ];

          # Retry the socket binding until we're bound. Give up after 5 minutes.
          service-sockets-max-retries = 60;
          service-sockets-retry-wait-time = 5000;
        };

        subnet4 = [
          {
            inherit (arena) subnet id;
            pools = [ {
              pool = "${arena.dhcpStart} - ${arena.dhcpEnd}";
            } ];
            ddns-qualifying-suffix = "${arena.dhcpDomain}.";
            option-data = [ {
              name = "routers";
              data = arena.address;
              always-send = true;
            } {
              name = "domain-name-servers";
              data = arena.address;
              always-send = true;
            } {
              name = "domain-name";
              data = arena.dhcpDomain;
              always-send = true;
            } ];
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
          ddns-domains = [ {
            name = "${domain}.";
            key-name = "dc-nixos-lv-key";
            dns-servers = [ {
              ip-address = "127.0.0.1";
              port = 53535;
            } ];
          } ];
        };
        tsig-keys = [
          {
            name = "dc-nixos-lv-key";
            algorithm = "HMAC-SHA256";
            secret-file = "/etc/kea/tsig.key";
          }
        ];
      };
    };

    knot = let
      zone = pkgs.writeTextDir "${baseDomain}.zone" ''
        @ SOA ns noc.${baseDomain} 1 86400 7200 3600000 172800
        @ NS nameserver
        nameserver A 127.0.0.1
        ${config.networking.hostName}.${arena.dhcpDomain}. A ${arena.address}
        ${config.networking.hostName}.cache.${baseDomain}. CNAME ${config.networking.hostName}.${arena.dhcpDomain}.
      '';
      zonesDir = pkgs.buildEnv {
        name = "knot-zones";
        paths = [ zone ];
      };
    in {
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
          dc-nixos-lv-acl = {
            key = "dc-nixos-lv-key";
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
            acl = ["dc-nixos-lv-acl"];
          };
        };
      };
    };

    kresd = { /* knot resolver daemon */
      enable = true;
      package = pkgs.knot-resolver.override { extraFeatures = true; };
      listenPlain = [ "${arena.address}:53" "127.0.0.1:53" "[::1]:53" ];
      extraConfig = ''
        cache.size = 32 * MB

        -- Uncomment for a LOT of logging.
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
        subnets = { '${arena.subnet}', '127.0.0.0/8' }
        for i, v in ipairs(subnets) do
          view:addr(v, function(req, qry) return policy.PASS end)
        end

        -- Drop everything that hasn't matched
        view:addr('0.0.0.0/0', function (req, qry) return policy.DROP end)

        -- We are responsible for these.
        our_domains = {
          'vivec.cache.nixos.lv.'
        }
        policy:add(policy.domains(policy.STUB('127.0.0.1@53535'), policy.todnames(our_domains)))

        -- Forward requests for the local DHCP domains.
        local_domains = { 'arena.${domain}' }
        for i, v in ipairs(local_domains) do
          policy:add(policy.suffix(policy.FORWARD({'127.0.0.1@53535'}), {todname(v)}))
        end

        -- Route upstream, over the meshes
        policy:add(policy.suffix(policy.STUB('10.5.0.1@53'), {todname('.')}))
        policy:add(policy.suffix(policy.STUB('10.6.6.6@53'), {todname('.')}))

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
        "${config.networking.hostName}.cache.${baseDomain}" = {
          servers = {
            "localhost:8501" = { };
          };
        };
      };

      virtualHosts = {
        "${config.networking.hostName}.cache.${baseDomain}" = {
          http2 = true;
          locations."/".proxyPass = "http://${config.networking.hostName}.cache.${baseDomain}";
        };
      };
    };

    # We have ~2 TB of storage, use 3/4 of it for local cache
    ncps.cache.maxSize = "1500G";
  };

  systemd.services.kea-dhcp4-server.partOf = [ "hostapd.service" ];

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = "25.05"; # Did you read the comment?

  nixpkgs.system = "x86_64-linux";
}
