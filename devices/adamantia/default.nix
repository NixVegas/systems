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
  nebulaEgress = "185.193.48.236";
  nebulaSubnet = config.networking.mesh.plan.constants.nebula.subnet;
in
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../../modules/swap.nix
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
    systemd-boot.enable = false;
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
    git htop nebula
  ];

  networking =
    let
      egress = "ens3";
    in
    {
      hostName = "adamantia";

      defaultGateway = {
        address = "151.236.16.1";
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
              address = "151.236.16.225";
              prefixLength = 24;
            }
            {
              address = "151.236.16.78";
              prefixLength = 24;
            }
            {
              address = "185.193.48.236";
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
              address = "2605:3b80:111:163e::1";
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
        allowedUDPPorts = [ 53 ];
        interfaces.arena = {
          allowedTCPPorts = [ 1935 ];
          allowedUDPPorts = [ 1935 ];
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
    avahi.enable = false;
    openntpd = {
      enable = true;
      servers = [
        "time.nist.gov"
        "pool.ntp.org"
      ];
      extraConfig = ''
        listen on ${nebulaIp}
      '';
    };
    unbound =
      let
        yes = "yes";
        no = "no";
        makeLocalData = data: map (x: "\"${x}\"") data;
        extraHosts = pkgs.stdenv.mkDerivation {
          name = "unbound-extra-hosts.conf";
          src = pkgs.writeText "extra-hosts" config.networking.extraHosts;
          phases = [ "installPhase" ];
          installPhase = ''
            ${pkgs.gawk}/bin/awk '{sub(/\r$/,"")} {sub(/^127\.0\.0\.1/,"0.0.0.0")} BEGIN { OFS = "" } NF == 2 && $1 == "0.0.0.0" { print "local-zone: \"", $2, "\" static"}' $src | tr '[:upper:]' '[:lower:]' | sort -u >  $out
          '';
        };

        coreNebulaIp = config.networking.mesh.plan.hosts."adamantia".nebula.address;
        onsiteNebulaIp = config.networking.mesh.plan.hosts."ghostgate".nebula.address;
      in
      {
        enable = true;
        settings.server = {
          # Listen on all interfaces, and allow access from Nebula-related routes.
          interface = [ "0.0.0.0" ];
          access-control = map (subnet: "${subnet} allow") (
            lib.singleton "127.0.0.0/8" ++ config.networking.mesh.plan.nebula.routes
          );

          # Domains that should be allowed to respond with private ranges.
          private-domain = [
            "nixos.lv."
          ];

          # "Private" IP ranges. We're sticking with RFC 1918 for now.
          private-address = [
            "10.0.0.0/8"
            "172.16.0.0/12"
            "192.168.0.0/16"
            "169.254.0.0/16"
          ];

          # Unbound hardening settings
          cache-max-ttl = 14400;
          cache-min-ttl = 300;
          hide-identity = yes;
          hide-version = yes;
          identity = "DNS";
          minimal-responses = yes;
          prefetch = yes;
          prefetch-key = yes;
          qname-minimisation = yes;
          rrset-roundrobin = yes;
          use-caps-for-id = yes;
          aggressive-nsec = yes;
          delay-close = 10000;
          val-clean-additional = yes;
          serve-expired = yes;
          so-reuseport = yes;
          harden-short-bufsize = yes;
          harden-glue = yes;
          harden-large-queries = yes;
          harden-dnssec-stripped = yes;
          harden-below-nxdomain = yes;
          harden-algo-downgrade = yes;
          deny-any = yes;

          local-data = makeLocalData [
            "nixos.lv. IN A ${onsiteNebulaIp}"
            "arena.nixos.lv. IN A ${coreNebulaIp}"
            "live.nix.vegas. IN A ${coreNebulaIp}"
            "live.nixos.lv. IN A ${coreNebulaIp}"
            "adamantia.arena.nixos.lv. IN A ${coreNebulaIp}"
            "ntp.arena.nixos.lv. IN A ${coreNebulaIp}"
            "cache.nixos.lv. IN CNAME cache.dc.nixos.lv."
            "cache.dc.nixos.lv. IN A ${onsiteNebulaIp}"
          ];

          # Includes
          include = [ "${extraHosts}" ];
        };

        # Forward zones
        settings.forward-zone = [
          {
            name = "dc.nixos.lv.";
            forward-addr = [ onsiteNebulaIp ];
          }
          {
            name = ".";
            forward-addr = config.networking.nameservers;
          }
        ];
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
          "ghostgate.dc.nixos.lv" = {
            servers = {
              ${config.networking.mesh.plan.hosts.ghostgate.nebula.address} = { };
            };
          };
        };

        virtualHosts = let
          proxyLetsEncrypt = upstream: options: lib.recursiveUpdate {
            locations."/" = {
              extraConfig = "empty_gif;";
            };
            locations."/.well-known/acme-challenge" = {
              proxyPass = "http://${upstream}";
            };
          } options;
        in {
          "nixos.lv" = proxyLetsEncrypt "ghostgate.dc.nixos.lv" { };
          "cache.nixos.lv" = proxyLetsEncrypt "ghostgate.dc.nixos.lv" { };
        };
      };
  };

  nixpkgs.system = "x86_64-linux";

  system.stateVersion = "25.05";
}
