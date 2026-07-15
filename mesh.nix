{ ... }:

{
  networking.mesh.plan = {
    hosts = {
      adamantia =
        let
          entryAddress = "151.236.16.185";
          entry6Address = "2605:3b80:111:584e::1";
        in
        {
          dns = {
            addresses = {
              ${entryAddress} = [ "adamantia.arena.nixos.lv" ];
              ${entry6Address} = [ "adamantia.arena6.nixos.lv" ];
            };
          };
          nebula = {
            address = "10.6.6.6";
            entryAddresses = [
              entryAddress
              entry6Address
            ];
            port = 5000;
            # Single-lighthouse topology: brass is the sole lighthouse+relay.
            isLighthouse = false;
            isRelay = false;
            defaultRouteMetric = 2010;
          };
          ssh.hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGdx91MTYIyUYNxALvGeMkke3fPRxvOEzVdy2cDa8tbh root@adamantia";
        };

      brass =
        let
          entryAddress = "185.193.48.248";
          entry6Address = "2605:3b80:111:1ca8::1";
        in
        {
          dns = {
            addresses = {
              ${entryAddress} = [ "brass.arena.nixos.lv" ];
              ${entry6Address} = [ "brass.arena6.nixos.lv" ];
            };
          };
          nebula = {
            address = "10.6.6.7";
            entryAddresses = [
              entryAddress
              entry6Address
            ];
            port = 5000;
            isLighthouse = true;
            isRelay = true;
            defaultRouteMetric = 2010;
          };
          ssh.hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIDcupelpHeFAxV0MCb+/w8GVpDQO4LOZdI+EBS8qZIi root@brass";
        };

      crystal =
        let
          entryAddress = "151.236.16.132";
          entry6Address = "2605:3b80:111:dee::1";
        in
        {
          dns = {
            addresses = {
              ${entryAddress} = [ "crystal.arena.nixos.lv" ];
              ${entry6Address} = [ "crystal.arena6.nixos.lv" ];
            };
          };
          nebula = {
            address = "10.6.6.8";
            entryAddresses = [
              entryAddress
              entry6Address
            ];
            port = 5000;
            # Single-lighthouse topology: brass is the sole lighthouse+relay.
            isLighthouse = false;
            isRelay = false;
            defaultRouteMetric = 2010;
          };
          ssh.hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGVGgBekGF8jkxkmHBYyNINkQb8/PtsleneLaOU7MnEq root@crystal";
        };

      dagoth =
        let
          entryAddress = "151.236.16.241";
          entry6Address = "2605:3b80:111:35e1::1";
        in
        {
          dns = {
            addresses = {
              ${entryAddress} = [ "dagoth.arena.aurb.is" ];
              ${entry6Address} = [ "dagoth.arena6.aurb.is" ];
            };
          };
          nebula = {
            address = "10.6.6.9";
            entryAddresses = [
              entryAddress
              entry6Address
            ];
            port = 4200;
            # Single-lighthouse topology: brass is the sole lighthouse+relay.
            isLighthouse = false;
            isRelay = false;
            defaultRouteMetric = 2020;
          };
          ssh = {
            hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFjuHts+xrtY/osQ5ARHd0sOYjGv5y+LYhoiq6tsxkb7 root@dagoth";
            port = 42070;
          };
        };


      ghostgate =
        let
          entryAddressBuild = "10.4.1.1";
          entryAddressMesh = "10.5.0.1";
        in
        {
          dns = {
            addresses = {
              ${entryAddressBuild} = [ "ghostgate.build.dc.nixos.lv" ];
              # Also advertise the mesh address so mesh peers (the VP2420s) get
              # it in their Nebula static host map — without this they only know
              # ghostgate at its build-net address, which they can't reach.
              ${entryAddressMesh} = [ "ghostgate.mesh.dc.nixos.lv" ];
            };
          };
          wifi.address = "10.5.0.1/16";
          nebula = {
            address = "10.6.7.1";
            entryAddresses = [
              entryAddressBuild
              entryAddressMesh
            ];
            # Not a lighthouse/relay: ghostgate has no stable public address, so
            # as a lighthouse its dynamic location was never reported to the
            # cloud lighthouses — a roaming 2420 only had ghostgate's (internal)
            # static addresses and nothing to relay toward. As a regular node it
            # checks in with the cloud lighthouses, so off-mesh peers can
            # hole-punch or relay to it (adamantia/brass/…).
            isLighthouse = false;
            isRelay = false;
          };
          cache = {
            server = {
              port = 443;
              hostOverride = "cache.nixos.lv";
              secure = true;
              sets = [ "cnl" ];
            };
            client = {
              # The gvh builders (saitama/bigzam) don't exist this year; an
              # empty set list keeps their dead 10.6.9.x substituters out of
              # ghostgate's nix.conf (they only time out). ghostgate pulls
              # through its own nar mirror instead (see devices/ghostgate).
              sets = [ ];
            };
          };
          ssh.hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGjq6aze6pZZwdyAqwALVuAIdjte1XgWv4+/94LDfgMS root@ghostgate";
        };

      citadel = {
        cache = {
          client = {
            sets = [ "cnl" ];
          };
        };
        ssh.hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKp3ggyZEEY2wbg2QXH5JytwADeRYluOszL5ooeQSMzL root@citadel";
      };

      ayem = {
        wifi.address = "10.5.1.1/16";
        # Advertise the mesh address so local peers reach us directly over the
        # mesh via the Nebula static host map — no cloud lighthouse needed.
        dns.addresses."10.5.1.1" = [ "ayem.mesh.dc.nixos.lv" ];
        nebula.address = "10.6.8.1";
        cache = {
          client = {
            # wants cache.nixos.lv
            sets = [ "cnl" ];
          };
        };
        ssh.hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILGezmmzvw5lnAulHSaw5zjLQDEdey1VwcPT8SAN6Et4 root@ayem";
      };

      seht = {
        wifi.address = "10.5.1.2/16";
        dns.addresses."10.5.1.2" = [ "seht.mesh.dc.nixos.lv" ];
        nebula.address = "10.6.8.2";
        cache = {
          client = {
            # wants cache.nixos.lv
            sets = [ "cnl" ];
          };
        };
        #ssh.hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILGezmmzvw5lnAulHSaw5zjLQDEdey1VwcPT8SAN6Et4 root@ayem";
      };

      vehk = {
        wifi.address = "10.5.1.3/16";
        dns.addresses."10.5.1.3" = [ "vehk.mesh.dc.nixos.lv" ];
        nebula.address = "10.6.8.3";
        cache = {
          client = {
            # wants cache.nixos.lv
            sets = [ "cnl" ];
          };
        };
        ssh.hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID9Mi3Z6hRCX5z/rGncDPjYybRWLJhAbsH56dtnaKy42 root@vehk";
      };

      bigzam = {
        nebula.address = "10.6.9.2";
        cache = {
          client = {
            sets = [ "gvh-a" ];
          };
          server = {
            priority = 20;
            port = 5000;
            # provides great-value-hydra mirror
            sets = [ "gvh-b" ];
          };
        };
      };

      saitama = {
        nebula.address = "10.6.9.3";
        cache = {
          server = {
            priority = 10;
            port = 5000;
            # provides great-value-hydra
            sets = [ "gvh-a" ];
          };
        };
      };

      genos = {
        nebula.address = "10.6.9.4";
        cache.client.sets = [ "gvh-a" ];
      };

      tatsumaki = {
        nebula.address = "10.6.9.5";
        cache.client.sets = [ "gvh-a" ];
      };
    };

    constants = {
      wifi = {
        essid = "NixMesh";
        primaryChannel = 5240;
        secondaryChannel = 5745;
        passwordFile = "/etc/meshos/dc34/mesh.key";
        subnet = "10.5.0.0/16";
      };

      nebula = {
        subnet = "10.6.0.0/16";
        caBundle = ./arena.ca.crt;
      };
    };
  };
}
