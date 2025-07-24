{
  config,
  lib,
  ...
}:
{
  security.sudo = {
    enable = true;
    execWheelOnly = true;
  };

  users = {
    users = {
      ross = {
        isNormalUser = true;
        group = "wheel";
      };
      numinit = {
        isNormalUser = true;
        group = "wheel";
      };
    };
    groups.wheel = { };
  };

  nix.settings.trusted-users = [
    "ross"
    "numinit"
  ];
}
