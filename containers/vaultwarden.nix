{
  config,
  ...
}:

{
  imports = [
    ../modules/vaultwarden.nix
  ];
  networking.firewall.allowedTCPPorts = [
    config.services.vaultwarden.config.ROCKET_PORT
  ];
}
