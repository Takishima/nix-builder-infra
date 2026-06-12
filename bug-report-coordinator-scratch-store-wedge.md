# Stale `coordinator.socket.lock` permanently wedges unprivileged daemon builds after any root coordinator build

## Environment

- Nix: `nix (Nix) 2.35.0pre20260612_371c158` (branch `claude/single-branch-pr-split-xpy8oq`, current head — i.e. *after* the unprivileged-ssh-ng and input-closure fixes, which work)
- NixOS 25.11.20260608.e820eb4 (Xantusia), x86_64-linux, Hetzner Cloud VM (2 vCPU)
- Daemon settings: `sandbox = true`, `experimental-features = nix-command flakes build-coordinator`, `trusted-users = root nixremote`
- Remote build path: GH runner client → `ssh-ng://nixremote@host` → `nix-daemon --stdio`
- GitOps: comin (root, LocalStore direct) rebuilds the system on every push to main

## Summary

After the build coordinator for the main store exits, it leaves
**`/nix/var/nix/coordinator.socket.lock`** behind — **owned by root, mode
0600, with no coordinator process alive and no `coordinator.socket` file**.
From then on, every **unprivileged** daemon-session build (`ssh-ng`) blocks
indefinitely: the forked daemon child hangs (observed 8+ minutes, until the
client gives up and the journal logs `unexpected Nix daemon error: error:
interrupted by the user`), and the client reports `Nix daemon disconnected
unexpectedly (maybe it crashed?)`.

**Root clients are unaffected** — comin kept building and switching
generations while every unprivileged build hung. Because the lock file is
root/0600, the natural suspicion is that the unprivileged relay path cannot
open/flock it and waits forever, while root clients sail through; that would
also explain why the very first unprivileged build on a fresh machine works
(it creates the lock itself, via the root daemon child) and later ones hang.

The lock file lives on disk in `/nix/var/nix`, so the wedge **survives
killing every nix process, restarting `nix-daemon.socket`/`.service`, and
would survive a reboot**. Deleting the lock file is the recovery (we
reinstalled twice before locating it).

Practical consequence on a GitOps-managed builder: **every deploy wedges the
machine's remote-build path**, because each comin rebuild is a root
coordinator build whose coordinator exit leaves the stale lock. Deploys and
remote building are currently mutually exclusive.

## Hard evidence (captured while wedged, 2026-06-12 10:09 UTC)

```
$ ls -la /nix/var/nix/ | grep -i coordinator
-rw------- 1 root root    0 Jun 12 09:57 coordinator.socket.lock      # no coordinator.socket, only the lock

$ ps -eo pid,ppid,etime,cmd | grep -i nix      # no coordinator process at all
 1309   1  11:30 nix-daemon --daemon
 (… only systemd/comin/sshd/dbus …)

# nix-daemon journal for the hung session:
09:59:42 nix-daemon[1309]: accepted connection from pid 4353, user nixremote (trusted)
10:07:48 nix-daemon[4359]: unexpected Nix daemon error: error: interrupted by the user
10:07:48 nix-daemon[1309]: reaped child process 4359, status = failed with exit code 1
```

## Timeline of the cleanest occurrence (fresh machine, single incident)

1. `09:52` — machine freshly installed (pristine `/nix/var/nix`, no lock file).
2. `09:57` — unprivileged ssh-ng build of an input-bearing probe: **works**
   (this run creates `coordinator.socket.lock`, timestamp matches).
3. `09:59:1x–31` — comin (root) rebuilds the system for a new commit and
   switches: **works**.
4. `09:59:42` — next unprivileged ssh-ng build: **hangs**; daemon child stuck
   until killed at `10:07:48`. At this point the lock file exists, no
   coordinator process exists, no socket file exists.
5. Restarting the daemon, killing processes: no effect. Removing the lock
   file (or reinstalling the machine) restores unprivileged builds.

Three earlier hangs on the same day followed the same pattern, always
immediately after a successful root (comin) coordinator build. An earlier
draft of this report blamed a scratch-store (`--store /root/tmp.XXX`)
coordinator; that was a confound — the minimal trigger is any root
coordinator build for the main store, scratch stores not required.

## Suspected mechanism

- The coordinator's socket lock is `/nix/var/nix/coordinator.socket.lock`,
  created root/0600 by whoever spawns the coordinator first.
- On coordinator exit the socket file is removed but **the lock file is
  not**.
- The unprivileged relay path (the code path fixed for ssh-ng recently)
  apparently needs to open/flock that lock before spawning/attaching a
  coordinator; with a root/0600 stale file it can neither lock it nor steal
  it, and there is **no timeout** — the daemon child blocks until the client
  disconnects.
- Root clients can lock the file, (re)spawn a coordinator, and proceed —
  hence comin's builds always working while ssh-ng hangs.

## Expected behaviour

- The coordinator removes its lock on exit (and the spawn path treats an
  unheld lock file as stale and takes it over).
- Lock/socket permissions allow every client class that is allowed to use
  the coordinator to actually acquire them (or the locking is done by the
  root daemon on behalf of unprivileged sessions).
- A relay that cannot acquire the coordinator fails fast or falls back to a
  direct build; it must never block a daemon session indefinitely.

## Reproduction (expected)

On a NixOS machine with the fork, `build-coordinator` enabled, trusted
unprivileged ssh-ng user:

1. Fresh store state (no `/nix/var/nix/coordinator.socket.lock`).
2. Unprivileged ssh-ng build → works (lock file appears).
3. As root: `nix build` anything uncached (coordinator builds it), let the
   coordinator exit.
4. Observe: `coordinator.socket.lock` present, no coordinator process.
5. Unprivileged ssh-ng build → hangs indefinitely; root build → works.
6. `rm /nix/var/nix/coordinator.socket.lock` → unprivileged builds work
   again.

## Suggested acceptance test

Functional test that alternates root-client and unprivileged daemon-session
coordinator builds of fresh input-bearing derivations (root, unprivileged,
root, unprivileged), with coordinator exit (idle timeout or explicit stop)
between rounds. Every round must complete promptly; afterwards no
`coordinator.socket.lock` may remain without a live holder.

## Evidence links

- Wedged-state capture (lock file + process list + journal): https://github.com/Takishima/nix-builder-infra/actions/runs/27409166787
- Hang after a deploy on a fresh machine: https://github.com/Takishima/nix-builder-infra/actions/runs/27408648155
- Two earlier hangs (same signature): https://github.com/Takishima/nix-builder-infra/actions/runs/27406876444, https://github.com/Takishima/nix-builder-infra/actions/runs/27407437827
- Infra-side workaround now deployed (Takishima/nix-builder-infra `builder.nix`): a path unit that removes the lock after each generation switch iff `flock -n` succeeds on it (i.e. no live coordinator holds it).
