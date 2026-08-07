{ pkgs, ... }:
{
  imports = [
    ../../modules/desktop.nix
    ../../modules/live-captions.nix
    ../../modules/swap.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "dragonborn";
  nixVegas.zfs = {
    enc = true;
    etc = true;
    rootHome = true;
  };

  # Streaming box: panel monitor with a live CPU clock readout (patched below).
  # The Framework 16 amd_pstate stick clamps every core to ~600 MHz until a
  # suspend/resume (the ONLY thing that clears it -- driver/governor/profile
  # bounces don't, and toggling amd_pstate/status WARNs). So we watch for it on
  # the panel and bounce it by hand: the applet shows the avg clock right on the
  # icon (e.g. "0.6G"), no popup needed. Add it via COSMIC Settings -> Panel ->
  # Applets (placement isn't declarative yet).
  environment.systemPackages = [ pkgs.cosmic-ext-applet-minimon ];

  # Local patch: add a CPU-frequency readout to minimon's CPU sensor. Reads the
  # cpufreq sysfs and renders the avg clock as a panel figure on the CPU applet
  # (shown even in icon-only mode, independent of the "value" toggle), and also
  # appends it to the popup text. Scoped to dragonborn. Upstreamable to
  # cosmic-utils/minimon-applet; drop if it lands there.
  nixpkgs.overlays = [
    (_final: prev: {
      cosmic-ext-applet-minimon = prev.cosmic-ext-applet-minimon.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../../pkgs/cosmic-ext-applet-minimon-cpufreq/cpu-frequency.patch
        ];
      });
    })
  ];

  services.live-captions = {
    enable = true;
    # Flag banner stays up for the whole ~15s flag-capture celebration.
    flagSeconds = 15.0;
    apiKeyFile = "/etc/live-captions/whisper-api-key";
    # Save one .ass per session next to OBS's default recording dir (~/Videos), so
    # `caption-align <session>.ass <recording>` can shift captions onto a take.
    # The user service runs as numinit; the dir is created on first write.
    subtitleDir = "/home/numinit/Videos/captions";
    triggers = [
      {
        keyword = "agency";
        webhookUrl = "https://home.nixos.lv/api/webhook/agency-flash";
      }
      {
        # CTF flag capture: fires the green flag-capture lights pattern AND flashes
        # the flag text (from the file below, read live so it's editable without a
        # rebuild) as a banner on the caption overlay.
        keyword = "escape your fate";
        webhookUrl = "https://home.nixos.lv/api/webhook/flag-capture";
        captionFile = "/etc/nixctf/flag-caption";
      }
    ];
    # Framework expansion module
    device = "Audio Expansion Card Mono";
  };
}
