{
  config,
  lib,
  ...
}:
{
  security.sudo = {
    enable = true;
    execWheelOnly = true;
    extraRules = [
      {
        users = [ "deploy" ];
        commands = [ { command = "ALL"; options = [ "NOPASSWD" ]; } ];
      }
    ];
  };

  users = {
    users = {
      deploy = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
      };
      ross = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
      };
      numinit = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = [
          "sk-ecdsa-sha2-nistp256@openssh.com AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5jb20AAAAIbmlzdHAyNTYAAABBBOLkms0KUv8J45FqK2WG6J6X4DZGhMB5sMM8gEl0bUCmH7XH36/D73+nDtVriXC2ITAduvKmCRvs+DW1js3jTwQAAAAEc3NoOg== numinit@cyrus#6460026"
        ];
      };
    };
  };

  nix.settings.trusted-users = [
    "deploy"
    "ross"
    "numinit"
  ];
}
