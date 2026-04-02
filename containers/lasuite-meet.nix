{
  config,
  ...
}:

{
  imports = [
    ../modules/lasuite-meet.nix
  ];
  networking.firewall.allowedTCPPorts = [
    config.services.livekit.settings.http_relay_port
  ];
}
