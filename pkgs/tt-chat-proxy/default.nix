{
  lib,
  stdenvNoCC,
  python3,
  makeWrapper,
}:
let
  # aiohttp: async reverse proxy + SSE streaming rewrite. Nothing else needed.
  pyEnv = python3.withPackages (ps: with ps; [ aiohttp ]);
in
stdenvNoCC.mkDerivation {
  pname = "tt-chat-proxy";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec/tt-chat-proxy $out/bin
    cp $src/proxy.py $out/libexec/tt-chat-proxy/
    makeWrapper ${pyEnv}/bin/python3 $out/bin/tt-chat-proxy \
      --add-flags $out/libexec/tt-chat-proxy/proxy.py
    runHook postInstall
  '';

  meta = {
    description = "OpenAI chat proxy that hides model reasoning and redacts flag-shaped strings";
    mainProgram = "tt-chat-proxy";
    platforms = lib.platforms.linux;
  };
}
