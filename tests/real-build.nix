# Realistic probe derivation: the standard nixpkgs shape, unlike the
# applet-less /bin/sh probes in remote-build*.nix. `runCommand` gives a
# store-path bash as the builder and coreutils on PATH, so the input closure
# is the real thing (the builder substitutes it via builders-use-substitutes
# rather than receiving it over the wire). This is exactly the shape of every
# real-world derivation — including the NixOS glue drvs whose coordinator
# builds broke twice — so it complements the minimal-protocol probes.
#
# Log interface matches remote-build.nix: BUILDTOKEN:<uptime> identifies the
# execution, MARKER:<tag> proves log streaming, DONE:<tag> the run to
# completion. `holdSeconds` may use real `sleep` here (coreutils exists).
{
  pkgs,
  tag,
  holdSeconds ? 0,
}:
pkgs.runCommand "real-${tag}" { } ''
  read start _rest < /proc/uptime
  echo "BUILDTOKEN:$start"
  echo "MARKER:real-${tag}"
  sleep ${toString holdSeconds}
  seq 1 200000 | sha256sum > "$out"
  echo "DONE:real-${tag}"
''
