# Backport of https://github.com/NixOS/nixpkgs/pull/543357.
#
# Our pinned nixpkgs predates that PR, so albucore and albumentations build
# against it without the postPatch steps it adds:
#   - setup.py does `from pkg_resources import ...`, which breaks under the
#     setuptools our nixpkgs ships (pkg_resources no longer importable that
#     way); rewrite it to importlib.metadata.
#   - albumentations' tests/test_blur.py passes a non-float radius to
#     Pillow's GaussianBlur, which newer Pillow rejects; coerce to float.
#
# These are vendored verbatim from the PR. Applied to every Python package set
# via pythonPackagesExtensions so it covers whichever interpreter pulls them in.
#
# Temporary: drop this overlay once the pinned nixpkgs includes the PR. The
# --replace-fail steps will then fail (the old strings are already gone),
# which is the intended signal that the backport is dead and should be removed.
final: prev: {
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (pyfinal: pyprev: {
      albucore = pyprev.albucore.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace setup.py \
            --replace-fail \
              'from pkg_resources import DistributionNotFound, get_distribution' \
              'from importlib.metadata import PackageNotFoundError as DistributionNotFound, distribution as get_distribution'
        '';
      });

      albumentations = pyprev.albumentations.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace setup.py \
            --replace-fail \
              'from pkg_resources import DistributionNotFound, get_distribution' \
              'from importlib.metadata import PackageNotFoundError as DistributionNotFound, distribution as get_distribution'
          substituteInPlace tests/test_blur.py \
            --replace-fail \
              '(ImageFilter.GaussianBlur(radius=sigma))' \
              '(ImageFilter.GaussianBlur(radius=float(sigma)))'
        '';
      });
    })
  ];
}
