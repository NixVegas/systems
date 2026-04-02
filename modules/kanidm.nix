{
  config,
  pkgs,
  ...
}:

{
  services.kanidm = {
    package = pkgs.kanidm_1_9.withSecretProvisioning;

    enableServer = true;
    serverSettings = {
      bindaddress = "127.0.0.1:6537";

      online_backup = {
        path = "/var/lib/kanidm/backups";
        schedule = "00 22 * * *";
        versions = 3;
      };
    };
  };
}
