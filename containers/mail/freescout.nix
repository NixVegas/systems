{
  freescout,
  ...
}:

{
  imports = [
    ../../modules/mail/freescout.nix
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
