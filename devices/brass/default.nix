{
  lib,
  config,
  pkgs,
  modulesPath,
  ...
}:

let
  myHost = config.networking.mesh.plan.hosts.${config.networking.hostName};
  nebulaIp = myHost.nebula.address;
  nebulaIngress = lib.findFirst (lib.strings.hasInfix ".") null myHost.nebula.entryAddresses;
  nebula6Ingress = lib.findFirst (lib.strings.hasInfix ":") null myHost.nebula.entryAddresses;

  publicIpv4 = nebulaIngress;
  publicIpv6 = nebula6Ingress;
  nebulaEgress = "188.190.9.32";

  nebulaSubnet = config.networking.mesh.plan.constants.nebula.subnet;

  erlib = import ../../modules/event-router/lib.nix { inherit lib pkgs; };

  # Public TLS-passthrough ingress. brass has the public IP; each name's TLS and
  # ACME are handled by the backend that owns it — brass just SNI-routes :443 and
  # forwards :80 so the backends' HTTP-01 challenges land.
  ghostgateNebula = config.networking.mesh.plan.hosts.ghostgate.nebula.address;
  citadelCtf = "10.4.2.2"; # citadel's pinned ctf reservation
  passthrough = {
    "nixc.tf" = citadelCtf;
    "ctf.nixos.lv" = citadelCtf;
    "ctf.nix.vegas" = citadelCtf;
    "cache.nixos.lv" = ghostgateNebula;
    "cache.nix.vegas" = ghostgateNebula;
    "nixos.lv" = ghostgateNebula;
  };
