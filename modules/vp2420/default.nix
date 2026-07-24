# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).
{
  config,
  pkgs,
  lib,
  modulesPath,
  ...
}:

let
  baseDomain = "nixos.lv";
  domain = "dc.${baseDomain}";

  # Shared event-router helpers (kea/knot/kresd builders).
  erlib = import ../event-router/lib.nix { inherit lib pkgs; };

  thisHost = config.networking.mesh.plan.hosts.${config.networking.hostName};

  brassNebula = config.networking.mesh.plan.hosts.brass.nebula.address;
  ghostgateMesh = lib.head (
    lib.splitString "/" config.networking.mesh.plan.hosts.ghostgate.wifi.address
  );

  # Nebula tun interface — traffic arriving here is already CA-authenticated
  # by nebula, so we trust it like the LAN/mesh.
  nebulaTun = config.services.nebula.networks.arena.tun.device;

  # WWAN (internal modem)
  wwan = "wlp0s20f0u3";
  # mt76x0u on external USB-A (lower)
  wlan = "wlp0s20f0u2";
  # mt76x2u on internal M.2
  internalM2Wifi = "wlp0s20f0u4";
  # mt76x2u on external USB-A (upper)
  mon = "wlp0s20f0u7";

  # Attendee network. Base/id come from the fleet arena map (arena-hosts.nix),
  # keyed by this host's name.
  arena = erlib.mkArena {
    self = config.networking.hostName;
    inherit domain;
  };

  # Attendee-AP 5GHz channel, per box. Kept in UNII-3 (149-165), clear of the
  # 802.11s mesh backhaul, which runs 80MHz across the whole UNII-1 block
  # (36-48) — the AP used to sit on ch40 *inside* that block and fight this
  # box's own backhaul. 40MHz uses HT40+ (each control channel is the lower of
  # its pair: 149+153, 157+161). Only two clean non-DFS 40MHz blocks exist up
  # here, so co-located boxes get distinct ones; seht is off-site right now and
  # reuses ayem's (RF-separated). Revisit if seht returns to the same hall.
  apChannel =
    {
      ayem = 149;
      vehk = 157;
      seht = 149;
    }
    .${config.networking.hostName} or 149;
