{
  ...
}:

{
  services.freescout = {
    enable = true;

    settings.APP_KEY._secret = "/etc/freescout/app.key";

    databaseSetup = {
      enable = true;
      kind = "pgsql";
    };

    nginx = {
      forceSSL = false;
      enableACME = false;
    };
  };
}
