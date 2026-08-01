{
  lib,
  config,
  pkgs,
  ...
}:
{
  networking = {
    useDHCP = lib.mkDefault true;
  };

  security.pki.certificateFiles = [ pkgs.nixos-lv-root-ca ];

  services = {
    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
    };
    fail2ban = {
      enable = lib.mkDefault true;
      ignoreIP =
        let
          subnet = config.networking.mesh.plan.constants.nebula.subnet or null;
        in
        lib.mkIf (subnet != null) [ subnet ];
      bantime-increment = {
        enable = true;
        rndtime = "4m";
      };
    };
    avahi = {
      enable = lib.mkDefault true;
      publish = {
        enable = true;
        userServices = true;
      };
      nssmdns4 = true;
      nssmdns6 = true;
    };
  };

  programs.ssh.startAgent = true;

  # Don't enable this garbage.
  services.gnome.gcr-ssh-agent.enable = lib.mkForce false;
}
