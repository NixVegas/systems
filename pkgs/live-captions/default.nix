{
  lib,
  stdenvNoCC,
  python3,
  makeWrapper,
}:
let
  # aiohttp: SSE server + async whisper/webhook calls. sounddevice: PortAudio
  # capture of the AV-mixer feed. numpy/scipy: framing + WAV encoding.
  pyEnv = python3.withPackages (
    ps: with ps; [
      aiohttp
      sounddevice
      numpy
      scipy
    ]
  );
in
stdenvNoCC.mkDerivation {
  pname = "live-captions";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    # caption_client.py finds overlay.html next to itself (via __file__), so keep
    # them together in libexec and wrap the interpreter over the script.
    mkdir -p $out/libexec/live-captions $out/bin
    cp $src/caption_client.py $src/overlay.html $out/libexec/live-captions/
    makeWrapper ${pyEnv}/bin/python3 $out/bin/live-captions \
      --add-flags $out/libexec/live-captions/caption_client.py
    runHook postInstall
  '';

  meta = {
    description = "Live talk captions (OBS overlay) + keyword->Home Assistant trigger, backed by Tenstorrent Whisper";
    mainProgram = "live-captions";
    platforms = lib.platforms.linux;
  };
}
