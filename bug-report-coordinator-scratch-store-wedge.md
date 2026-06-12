# Coordinator started for a secondary (scratch) store permanently wedges unprivileged daemon builds

## Environment

- Nix: `nix (Nix) 2.35.0pre20260612_371c158` (branch `claude/single-branch-pr-split-xpy8oq`, current head — i.e. *after* the unprivileged-ssh-ng and input-closure fixes, which work)
- NixOS 25.11.20260608.e820eb4 (Xantusia), x86_64-linux, Hetzner Cloud VM (2 vCPU)
- Daemon settings: `sandbox = true`, `experimental-features = nix-command flakes build-coordinator`, `trusted-users = root nixremote`
- Remote build path under test: GH runner client → `ssh-ng://nixremote@host` → `nix-daemon --stdio`

## Summary

Running **one** coordinator-enabled build as root against a **throwaway chroot
store** poisons the machine: from that moment on, every **unprivileged**
daemon-session build (`ssh-ng`, the builder's whole purpose) hangs ~5 minutes
and dies with `Nix daemon disconnected unexpectedly (maybe it crashed?)`.
Root/LocalStore builds on the same machine keep working throughout. The
poisoned state **survives** killing every related process and restarting the
daemon; only a full reinstall of the machine cleared it.

## Trigger

This was a NixOS `system.preSwitchChecks` smoke test, executed by root during
`switch-to-configuration switch` (under the comin service cgroup):

```sh
scratch=$(mktemp -d /root/pre-switch-smoke.XXXXXXXX)
trap 'rm -rf "$scratch"' EXIT
nix build --no-link \
  --extra-experimental-features 'nix-command build-coordinator' \
  --store "$scratch" \
  --option substituters "" \
  -f ./remote-build-with-inputs.nix --argstr prefix pre-switch-smoke
```

`remote-build-with-inputs.nix` is a two-derivation probe (a store-path build
script executed via `sh <path>`, reading back a `builtins.toFile` source); the
same file builds fine remotely and in the main store. **The scratch-store build
itself succeeded**, the check passed, the switch went through. The scratch
directory was deleted by the trap immediately after.

## Observed timeline (all times UTC, 2026-06-12; one continuous incident)

1. `09:23:1x` — pre-switch check runs the scratch-store build above (success), switch completes.
2. `09:23:27` — CI starts an unprivileged ssh-ng build of the same probe in the **main** store. It prints `building '...build-script.drv'...` then hangs.
3. `09:28:55` — after ~5.5 min: `error: Nix daemon disconnected unexpectedly (maybe it crashed?)`, `builder failed with exit code 1`.
4. Recovery attempted: `systemctl stop comin` (kills the whole cgroup, including anything the switch left behind), `pkill` of lingering serve processes, `rm -f /nix/var/nix/coordinator*.socket` (path guessed), `systemctl restart nix-daemon.socket nix-daemon.service`.
5. `09:33–09:37` — comin (root, LocalStore) **successfully builds and switches two more generations** — root-path builds are unaffected.
6. `09:37:22` — fresh unprivileged ssh-ng build: hangs again, dies at `09:42:12` with the same daemon-disconnect. The poison survived step 4.
7. Full `nixos-anywhere` reinstall of the machine → unprivileged builds work again (this is how the box was recovered both times this happened).

A second occurrence followed the identical pattern after another deploy ran
the same check, confirming reproducibility (n=3 hangs across 2 poisonings).

## Why this looks like a coordinator scoping bug

- The asymmetry is the key clue: **root/LocalStore clients build fine** while
  **unprivileged daemon sessions hang**, on the same machine, same store, same
  derivations. Whatever the unprivileged relay path (added/changed by the
  recent fixes) looks up to find "the" coordinator, the root path evidently
  does not use the same lookup.
- The poisoned state is not a live process: killing the originating cgroup,
  all nix processes, and restarting the daemon does not clear it. It behaves
  like a **stale socket file or persistent registration** that the scratch
  store's coordinator left at a path not scoped to that store — and which
  unprivileged relays then try to attach to, hanging until the session dies.
  (`/nix/var/nix/coordinator*.socket` was a guess and matched nothing or the
  wrong thing; the actual location is in the fork's coordinator code.)
- Related earlier signature, same day, different trigger: a *failed*
  coordinator build (on the previous pin `d2d9fa5`) left coordinator processes
  in the comin cgroup holding "the big Nix store lock", with concurrent remote
  sessions dying the same way; that variant *was* cleared by killing the
  cgroup. Coredumps from those crashes showed
  `tryStartCoordinatorRelay → startProcess → spawnCoordinator →
  Coordinator::run → onConnReadable → Coordinator::startBuild →
  Store::buildDerivation → ChrootLinuxDerivationBuilder::startChild` with the
  signal-handler thread in `unix::triggerInterrupt → pthread_kill`.

## Reproduction (expected)

On a NixOS machine running the fork with `build-coordinator` enabled and an
unprivileged trusted ssh-ng user:

1. Confirm a remote unprivileged build of an input-bearing derivation works.
2. As root: `nix build --store $(mktemp -d /root/s.XXXX) --extra-experimental-features 'nix-command build-coordinator' --option substituters '' <same probe>` ; then `rm -rf` the scratch dir.
3. Repeat step 1 → hangs ~5 min, `Nix daemon disconnected unexpectedly`.
4. Restart `nix-daemon.socket`/`.service`, kill all nix processes → step 1 still fails.

## Expected behaviour

- Coordinator sockets/registrations are scoped to their store; a coordinator
  for `/root/s.XXXX` must be invisible to builds in `/nix/store`.
- A coordinator whose store disappears (or whose last client exits) shuts
  down and removes its registration.
- A relay that cannot reach a coordinator fails fast (or falls back to a
  direct build) instead of hanging for minutes and killing the daemon session.

## Suggested acceptance test

Functional test: as root, run one coordinator-enabled build in a scratch
chroot store and delete the store; then perform an unprivileged daemon-session
build of an input-bearing derivation in the main store. It must complete
promptly. (Input-free probes whose builder is the sandbox `/bin/sh` do not
exercise enough of the path — that blind spot is what let the earlier
input-closure bug ship.)

## Evidence

- Hang + disconnect (first poisoning): https://github.com/Takishima/nix-builder-infra/actions/runs/27406876444
- Hang + disconnect after process-level recovery (proving persistence): https://github.com/Takishima/nix-builder-infra/actions/runs/27407437827
- The check and probe sources: `builder.nix` (`system.preSwitchChecks.fork-daemon-smoke-build`) and `tests/remote-build-with-inputs.nix` in Takishima/nix-builder-infra (the check now runs with the coordinator feature disabled as a workaround, commit `1d4d0e7`).
