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
  sg1Image = pkgs.autopen.lib.signingKey.remote {
    name = "sg1-image";
    verificationKey = pkgs.autopen.lib.verificationKey.fromCertificate ./sg1-image.crt;
    socketPath = "/run/autopen/socket";
  };
in
{
  imports = [
    ../../modules/vp2420
    # Hydra builder agent (same shape as citadel: mTLS to runner.hydra.nixos.lv).
    ../../modules/hydra-builder.nix
  ];

  # vehk is the only host with the autopen signing daemon (TPM-backed sg1
  # keys behind /run/autopen/socket), so builds that declare
  # `requiredSystemFeatures = [ "autopen" ]` can ONLY run here. It is also a
  # resource-limited VP2420, so it must take NOTHING else. mandatoryFeatures
  # does both: Hydra dispatches a step to a machine only if the machine's
  # mandatory features are a subset of the step's required features, so vehk
  # sees only autopen steps -- and since no other builder advertises autopen,
  # those steps land only here. supportedFeatures is left at its default
  # (derived from nix.settings.system-features, which already includes
  # autopen plus the standard kvm/big-parallel/... set) so an autopen step
  # that also needs a common feature still matches instead of stranding with
  # no eligible builder. Prereq, as for citadel: the mTLS client cert/key at
  # /etc/keys/hydra-builder-{cert,privkey}.pem, provisioned out of band.
  services.hydra-queue-builder-dev.settings = {
    maxJobs = 1;
    mandatoryFeatures = [ "autopen" ];
  };

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
        sg1-image = mkRsaKey {
          name = "sg1-image";
          id = 19;
          cn = "SG1 Boot Image";
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
    hardwareKeys.sg1-image = {
      inherit (config.security.pkcs11.keypairs.sg1-image) uri;
      fileRef = sg1Image.fileRefPath;
    };
  };

  # Advertise the `autopen` build feature so derivations that MUST sign on this
  # host can pin themselves to it with requiredSystemFeatures = [ "autopen" ].
  # The SG2000 signed/encrypted FIPs do exactly this (sophgone's fip-sign.nix):
  # signing reaches the local TPM through the autopen daemon socket, so the build
  # cannot run on citadel or any other builder. Without this feature that pin
  # would make the FIP unbuildable everywhere; with it, the sign always lands
  # here. The four defaults are restated because setting this replaces the list.
  nix.settings.system-features = [
    "nixos-test"
    "benchmark"
    "big-parallel"
    "kvm"
    "autopen"
  ];

  systemd.services.autopen = {
    after = [
      "nixpkcs@sg1-sb.service"
      "nixpkcs@sg1-enc.service"
      "nixpkcs@sg1-image.service"
    ];

    serviceConfig.ReadWritePaths = lib.mkAfter [ "/etc/tpm2-pkcs11" ];

    # Need these environment variables for signing.
    environment = 
      config.security.pkcs11.keypairs.sg1-sb.extraEnv
      // config.security.pkcs11.keypairs.sg1-enc.extraEnv
      // config.security.pkcs11.keypairs.sg1-image.extraEnv;
  };

  networking.hostName = "vehk";
}
