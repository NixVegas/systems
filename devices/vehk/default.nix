# vehk — Protectli VP2420 wireless monitoring / mesh-client travel router.
# The bulk of the configuration is shared with its siblings ayem/seht in
# ../../modules/vp2420; only host-specific bits live here.
{ lib, pkgs, config, ... }:

let
  sg1SecureBoot = pkgs.autopen.lib.signingKey.remote {
    name = "sg1-sb";
    verificationKey = pkgs.autopen.lib.verificationKey.fromCertificate ./sg1-sb.crt;
    socketPath = "/run/autopen/socket";
  };
  sg1Encryption = pkgs.autopen.lib.signingKey.remote {
    name = "sg1-enc";
    verificationKey = pkgs.autopen.lib.verificationKey.fromCertificate ./sg1-enc.crt;
    socketPath = "/run/autopen/socket";
  };
in
{
  imports = [
    ../../modules/vp2420
  ];

  security.pkcs11 = {
    enable = true;
    pcsc = {
      enable = true;
      users = [ "numinit" ];
    };
    tpm2.enable = true;
    keypairs =
      let
        mkRsaKey =
          {
            name,
            id,
            cn,
            extensions ? [
              "basicConstraints=critical,CA:FALSE"
              "keyUsage=critical,nonRepudiation,digitalSignature"
              "extendedKeyUsage=critical,codeSigning"
              "subjectKeyIdentifier=hash"
              "authorityKeyIdentifier=keyid:always"
            ],
          }:
          {
            enable = true;
            inherit (pkgs.tpm2-pkcs11) pkcs11Module;
            inherit id;
            keyOptions = {
              algorithm = "RSA";
              type = "2048";
              usage = [ "sign" ];
              soPinFile = "/etc/nixpkcs/tpm2.user.pin";
              loginAsUser = true;
            };
            certOptions = {
              digest = "SHA256";
              subject = "C=US/ST=California/L=Carlsbad/O=Nix Vegas/OU=Keymaster/CN=${cn}";
              validityDays = 365 * 5;
              inherit extensions;
              pinFile = "/etc/nixpkcs/tpm2.user.pin";
              writeTo = "/etc/nixpkcs/${name}.crt";
            };
          };
      in
      {
        sg1-root = mkRsaKey {
          id = 15;
          name = "sg1-root";
          cn = "SG1 Root";
          extensions = [
            "v3_ca"
            "keyUsage=critical,nonRepudiation,keyCertSign,digitalSignature,cRLSign"
          ];
        };
        sg1-sb = mkRsaKey {
          name = "sg1-sb";
          id = 16;
          cn = "SG1 Secure Boot";
        };
        sg1-enc = mkRsaKey {
          name = "sg1-enc";
          id = 17;
          cn = "SG1 Image Encryption";
        };
        sg1-attest = mkRsaKey {
          id = 18;
          name = "sg1-attest";
          cn = "SG1 Attestation Root";
          extensions = [
            "v3_ca"
            "keyUsage=critical,nonRepudiation,keyCertSign,digitalSignature,cRLSign"
          ];
        };
      };
  };

  services.autopen = {
    enable = true;

    # Relax hardening enough to reach the TPM (adds the `tss` group + /dev/tpmrm0
    # and permits the AF_UNIX socket to tpm2-abrmd). Keeps cgroups readable for
    # peer attestation.
    tpm = true;

    # The socket defaults to /run/autopen/socket in the `nixbld` group, and
    # `exposeToSandbox` (default true) adds /run/autopen to
    # nix.settings.extra-sandbox-paths so sandboxed builds can sign. If the TPM
    # token store is guarded by a group other than `tss`, add it here:
    #   supplementaryGroups = [ "tpm2-pkcs11" ];

    hardwareKeys.sg1-sb = {
      inherit (config.security.pkcs11.keypairs.sg1-sb) uri;
      fileRef = sg1SecureBoot.fileRefPath;
    };
    hardwareKeys.sg1-enc = {
      inherit (config.security.pkcs11.keypairs.sg1-enc) uri;
      fileRef = sg1Encryption.fileRefPath;
    };
  };

  systemd.services.autopen = {
    after = [
      "nixpkcs@sg1-sb.service"
      "nixpkcs@sg1-enc.service"
    ];

    serviceConfig.ReadWritePaths = lib.mkAfter [ "/etc/tpm2-pkcs11" ];

    # Need these environment variables for signing.
    environment = 
      config.security.pkcs11.keypairs.sg1-sb.extraEnv // config.security.pkcs11.keypairs.sg1-enc.extraEnv;
  };

  networking.hostName = "vehk";
}
