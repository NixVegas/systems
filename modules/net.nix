{
  lib,
  config,
  ...
}:
{
  networking = {
    useDHCP = lib.mkDefault true;
    hostId = lib.mkDefault (
      builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName)
    );
    networkmanager.enable = lib.mkForce false;
  };

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
}