in
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../../modules/swap.nix
    ../../modules/unbound.nix
  ];

  boot = {
    initrd.availableKernelModules = [
      "ata_piix"
      "uhci_hcd"
      "virtio_pci"
      "sr_mod"
      "virtio_blk"
    ];
  };

  boot.kernel.sysctl = {
    "net.ipv4.conf.all.forwarding" = true;
    "net.ipv6.conf.all.forwarding" = true;
  };

  boot.loader = {
    limine.enable = false;
    grub = {
      enable = true;
      device = "/dev/vda";
    };
  };

  boot.zfs = {
    forceImportRoot = true;
    devNodes = "/dev/disk/by-partlabel";
  };

  environment.systemPackages = with pkgs; [
    git
    htop
    nebula
    openssl
    net-tools
  ];

  networking =
    let
      egress = "ens3";
    in
    {
      hostName = "brass";

      defaultGateway = {
        address = "185.193.48.1";
        interface = egress;
      };
      defaultGateway6 = {
        address = "2605:3b80:111::1";
        interface = egress;
      };
      interfaces.${egress} = {
        useDHCP = false;
        ipv4 = {
          addresses = [
            {
              address = publicIpv4;
              prefixLength = 24;
            }
          ];
          routes = [
            {
              address = "151.236.16.0";
              prefixLength = 24;
            }
          ];
        };
        ipv6 = {
          addresses = [
            {
              address = publicIpv6;
              prefixLength = 64;
            }
          ];
        };
      };
      nameservers = [
        "1.1.1.1"
        "1.0.0.1"
        "2606:4700:4700::1111"
        "2606:4700:4700::1001"
      ];
      mesh = {
        nebula = {
          enable = true;
          networkName = "arena";
        };
      };

      firewall = {
        enable = true;
        allowPing = true;
        allowedTCPPorts = [
          22
          80
          443
        ];
        allowedUDPPorts = [
          53
          5000
        ];
        interfaces.arena = {
          allowedTCPPorts = [ 1935 ];
          allowedUDPPorts = [
            1935
            5000
          ];
        };
      };
      nat = {
        enable = true;
        extraCommands = ''
          # Flush tables for redeploy.
          iptables -t nat -F

          # NAT gateway for Nebula hosts
          iptables -I FORWARD -s ${nebulaSubnet} -d 0.0.0.0/0 -j ACCEPT
          iptables -t nat -I POSTROUTING -s ${nebulaSubnet} -j MASQUERADE

          # Redirect anything from Nebula and destined for external IPs internal
          iptables -t nat -I PREROUTING -s ${nebulaSubnet} -d ${nebulaIngress} -j REDIRECT
          iptables -t nat -I PREROUTING -s ${nebulaSubnet} -d ${nebulaEgress} -j REDIRECT

          # Redirect Nebula DNS and NTP queries
          iptables -t nat -I PREROUTING -p udp -s ${nebulaSubnet} --dport 53 -j REDIRECT
          iptables -t nat -I PREROUTING -p udp -s ${nebulaSubnet} --dport 123 -j REDIRECT
        '';
      };
    };

  services = {
    owncast = {
      enable = true;
    };

    nginx = {
      enable = true;

      recommendedTlsSettings = true;
      recommendedGzipSettings = true;
      recommendedBrotliSettings = true;
      recommendedProxySettings = true;
      recommendedUwsgiSettings = true;
      recommendedOptimisation = true;

      upstreams = {
        "owncast" = {
          servers = {
            "localhost:${toString config.services.owncast.port}" = { };
          };
        };
      };

      # brass's own TLS vhosts terminate here, but behind the SNI router on
      # :8443 (the router's `default`). Public :443 is the passthrough router.
      defaultSSLListenPort = 8443;

      virtualHosts =
        {
          # In case they go here...
          "live.nixos.lv" = {
            forceSSL = true;
            enableACME = true;
            globalRedirect = "live.nix.vegas";
          };

          # We redirect them here.
          "live.nix.vegas" = {
            forceSSL = true;
            enableACME = true;
            locations."/" = {
              proxyPass = "http://owncast";
              proxyWebsockets = true;
            };
          };
        }
        # Passed-through names get a plain :80 vhost forwarding to the backend,
        # so the backend's ACME HTTP-01 challenge lands and its own http->https
        # redirect is served. Their TLS (:443) is SNI-passed-through below.
        // lib.mapAttrs (_: be: {
          locations."/".proxyPass = "http://${be}";
        }) passthrough;

      # L4 SNI router on :443: pass each name through to the backend that owns
      # its cert; everything else (owncast/live) to brass's local nginx on :8443.
      streamConfig = ''
        map $ssl_preread_server_name $tls_upstream {
          hostnames;
        ${lib.concatStrings (lib.mapAttrsToList (sni: be: "  ${sni} ${be}:443;\n") passthrough)}  default 127.0.0.1:8443;
        }
        server {
          listen 443 reuseport;
          listen [::]:443 reuseport;
          proxy_pass $tls_upstream;
          ssl_preread on;
        }
      '';

      appendHttpConfig = ''
        geo $source {
          default public;
          ${nebulaSubnet} nebula;
        }
      '';
    };
  };

  # Reach the internal CTF backbone (citadel) over Nebula via ghostgate, so the
  # ctf.nixos.lv front above can proxy to it. Requires ghostgate's Nebula cert to
  # authorize 10.4.2.0/24.
  services.nebula.networks.arena = {
    tun.device = lib.mkForce "nebula.arena";
    settings.tun.unsafe_routes = [
      (erlib.ctfUnsafeRoute { planHosts = config.networking.mesh.plan.hosts; })
    ];
  };
  # Nebula won't install a `via <peer>` route (the peer isn't on-link on the
  # tun), so add the route by device; the unsafe_route above directs it to
  # ghostgate.
  systemd.services."nebula@arena".postStart = ''
    ${lib.getExe' pkgs.iproute2 "ip"} route replace ${erlib.ctfNet} dev nebula.arena || true
  '';

  security.acme = {
    acceptTerms = true;
    defaults.email = "noc@nix.vegas";
  };

  nixpkgs.system = "x86_64-linux";
}
