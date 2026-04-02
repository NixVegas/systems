{
  ...
}:

{
  services.lasuite-meet = {
    enable = true;
    enableNginx = true;
    livekit = {
      enable = true;
      keyFile = "/etc/lasuite-meet/livekit.yml";
      openFirewall = true;
    };
    redis.createLocally = true;
    postgresql.createLocally = true;
    settings = {
      FRONTEND_IS_SILENT_LOGIN_ENABLED = "0";
      ALLOW_UNREGISTERED_ROOMS = "0";
      RECORDING_ENABLE = "1";
    };
    environmentFile = "/etc/lasuite-meet/lasuite-meet.env";
  };
}
