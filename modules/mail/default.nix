{
  nixos-mailserver,
  ...
}:

{
  imports = [
    nixos-mailserver.nixosModules.default
  ];

  services.nginx = {
    enable = true;

    # For 26.05
    # virtualHosts.${config.mailserver.fqdn}.enableACME = true;
  };

  mailserver = {
    enable = true;
    dmarcReporting.enable = true;
    certificateScheme = "acme-nginx";

    # For 26.05
    # Reference the existing ACME configuration created by nginx
    # x509.useACMEHost = config.mailserver.fqdn;
  };
}
