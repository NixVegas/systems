{ lib, ... }:
{
  boot.kernelPatches = [
    {
      name = "perf";
      patch = null;
      extraStructuredConfig = with lib.kernel; {
        ARM64_64K_PAGES = yes;
        HZ_100 = yes;
      };
    }
  ];
}
