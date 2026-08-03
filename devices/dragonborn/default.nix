{ pkgs, ... }:
{
  imports = [
    ../../modules/desktop.nix
    ../../modules/live-captions.nix
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
    # Whisper Bearer key read from a file at runtime (out of the store). A STRING
    # path so it is not copied in. Operator places it readable by the desktop
    # user, e.g. `install -m644 -D <key> /var/lib/live-captions/whisper-api-key`
    # (low-value LAN key; use 640 + a group if you prefer). Must match citadel's.
    apiKeyFile = "/var/lib/live-captions/whisper-api-key";
    triggers = [
      {
        keyword = "agency";
        webhookUrl = "https://home.nixos.lv/api/webhook/agency-flash";
      }
    ];
    # TODO: set to the AV mixer's capture device. Run `live-captions
    # --list-devices` on dragonborn and put the index or a unique name substring
    # here. Left unset it uses the default input (the built-in mic).
    # device = "USB Audio";
  };
}
