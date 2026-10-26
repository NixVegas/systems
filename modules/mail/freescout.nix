{
  pkgs,
  lib,
  ...
}:

{
  services.freescout = {
    enable = true;

    phpPackage =
      let
        callPackage = pkgs.newScope {
          stdenv = pkgs.funkyenv.seed (lib.toInt (lib.readFile ./php.seed));
          inherit callPackage;
        };
      in
      (callPackage (pkgs.path + "/pkgs/development/interpreters/php") { }).php84;

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
