{ ... }:

{
  networking.mesh.plan = {
    hosts = {
      adamantia =
        let
          entryAddress = "151.236.16.225";
          entry6Address = "2605:3b80:111:163e::1";
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
          ssh = {
            hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGdx91MTYIyUYNxALvGeMkke3fPRxvOEzVdy2cDa8tbh root@adamantia";
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
              "10.4.0.1" = [ "ghostgate.noc.dc.nixos.lv" ];
              ${entryAddressBuild} = [ "ghostgate.build.dc.nixos.lv" ];
            };
          };
          wifi.address = "10.5.0.1/24";
          nebula = {
            address = "10.6.0.1";
            entryAddresses = [
              entryAddressBuild
              entryAddressMesh
            ];
            isLighthouse = true;
            isRelay = true;
          };
        };
    };

    constants = {
      wifi = {
        essid = "/nix/store/dc33-nv-backhaul-1.0";
        primaryChannel = 5240;
        secondaryChannel = 5745;
      };

      nebula = {
        subnet = "10.6.0.0/16";
        caBundle = ./arena.ca.crt;
      };
    };
  };
}
