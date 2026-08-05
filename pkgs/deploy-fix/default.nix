# `deploy` wrapper that makes deploy-rs evaluate with the parallel `fix` evaluator
# instead of nix (~4x faster on the toplevel eval: ~1m vs ~4m). It puts a `nix`
# shim on PATH *only* for deploy-rs's own children, so the shim intercepts just
# deploy-rs's `nix eval --apply` (routing it to fix) and passes every other nix
# call through to real nix. Fail-safe (shim falls back to real nix on any error),
# so it can't break a deploy. See ../../docs/fix-evaluator.md.
#
# DEPLOY_NO_FIX=1 deploy .#host  -> stock nix eval (no fix, no 19700101 labels).
{
  runCommand,
  writeShellApplication,
  deploy-rs,
  nix,
  fix,
  coreutils,
  gnugrep,
  gnused,
}:
let
  shim = runCommand "deploy-fix-nix-shim" { } ''
    mkdir -p $out/bin
    substitute ${./nix-eval-shim} $out/bin/nix \
      --subst-var-by nix '${nix}' \
      --subst-var-by fix '${fix}'
    chmod +x $out/bin/nix
  '';
in
writeShellApplication {
  name = "deploy";
  # The shim (deploy-rs's child) needs these; it calls nix/fix by absolute path.
  runtimeInputs = [
    coreutils
    gnugrep
    gnused
  ];
  text = ''
    if [ -n "''${DEPLOY_NO_FIX:-}" ]; then
      exec ${deploy-rs}/bin/deploy "$@"
    fi
    export PATH="${shim}/bin:$PATH"
    exec ${deploy-rs}/bin/deploy "$@"
  '';
}
