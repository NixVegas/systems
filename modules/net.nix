{
  lib,
  config,
  ...
}:
{
  networking.useDHCP = lib.mkDefault true;
  services = {
    openssh = {
      enable = true;
    };
    avahi = {
      enable = true;
      publish = {
        enable = true;
        userServices = true;
      };
      nssmdns4 = true;
      nssmdns6 = true;
    };
  };
}
