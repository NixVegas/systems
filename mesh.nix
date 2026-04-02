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
            isLighthouse = true;
            isRelay = true;
            defaultRouteMetric = 2010;
          };
          ssh.hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGdx91MTYIyUYNxALvGeMkke3fPRxvOEzVdy2cDa8tbh root@adamantia";
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
            isLighthouse = true;
            isRelay = true;
            defaultRouteMetric = 2010;
          };
          ssh.hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGdx91MTYIyUYNxALvGeMkke3fPRxvOEzVdy2cDa8tbh root@adamantia";
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
            isLighthouse = true;
            isRelay = true;
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
            };
          };
          wifi.address = "10.5.0.1/16";
          nebula = {
            address = "10.6.7.1";
            entryAddresses = [
              entryAddressBuild
              entryAddressMesh
            ];
            isLighthouse = true;
            isRelay = true;
          };
          cache = {
            server = {
              port = 443;
              hostOverride = "cache.nixos.lv";
              secure = true;
              sets = [ "cnl" ];
            };
            client = {
              # we want great-value-hydra and the mirror
              sets = [
                "gvh-a"
                "gvh-b"
              ];
            };
          };
          ssh.hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGjq6aze6pZZwdyAqwALVuAIdjte1XgWv4+/94LDfgMS root@ghostgate";
        };

      vivec = {
        wifi.address = "10.5.1.3/16";
        nebula.address = "10.6.8.1";
        cache = {
          client = {
            # wants cache.nixos.lv
            sets = [ "cnl" ];
          };
        };
        ssh.hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID9Mi3Z6hRCX5z/rGncDPjYybRWLJhAbsH56dtnaKy42 root@vivec";
      };

      bigzam = {
        nebula.address = "10.6.8.2";
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
        nebula.address = "10.6.8.3";
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
        nebula.address = "10.6.8.4";
        cache.client.sets = [ "gvh-a" ];
      };

      tatsumaki = {
        nebula.address = "10.6.8.5";
        cache.client.sets = [ "gvh-a" ];
      };
    };

    constants = {
      wifi = {
        essid = "/nix/var/nix/gcroots/dc33-mesh-a";
        primaryChannel = 5240;
        secondaryChannel = 5745;
        passwordFile = "/etc/meshos/dc33/a.key";
        subnet = "10.5.0.0/16";
      };

      nebula = {
        subnet = "10.6.0.0/16";
        caBundle = ./arena.ca.crt;
      };
    };
  };
}
