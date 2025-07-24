{ pkgs, ... }:
{
  services.openssh.extraConfig =
    let
      command = pkgs.writeShellApplication {
        name = "command";
        runtimeInputs = [
          pkgs.nix
          pkgs.coreutils
        ];
        text = builtins.readFile ./force-command.sh;
      };
      matchBlock = ''
        Match User nixbld
          AllowAgentForwarding no
          AllowTcpForwarding no
          PermitTTY no
          PermitTunnel no
          X11Forwarding no
          ForceCommand ${command}/bin/command
        Match All
      '';
    in
    matchBlock;

  users.users.builder = {
    isNormalUser = true;
  };

  nix.settings.trusted-users = [ "builder" ];
}
