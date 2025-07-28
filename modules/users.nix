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
      };
    };
  };

  nix.settings.trusted-users = [
    "deploy"
    "ross"
    "numinit"
  ];
}
