{ config, pkgs, ... }:

{
  environment.systemPackages = [
    config.services.mattermost.package
  ];
  services.mattermost = {
    enable = true;
    package = (pkgs.mattermost.override {
      # Use a premium build environment for the frontend
      # Backend injects ads before it starts and we r poor :-(
      buildNpmPackage = pkgs.buildNpmPackage.override {
        stdenv = pkgs.premenv;
      };
    }).overrideAttrs (prev: {
      webapp = prev.webapp.overrideAttrs (prevWebapp: {
        patchFlags = ["-p2"]; # we're in the webapp directory but patches are relative to root
        patches = [
          ./mattermost/0001-constants-menu-header-Add-nixpkgs-gold-support.patch
        ];
        goldLicense = "gold";
      });
    });
    host = "0.0.0.0";
    port = 8065;
    environment.MM_CALLS_GROUP_CALLS_ALLOWED = "true";
    mutableConfig = true;
    preferNixConfig = true;

    /*
      Grab these using `nix-prefetch-url`
    */
    plugins = [
      /*
        calls
        1.11.0
        https://github.com/mattermost/mattermost-plugin-calls/releases
      */
      (pkgs.fetchurl {
        url = "https://github.com/mattermost/mattermost-plugin-calls/releases/download/v1.11.0/mattermost-plugin-calls-v1.11.0-linux-amd64.tar.gz";
        hash = "sha256-J8kDL9bACQbHUs6dRmASdH6zN1Spp2ZozKvRROqZENo=";
      })
      /*
        giphy plugin plus logo tweaks
        4.0.0
        https://github.com/moussetc/mattermost-plugin-giphy/releases
      */
      (pkgs.stdenv.mkDerivation rec {
        version = "4.0.0";
        name = "mattermost-plugin-giphy";
        src = pkgs.fetchurl {
          url = "https://github.com/moussetc/mattermost-plugin-giphy/releases/download/v${version}/com.github.moussetc.mattermost.plugin.giphy-${version}.tar.gz";
          hash = "sha256-Eq1ynuZl7bdUWlVZMgEEB6z2mxG6dR5Rx6432R+2vY8=";
        };
        installPhase = ''
          rm -f public/powered-by-giphy.png
          cp ${./mattermost/powered-by-nixos.png} public/powered-by-giphy.png
          ${pkgs.pngcrush}/bin/pngcrush -rem alla -ow -brute public/powered-by-giphy.png
          tar czf $out .
        '';
      })

      /*
        rss feed
        0.2.5
        https://github.com/wbernest/mattermost-plugin-rssfeed/releases
      */
      (pkgs.fetchurl {
        url = "https://github.com/wbernest/mattermost-plugin-rssfeed/releases/download/0.2.5/rssfeed-0.2.5.tar.gz";
        sha256 = "0kx5q0s3dkvv974c5zj89g6dr5i7glahfxsmbd5718w084gmgd5j";
      })

      /*
        reminder plugin
        1.0.0
        https://github.com/scottleedavis/mattermost-plugin-remind/releases
      */
      (pkgs.fetchurl {
        url = "https://github.com/scottleedavis/mattermost-plugin-remind/releases/download/v1.0.0/com.github.scottleedavis.mattermost-plugin-remind-1.0.0.tar.gz";
        hash = "sha256-uFH4w6xROC4uG+5fHY342A2Rr9bvkJyKxBGfyE7L63I=";
      })

      /*
        matterpoll
        1.8.0
        https://github.com/matterpoll/matterpoll/releases
      */
      (pkgs.fetchurl {
        url = "https://github.com/matterpoll/matterpoll/releases/download/v1.8.0/com.github.matterpoll.matterpoll-1.8.0.tar.gz";
        hash = "sha256-ORfa+f5HJLbG+kRnL+UnbL66iPH+S9jhOHdB1vvRx2A=";
      })

      /*
        custom attributes
        1.3.1
        https://github.com/mattermost/mattermost-plugin-custom-attributes/releases
      */
      (pkgs.fetchurl {
        url = "https://github.com/mattermost/mattermost-plugin-custom-attributes/releases/download/v1.3.1/com.mattermost.custom-attributes-1.3.1.tar.gz";
        hash = "sha256-+vlbd++EEMJV0L9FixUShBua8YMF/K9QLq8fC5szq10=";
      })

      /*
        spoiler
        4.1.0
        https://github.com/moussetc/mattermost-plugin-spoiler/releases
      */
      (pkgs.fetchurl {
        url = "https://github.com/moussetc/mattermost-plugin-spoiler/releases/download/v4.1.0/com.github.moussetc.mattermost.plugin.spoiler-4.1.0.tar.gz";
        hash = "sha256-6QXMt4nYUmsoxJfxwkT9Wc7aWp1mj1O9iXn7Sq4AFSo=";
      })

      /*
        todo
        0.7.1
        https://github.com/mattermost/mattermost-plugin-todo/releases
      */
      (pkgs.fetchurl {
        url = "https://github.com/mattermost-community/mattermost-plugin-todo/releases/download/v0.7.1/com.mattermost.plugin-todo-0.7.1.tar.gz";
        sha256 = "1ki7vsvhjl2xgw4mfmnvn9s5hkn98l7nf4v9fdk59v44zbm7mriz";
      })

      /*
        profanity filter
        1.1.0-rc1
        https://github.com/mattermost/mattermost-plugin-profanity-filter/releases
      */
      (pkgs.fetchurl {
        url = "https://github.com/mattermost/mattermost-plugin-profanity-filter/releases/download/v1.1.0-rc1/mattermost-profanity-filter-1.0.0.tar.gz";
        sha256 = "d701c11dbe8e19258c7e58eae6f799826ad39bd2196b9241d3b236c897d37c4d";
      })

      /*
        memes
        1.5.0
        https://github.com/mattermost/mattermost-plugin-memes/releases
      */
      (pkgs.fetchurl {
        url = "https://github.com/mattermost/mattermost-plugin-memes/releases/download/v1.5.0/memes-1.5.0.tar.gz";
        sha256 = "0rdb9m1pn2cm8d6lix2i93ga0s6p70ls4np90slwimfw4zyrdqvk";
      })

      /*
        autolink
        1.4.1
        https://github.com/mattermost/mattermost-plugin-autolink/releases
      */
      (pkgs.fetchurl {
        url = "https://github.com/mattermost-community/mattermost-plugin-autolink/releases/download/v1.4.1/mattermost-autolink-1.4.1.tar.gz";
        hash = "sha256-uKnGAGO9CQquBLWcehhUeNOIMZduKmYL2hhDEpmUTlE=";
      })
    ];
  };

  networking = {
    firewall = {
      enable = true;
      allowedTCPPorts = [ 8065 ];
      allowedUDPPorts = [ 8443 ];
    };
  };

  system.activationScripts.postgresPermissions.text = ''
    mkdir -p /var/lib/postgresql
    chown postgres:postgres /var/lib/postgresql
  '';
}
