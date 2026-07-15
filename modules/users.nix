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
        commands = [
          {
            command = "ALL";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };

  users = {
    users = {
      ross = {
        isNormalUser = true;
        extraGroups = [
          "wheel"
          "video"
        ];
        openssh.authorizedKeys.keys = [
          "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIHz1uZoTpZgyIa2mCf+oKqTPiKhK0h8WNVUJLbZNPFqZAAAABHNzaDo= yubikey"
        ];
      };
      numinit = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = [
          "sk-ecdsa-sha2-nistp256@openssh.com AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5jb20AAAAIbmlzdHAyNTYAAABBBOLkms0KUv8J45FqK2WG6J6X4DZGhMB5sMM8gEl0bUCmH7XH36/D73+nDtVriXC2ITAduvKmCRvs+DW1js3jTwQAAAAEc3NoOg== numinit@cyrus#6460026"
          "sk-ecdsa-sha2-nistp256@openssh.com AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5jb20AAAAIbmlzdHAyNTYAAABBBKbkBgZrUquZzDkohEHcWm3jn6L7swIAJO1FG/QPoAisX0VUiTLFXlk4Xz6tBWtTatHc8zTSa58hJuWmytww0CoAAAAEc3NoOg== numinit@vestige#6460026"
          "sk-ecdsa-sha2-nistp256@openssh.com AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5jb20AAAAIbmlzdHAyNTYAAABBBCuAGKvba5h2PcMxw03+GutdrhqjaVPF9w2uIKJR0BFfNEgqKKidzw+0KJGBKwP760ziKT0gHVDdkPKupkK8wJ8AAAAEc3NoOg== numinit@talin#6460026"
          "sk-ecdsa-sha2-nistp256@openssh.com AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5jb20AAAAIbmlzdHAyNTYAAABBBOCXnQOjfz1FD8Ome8WyZoNL9ViGSdE0WQpBP9PZSYi1aSAx03kotK2NS/+EwJJm+DkOebPBUCoHLzvxv2xmkjcAAAAEc3NoOg== numinit@dragonborn#6460026"
          "sk-ecdsa-sha2-nistp256@openssh.com AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5jb20AAAAIbmlzdHAyNTYAAABBBKK0oBIjxEkgxG2a8gXHZjX8Q/VViG2NhK+IIomWeaqki2ttZ5jH8/M7tBgrV1kmd6xxK+nLCbBfjehxpmTFhCUAAAAEc3NoOg== numinit@monomyth#6460026"
          "sk-ecdsa-sha2-nistp256@openssh.com AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5jb20AAAAIbmlzdHAyNTYAAABBBKh0nVO9z2hjBUAMHOHarozq+0QHTfu5rriX9C/8ZcOGuhz3kXyMZ19zwxJchIledp8SqqLbi9HWohvfPWV0W+sAAAAEc3NoOg== numinit@aurbis#6460026"
        ];
      };
      rob = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMEiESod7DOT2cmT2QEYjBIrzYqTDnJLld1em3doDROq yubikey"
        ];
      };
      djacu = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEbH7DL3UpeYHm+J3YHJTIsnk/vdo5JgEzwD/Bf1tupp yubikey"
        ];
      };
      crertel = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = [
          "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIGKDzVwo8Xe1dJk2hhIizPai/KfIPhWUYRs18gKv9JygAAAABHNzaDo= crertel"
        ];
      };
    };
  };

  nix.settings.trusted-users = [
    "@wheel"
  ];
}
