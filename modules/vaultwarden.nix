{
  lib,
  ...
}:

{
  services.vaultwarden = {
    enable = true;
    environmentFile = lib.mkDefault "/var/lib/vaultwarden/vaultwarden.env";
    dbBackend = lib.mkDefault "postgresql";
    configurePostgres = lib.mkDefault true;
    config = {
      SIGNUPS_ALLOWED = lib.mkDefault false;
      SHOW_PASSWORD_HINT = lib.mkDefault false;
      SIGNUPS_VERIFY = lib.mkDefault true;
      ROCKET_ADDRESS = lib.mkDefault "127.0.0.1";
      ROCKET_PORT = lib.mkDefault 8222;
      ROCKET_LOG = lib.mkDefault "critical";
      SMTP_HOST = lib.mkDefault "localhost";
      SMTP_PORT = lib.mkDefault 25;
      ORG_EVENTS_ENABLED = lib.mkDefault true;
    };
  };
}