in
{
  imports = [
    ../event-router/common.nix
    ../harmonia-cache.nix
    ../citadel-builder.nix
    ../pxe.nix
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "usbhid"
    "usb_storage"
    "sd_mod"
    "sdhci_pci"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [
    "kvm-intel"
    "option"
  ];
  boot.extraModulePackages = [ ];

  fileSystems."/nix" = lib.mkForce {
    device = "${config.networking.hostName}/local/nix";
    fsType = "zfs";
  };

  fileSystems."/home" = lib.mkForce {
    device = "${config.networking.hostName}/user/home";
    fsType = "zfs";
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  boot.kernelParams = [
    "console=tty0"
    "console=ttyS0,115200n8"
  ];

  services.gpsd =
    let
      nmeaDevice = "/dev/serial/by-id/usb-Qualcomm_MDG200-if02-port0";
    in
    {
      enable = true;
      nowait = true;
      devices = lib.singleton nmeaDevice;
      # 9600-8-N-1
      extraArgs = [
        "-s"
        "9600"
        "-f"
        "8N1"
      ];
    };

  # Try to save power since these machines are usually on battery
  powerManagement.cpuFreqGovernor = "powersave";

  networking.hosts = {
    # We get to lv over 802.11s
    "${ghostgateMesh}" = [ "cache.nixos.lv" ];
  };

  # Patched stream-through harmonia edge cache (shared module:
  # modules/harmonia-cache.nix). Upstream is cache.nixos.lv, which resolves to
  # ghostgate via the /etc/hosts entry above — so a miss hops this box ->
  # ghostgate (dedup'd store) -> internet, and never loops back on itself.
  nixVegas.harmoniaCache = {
    enable = true;
    upstreamUrl = "https://cache.nixos.lv";
  };

  # PXE/iPXE netboot server (shared module: modules/pxe.nix). Unlike ghostgate,
  # each 2420 serves the artifacts locally: iPXE is handed this box's own arena
  # IP, so the kernel/initrd ride the local arena link rather than the mesh.
  # serveArtifacts adds the default :80 vhost that answers that by-IP request.
  nixVegas.pxe = {
    enable = true;
    ipxeScriptUrl = "http://${arena.address}/boot/menu.ipxe";
    serveArtifacts = true;
  };

  # This box's own nix client substitutes from ghostgate (cache.nixos.lv), NOT
  # from its own local harmonia. harmonia serves *this box's* /nix/store and
  # add_to_store_nar's fetched paths back into it; if the local client also
  # substituted from it, the client's import and harmonia's store-write race for
  # the same store-path lock and deadlock. Point the client at ghostgate's
  # harmonia (a *different* store), which pulls through to cache.nixos.org there.
  # mkForce past MeshOS to keep it explicit.
  nix.settings.substituters = lib.mkForce [
    "https://cache.nixos.lv"
  ];

  # harmonia's HTTPS vhost gets a real Let's Encrypt cert; brass forwards the
  # HTTP-01 challenge for ${hostName}.cache.nixos.lv over Nebula (devices/brass).
  security.acme = {
    acceptTerms = true;
    defaults.email = "noc@nix.vegas";
  };

  networking.mesh = {
    wifi = {
      enable = true;
      countryCode = "US";
      dedicatedWifiDevices = lib.mkDefault [ internalM2Wifi ];
      useForFallbackInternetAccess = true;
      # 20/30 under ideal conditions over 4G, hotel wifi limited to
      # 50, let's just call it 50 for BATMAN throughput estimation purposes
      # Usually these will be close, so go 100
      advertisedUploadMbps = 100;
      advertisedDownloadMbps = 100;
    };
    nebula = {
      enable = true;
      networkName = "arena";
      tpm2Key = true;
    };
    cache = {
      # ncps retired in favor of the patched stream-through harmonia
      # (nixVegas.harmoniaCache below). server.enable = false so MeshOS stops
      # running ncps and stops force-pointing our client at localhost:8501; we
      # front harmonia ourselves and point this box's own client at it (see
      # nix.settings.substituters).
      server = {
        enable = false;
      };
      client = {
        enable = true;
        useHydra = false;
        # harmonia stream-through preserves the upstream (cache.nixos.org)
        # signature on pass-through NARs, so keep that key trusted rather than
        # letting MeshOS mkForce trusted-public-keys to [].
        trustHydra = true;
        useRecommendedCacheSettings = true;
      };
    };
    ieee80211s.networks.mesh2.metric = 1001;
  };

  services.nebula.networks.arena = {
    tun.device = lib.mkForce "nebula.arena";
    # Full-mesh inter-arena routing: reach every other router's arena LAN over
    # Nebula (cert-authorized). Kernel routes are installed in the postStart
    # below (table arena), so install = false here.
    # Attendee internet exits at the fleet Nebula endpoint (brass); inter-arena
    # goes direct to the peer routers.
    settings.tun.unsafe_routes = [
      (erlib.arenaDefaultRoute { planHosts = config.networking.mesh.plan.hosts; })
    ]
    ++ erlib.arenaUnsafeRoutes {
      self = config.networking.hostName;
      planHosts = config.networking.mesh.plan.hosts;
    }
    # Reach the CTF backbone (behind ghostgate) so attendees can hit challenge VMs.
    ++ [ (erlib.ctfUnsafeRoute { planHosts = config.networking.mesh.plan.hosts; }) ]
    # Reach the build net (citadel, the remote builder) behind ghostgate the same
    # way, so this box — and its attendee arena — can offload builds.
    ++ [ (erlib.buildUnsafeRoute { planHosts = config.networking.mesh.plan.hosts; }) ];

    # Relays are driven by mesh.nix: brass is the sole lighthouse+relay, so
    # every node gets `relays = [brass]` automatically. A single relay removes
    # the fan-out churn entirely — a peer's handshake no longer arrives via
    # multiple relay paths at once, so collision-resolution can't thrash.

    # NOTE: `preferred_ranges = [ wifi.subnet ]` (prefer the 802.11s mesh) is
    # intentionally NOT set. Forcing the mesh while its RF is marginal pins
    # Nebula to a flapping path and makes it thrash instead of falling back to a
    # relay. Re-enable only once the mesh underlay is consistently healthy (~1ms).

    # Constrain Nebula underlay address discovery. These are multi-homed
    # routers; without this each advertises (and tries peers on) every internal
    # interface. The Nebula overlay (10.6) and the arena LANs (10.7/10.8) are
    # routed *over* Nebula, so a handshake aimed at such an address loops back
    # into the tun and never completes. Exclude the overlay + routed arena
    # aggregates in both directions; the WiFi mesh (10.5, a real low-latency
    # underlay), the WAN and public addresses stay usable.
    settings.lighthouse =
      let
        deny = builtins.listToAttrs (
          map (c: lib.nameValuePair c false) (
            [
              config.networking.mesh.plan.constants.nebula.subnet # 10.6/16 overlay
              "10.3.0.0/16" # deploy/mgmt LAN — collides across sites, never a Nebula underlay
              "192.168.0.0/16" # stale roamed private nets
            ]
            ++ erlib.arenaAggregates # 10.7/16, 10.8/16 (routed over Nebula)
          )
        );
        allowList = deny // {
          "0.0.0.0/0" = true;
        };
      in
      {
        local_allow_list = allowList;
        remote_allow_list = allowList;
      };
  };

  # These commands will let users on DHCP get out over the LAN ports.
  systemd.services."nebula@arena".postStart = ''
    ${erlib.arenaPostStartPreamble {
      ip = lib.getExe' pkgs.iproute2 "ip";
      sleep = lib.getExe' pkgs.coreutils "sleep";
    }}
    _rule_replace from ${arena.subnet} lookup arena

    _ip route flush table arena || true

    # Let them get to the local network
    _ip route replace ${arena.subnet} dev arena table arena

    # Let them get to the mesh peers (the mesh subnet is on-link on mesh2, so
    # no `via` — that nexthop may not be resolvable when this first runs).
    _ip route replace ${config.networking.mesh.plan.constants.wifi.subnet} dev mesh2 table arena

    # Reach the other routers' arena LANs over Nebula (full mesh) — in table
    # arena for LAN clients, and in the main table so the router itself can
    # reach them too.
    ${erlib.arenaTableRoutes { }}
    ${erlib.arenaTableRoutes { table = "main"; }}
    # Reach the CTF backbone (behind ghostgate) over Nebula — table arena for LAN
    # clients, main table so the router itself can reach it.
    ${erlib.ctfTableRoutes { }}
    ${erlib.ctfTableRoutes { table = "main"; }}
    # Reach the build net (citadel) over Nebula too — arena table for LAN
    # clients, main table so the router itself can offload builds.
    ${erlib.buildTableRoutes { }}
    ${erlib.buildTableRoutes { table = "main"; }}
    # Attendee internet exits at the normal Nebula endpoint (brass): `dev
    # nebula.arena`, and Nebula's 0.0.0.0/0 unsafe_route tunnels it to brass.
    # This is underlay-agnostic — it works near ghostgate (Nebula rides the
    # mesh) and while roaming on the modem/WAN — and always stays encrypted.
    _ip route replace default dev nebula.arena table arena

    # Router's own traffic default (main table): wired WAN (dhcpcd metric 1000)
    # preferred, WiFi mesh as fallback.
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
      gps.gpsd = {
        host = "localhost";
        port = 2947;
      };
    };
  };

  # List packages installed in system profile. To search, run:/
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    wget
    vim
    curl
    git
    tmux
    psmisc
    man-pages
    htop
    perf
    iftop
    speedtest-cli
    zip
    unzip
    usbutils
    gpsd
    iw

    openssl
    firefox

    iproute2
    traceroute
    unbound
    bind
    bridge-utils
    ethtool
    tcpdump
    conntrack-tools
    nebula
  ];

  # Keep mDNS internal-only (still reachable over trustedInterfaces); avahi
  # would otherwise open 5353 on every interface.
  services.avahi.openFirewall = lib.mkForce false;

  networking = {
    nameservers = [ "127.0.0.1" ];

    nat.enable = lib.mkForce false;

    # Host input filtering is delegated to the NixOS firewall; the custom
    # nftables table below only handles routing (forward) and NAT.
    firewall = {
      enable = true;
      # Loose reverse-path filtering: attendee internet is policy-routed out
      # nebula.arena (to brass), but replies come back with an internet source
      # whose main-table route is the WAN/mesh — strict rp_filter would drop
      # them on nebula.arena. Loose only requires the source be routable at all.
      checkReversePath = "loose";
      # Internal networks (LAN, WiFi mesh, and the CA-authenticated nebula
      # tun) are fully trusted.
      trustedInterfaces = [
        "arena"
        "mesh2"
        nebulaTun
      ];
      # SSH for remote deploys over any uplink. mkForce so ports other modules
      # open globally (e.g. the ncps cache on 8501, which has no openFirewall
      # toggle) aren't exposed on the uplinks — internal clients still reach
      # them over trustedInterfaces.
      allowedTCPPorts = lib.mkForce config.services.openssh.ports;
      # ...and the Nebula transport so the overlay forms over the uplinks.
      allowedUDPPorts = [ (config.networking.mesh.plan.nebula.portFor thisHost) ];
    };

    iproute2 = {
      enable = true;
      rttablesExtraConfig = ''
        200 arena
      '';
    };

    dhcpcd = {
      allowInterfaces = [
        "wan"
        wwan
        "modem"
      ];
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
        ipv4.addresses = [
          {
            inherit (arena) address;
            prefixLength = arena.prefix;
          }
        ];
      };
    };

    bridges = {
      arena = {
        interfaces = [
          "eth0"
          "enp2s0"
          "enp3s0"
        ];
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
      # Restrict wpa_supplicant to the WWAN client radio so it doesn't try to
      # manage the hostapd AP interface (${wlan}) or the kismet monitor radio.
      interfaces = [ wwan ];
      fallbackToWPA2 = false;
      allowAuxiliaryImperativeNetworks = true;
      userControlled = true;
    };

    nftables = {
      enable = true;
      flushRuleset = true;
      tables = {
        filter = {
          family = "inet";
          content = ''
            # Host input filtering lives in the NixOS firewall
            # (networking.firewall above). This table only governs routing.
            chain forward {
              type filter hook forward priority filter; policy drop;

              # Route between arena LANs over Nebula (cert-authorized, no NAT).
              iifname "arena" oifname "${nebulaTun}" counter accept comment "arena -> nebula (inter-arena)"
              iifname "${nebulaTun}" oifname "arena" counter accept comment "nebula -> arena (inter-arena)"

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

            # Setup NAT masquerading on egress interfaces
            chain postrouting {
              type nat hook postrouting priority filter; policy accept;
              # Masquerade internet egress on the WAN only — NOT the arena LAN,
              # so inter-arena delivery keeps real source IPs.
              oifname "wan" masquerade
              # mesh2 is the Nebula *underlay*, not an internet uplink. Masquerading
              # the router's own mesh peer-to-peer traffic (10.5.x → 10.5.x, e.g.
              # Nebula handshakes to the other 2420s) collides in conntrack when
              # both peers initiate simultaneously and rewrites the source port,
              # breaking the handshake and forcing a relay fallback. Only
              # masquerade non-mesh egress here; keep mesh peer traffic untouched.
              oifname "mesh2" ip daddr != ${config.networking.mesh.plan.constants.wifi.subnet} masquerade
              # Masquerade only genuine internet egress over Nebula. Traffic to
              # other arenas, the CTF backbone, OR Nebula hosts (e.g. a router's
              # own Nebula IP, as when pinging from the box) keeps its real source
              # so replies match conntrack and the CTF sees real attendee IPs.
              oifname "${nebulaTun}" ip daddr != { ${
                lib.concatStringsSep ", " (
                  erlib.arenaCidrs
                  ++ [
                    config.networking.mesh.plan.constants.nebula.subnet
                    erlib.ctfNet
                  ]
                )
              } } masquerade
            }
          '';
        };
      };
    };
  };

  systemd = {
    network.wait-online.enable = false;

    # Make boot snappier.
    settings.Manager.DefaultDeviceTimeoutSec = 15;

    services = {
      # HACK to support pluggable devices: https://github.com/NixOS/nixpkgs/pull/155017
      "wpa_supplicant-${wwan}" = {
        # Don't block boot ~15s waiting for this pluggable WWAN dongle: drop the
        # multi-user.target pull (which Requires the device unit) so the
        # supplicant is started only by the udev rule below (SYSTEMD_WANTS) when
        # the device is actually present.
        wantedBy = lib.mkForce [ ];
        serviceConfig = {
          Restart = "always";
          RestartSec = 15;
        };
      };

      # Allow this to exist independently of device status
      "network-addresses-${wwan}".bindsTo = lib.mkForce [ ];

      # Protectli devices have a serial console, enable it despite being otherwise headless.
      "serial-getty@ttyS0".enable = true;

      # Initialize the GPS using AT commands on the modem.
      "gpsd".serviceConfig.ExecStartPre =
        let
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
        in
        "+${modemInitWrapper} ${atCommandDevice} ${atCommandMode}";
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

    ntp = {
      enable = true;
      servers = [ ghostgateMesh ];
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
        band = "5g";
        channel = apChannel;
        # 40MHz: HT40+ (secondary channel above the primary), with VHT/HE riding
        # on top. operatingChannelWidth "20or40" is the 40MHz setting (0); bump
        # wifi5/wifi6 to "80" here if a box is RF-isolated and wants VHT80.
        wifi4 = {
          enable = true;
          capabilities = [ "HT40+" ];
        };
        wifi5 = {
          enable = true;
          operatingChannelWidth = "20or40";
        };
        wifi6 = {
          enable = true;
          operatingChannelWidth = "20or40";
        };
        networks.${wlan} = {
          ssid = "NixVegas_${config.networking.hostName}";
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

          # The arena bridge may have no carrier at boot (nothing plugged in
          # yet, AP not up), so the raw socket can't open ("interface isn't
          # running"). Don't require it up front, and keep retrying effectively
          # forever so kea binds as soon as the interface is running instead of
          # giving up and needing a manual restart.
          service-sockets-require-all = false;
          service-sockets-max-retries = 1000000;
          service-sockets-retry-wait-time = 5000;
        };

        subnet4 = [
          (erlib.mkDhcp4Subnet {
            net = arena;
            ntp = false;
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
        keyName = "dc-nixos-lv-key";
        zoneName = domain;
      };
    };

    knot = erlib.mkKnot {
      inherit baseDomain;
      aclName = "dc-nixos-lv-acl";
      keyName = "dc-nixos-lv-key";
      zoneText = ''
        @ SOA ns noc.${baseDomain} 1 86400 7200 3600000 172800
        @ NS nameserver
        nameserver A 127.0.0.1
        ${config.networking.hostName}.${arena.dhcpDomain}. A ${arena.address}
        ${config.networking.hostName}.cache.${baseDomain}. CNAME ${config.networking.hostName}.${arena.dhcpDomain}.
      '';
    };

    kresd = {
      # knot resolver daemon
      enable = true;
      package = pkgs.knot-resolver_5.override { extraFeatures = true; };
      listenPlain = [
        "${arena.address}:53"
        "127.0.0.1:53"
        "[::1]:53"
      ];
      extraConfig = erlib.mkKresdExtraConfig {
        # Synthesize <host>.nebula.arena.nixos.lv A hints from the plan.
        planHosts = config.networking.mesh.plan.hosts;
        subnets = [
          arena.subnet
          "127.0.0.0/8"
        ];
        ourDomains = [ "${config.networking.hostName}.cache.nixos.lv." ];
        localDomains = [ "arena.${domain}" ];
        localForward = true;
        # Split-horizon: resolve ctf.nixos.lv via ghostgate (-> the internal CTF
        # server, citadel) instead of the public front, so this arena's players
        # reach the CTF directly over the arena -> ctf path.
        forwardZones = [
          {
            domain = "ctf.nixos.lv.";
            server = "${ghostgateMesh}@53";
          }
        ];
        upstreams = [
          "${ghostgateMesh}@53"
          "${brassNebula}@53"
        ];
        # nixc.tf -> the internal CTF server for this arena; public stays brass.
        hints = {
          "nixc.tf" = erlib.ctfServer;
          "www.nixc.tf" = erlib.ctfServer;
        };
      };
    };

    nginx = {
      enable = true;

      # Front the local stream-through harmonia edge cache. addSSL (not
      # forceSSL): a plugged-in client can hit http:// directly — it's a local
      # link and NARs are signed — while https:// also works. The cert comes
      # from ACME, with brass forwarding the HTTP-01 challenge for this name
      # (see devices/brass: the SNI-passthrough cacheBackends entry).
      virtualHosts = {
        "${config.networking.hostName}.cache.${baseDomain}" = {
          http2 = true;
          enableACME = true;
          addSSL = true;
          locations."/".proxyPass = "http://[::1]:5000";
        };
      };
    };
  };

  systemd.services.kea-dhcp4-server.partOf = [ "hostapd.service" ];

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = lib.mkDefault "25.05"; # Did you read the comment?

  nixpkgs.system = "x86_64-linux";
}
