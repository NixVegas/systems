{
  pkgs,
  lib,
  ...
}:

let
  domainName = "runner.hydra.nixos.lv";
in
{
  systemd.services.hydra-queue-builder-dev = {
    serviceConfig.LimitNOFILE = lib.mkForce 1048576;
  };

  services.hydra-queue-builder-dev = {
    enable = true;
    queueRunnerAddr = "https://${domainName}";
    maxJobs = lib.mkDefault 2;

    mtls = {
      # Signed with Let's Encrypt, which is in here.
      serverRootCaCertPath = "/etc/ssl/certs/ca-certificates.crt";
      clientCertPath = "/etc/keys/hydra-builder-cert.pem";
      clientKeyPath = "/etc/keys/hydra-builder-privkey.pem";
      inherit domainName;
    };
  };
}
