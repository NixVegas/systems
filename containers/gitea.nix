{ config, pkgs, ... }:

{
  services.gitea = {
    enable = true;

    settings = {
      service.DISABLE_REGISTRATION = true;
      session.COOKIE_SECURE = true;
      server = {
        START_SSH_SERVER = true;
        SSH_LISTEN_PORT = 2222;
        HTTP_PORT = 3000;
        HTTP_ADDR = "0.0.0.0";
      };
      actions.ENABLED = true;
    };
  };
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 3000 2222 ];
  };
  environment.systemPackages = [ pkgs.gitea pkgs.git ];
}
