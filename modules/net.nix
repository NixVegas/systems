{
  lib,
  config,
  ...
}:
{
  networking.useDHCP = lib.mkDefault true;
  services.openssh.enable = true;
}
