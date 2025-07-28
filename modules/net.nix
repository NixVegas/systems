{
  lib,
  config,
  ...
}:
{
  networking = {
    useDHCP = lib.mkDefault true;
    hostId = lib.mkDefault (builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName));
  };

  services = {
    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
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
