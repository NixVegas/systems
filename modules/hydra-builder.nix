{
  lib,
  ...
}:

let
  domainName = "runner.hydra.nixos.lv";
in
{
  systemd.services.hydra-queue-builder.dev = {
    serviceConfig.LimitNOFILE = lib.mkForce 1048576;
  };

  services.hydra-queue-builder-dev = {
    enable = true;
    queueRunnerAddr = "https://${domainName}";
    maxJobs = lib.mkDefault 2;

    mtls = {
      serverRootCaCertPath = "/etc/keys/hydra-ca.crt";
      clientCertPath = "/etc/keys/hydra-runner-cert.pem";
      clientKeyPath = "/etc/keys/hydra-runner-privkey.pem";
      inherit domainName;
    };
  };
}
