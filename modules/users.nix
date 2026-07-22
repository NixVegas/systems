{
  config,
  lib,
  ...
}:
let
  # Every wheel (admin) user also lands in these groups: local console + media
  # + device access (serial/GPU/input) without per-user boilerplate. `usb` comes
  # from the udev rule below that tags USB devices GROUP="usb".
  adminExtraGroups = [
    "tty"
    "video"
    "render"
    "input"
    "dialout"
    "usb"
  ];
in
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
    groups.usb.gid = 500;

    # Fold adminExtraGroups into every user that's in wheel. Maps the local
    # attrset below (NOT config.users.users), so there's no self-referential
    # recursion, and any new wheel user picks the groups up automatically.
    users = lib.mapAttrs (
      _: u:
      u
      // lib.optionalAttrs (lib.elem "wheel" (u.extraGroups or [ ])) {
        extraGroups = lib.unique (u.extraGroups ++ adminExtraGroups);
      }
    ) {
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
      jasonodoom = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = [
          "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDdTRD5etaWB3UmGiJ2cD/TVCn/asEw7c8frhAYDOhsb1bmEp7z3mG7gKFwepBaWFX3D7aXXirTTNsnKd7AsM5riQQg1tZ5qtmT+nEmpDhi1WVtFm89jc0ezyJN1SnlsCUEhQ0twn4qzR+PnjRVE1E4KTpbwTCapgMl9w4iCEQikaPWWcg9u+CRGNLaehgM7Jm5jKdVoIa258wNgvCrNZcba4LCccz1PK5j4j1uu3sr400CatIEkWe+aqiDCBIamFPXuJqZy1gb4+dqk1wKPJqn8L9WFD6j5mDarrIaHHmy7rnviPinbpLoCE3eksxAVeI1QjI8uPXyrn4GtUQNSNBMZPu2DTCZSo5bG5NbcE2Di9KSkW8SQJg0dYgZSJjssp5qkT9uFx7AnLfvIlR3+IQA45cXnM+jXCikNbGPLMenv8jjMrSke73hxr8T6rsjO2FGT3tWeiDBN5B59wgWY+bbrExOcFe2/cClYfBFzdF9d800Xg6+fN7E6gamTyrNNRL68f+sawuTDBrWggPJFFcHvQMd4zxE/ujbyCgy+11U8M5AAU/y6/Aa2XUt0jnEXgMXBpo7M3/5OWRzzyCO2RwtDWVxrJXPW9xYGvSoPAfDmdi0VNiGyldvbw4HHcHiFqftTCrNzMbR/QbjsuF4HMGI4fXddWYOFlNHbv+X+O2/kQ=="
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICwLk94aSzaUrpxHZ6BHbxMaF3054VZJh6rUF8cdSHIm"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPW8f7060MjdAPuUfMz1VJEBzSqf5xXfYHC4NalF1y7b"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBBMwvNuHcWxV+R2CnQVcxgy/lP89m9gmlXxsNp4p4HL"
        ];
      };
    };
  };

  # USB devices are owned by the `usb` group (which every admin joins above), so
  # wheel users can talk to them without root.
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", GROUP="usb"
  '';

  nix.settings.trusted-users = [
    "@wheel"
  ];
}
