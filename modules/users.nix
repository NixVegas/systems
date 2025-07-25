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
    "ross"
    "numinit"
  ];
}
