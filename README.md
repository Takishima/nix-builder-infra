# nix-builder-infra

A fleet of NixOS remote builders on Hetzner Cloud, used to load-test the Nix
`ssh-ng://` daemon worker protocol (developed in
[Takishima/nix](https://github.com/Takishima/nix)) with real builds.

This lives in its own repository (rather than inside the nix fork) so that
GitHub Actions `workflow_dispatch` works out of the box and fleet config stays
independent of the upstream source tree.

## Why it's built this way

Claude Code web sessions run in a sandbox whose only egress is Anthropic's
HTTP/HTTPS proxy — **there is no outbound SSH (port 22)**. So the usual
SSH-based deploy tools (`nixos-anywhere`, `nixos-rebuild --target-host`,
`colmena`, `deploy-rs`) can't run from a web session.

Instead this uses a **GitOps pull model**: each builder runs
[`comin`](https://github.com/nlewo/comin), which polls this repo over HTTPS and
rebuilds itself to `nixosConfigurations.<hostname>` on every push to `main`.
A web session deploys by editing files and pushing.

```
web session  --git push-->  this repo  <--HTTPS poll--  comin on each builder --> nixos-rebuild switch
web session  --workflow_dispatch--> GH-hosted runner --SSH--> builder   (bootstrap & health checks only)
```

## Layout

| File            | Purpose                                                              |
| --------------- | -------------------------------------------------------------------- |
| `flake.nix`     | `nixosConfigurations.<host>` for each builder; inputs (nixpkgs/comin/disko) |
| `builder.nix`   | The deployable config: nix-daemon builder role, `comin`, SSH, status reporter |
| `disko.nix`     | Deterministic disk layout (BIOS/GRUB, ext4 root), applied by nixos-anywhere |
| `keys/ci-builder.pub` | Authorized key for the `nixremote` ssh-ng:// build user (populate this) |
| `provision.sh`  | Sandbox-runnable server creation via the Hetzner HTTPS API (no SSH)  |
| `.github/workflows/bootstrap-builder.yml` | One-shot nixos-anywhere install of a fresh server |
| `.github/workflows/builder-check.yml`     | On-demand SSH health probe, readable from web sessions |
| `.github/workflows/redeploy-fork.yml`     | Auto-tracks the fork branch: bump pin, prebuild to Cachix, push to main |
| `.github/workflows/builder-protocol-tests.yml` | Staged end-to-end tests of remote building over ssh-ng (see below) |
| `tests/remote-build.nix` | Zero-dependency probe derivation the protocol tests build remotely |

## One-time setup

1. **Hetzner**: a read/write API token and an SSH key in the project whose
   private half is the `BUILDER_SSH_PRIVATE_KEY` Actions secret here.
2. **Web environment** (claude.ai/code environment dialog): Custom network
   access including `api.hetzner.cloud`; `HCLOUD_TOKEN` env var; setup script
   from `web-setup.sh`.
3. **Secrets on builders** (optional, delivered out-of-band): a `state:write`
   GitHub token at `/run/keys/github-status-token` to report deploy convergence
   as commit statuses.

## Bootstrap a builder

```bash
# 1. Create the server (runs in a web session; HTTPS only):
HETZNER_SSH_KEY=hetzner-bootstrap COUNT=1 SERVER_TYPE=cx33 NO_INFECT=1 ./provision.sh
# 2. Dispatch the bootstrap-builder workflow with host=nix-builder-NN and the
#    server's IP. A GitHub-hosted runner kexecs the server and installs the
#    flake config, disko layout included.
# 3. The final workflow step verifies the host rebooted into NixOS with comin
#    active. Later health checks: dispatch builder-check with the IP.
```

Do **not** switch a `nixos-infect`ed machine onto this flake: the disko layout
here describes what nixos-anywhere creates, not an infected image's partitions.

## Automatic redeploys on fork pushes

The `redeploy-fork` workflow keeps the fleet tracking
`Takishima/nix@claude/single-branch-pr-split-xpy8oq` automatically: it bumps
the `nix-fork` pin in `flake.lock`, builds the fork's `nix-cli` and pushes its
closure to Cachix, then commits the lock bump to `main` — at which point comin
redeploys every builder within ~60s. A failed build never reaches `main`, so
the fleet keeps the last working pin.

Out of the box it polls the fork branch every 10 minutes (and can be kicked
manually via `workflow_dispatch`, or from a web session by bumping the nonce in
`redeploy/request.json`). For true per-commit redeploys, add this notifier to
**Takishima/nix** with a `BUILDER_INFRA_DISPATCH_TOKEN` secret (fine-grained
PAT, `contents: read & write` on this repo):

```yaml
# Takishima/nix: .github/workflows/notify-builder-infra.yml
name: notify-builder-infra
on:
  push:
    branches: [claude/single-branch-pr-split-xpy8oq]
jobs:
  dispatch:
    runs-on: ubuntu-latest
    steps:
      - run: |
          curl --fail -X POST \
            -H "Authorization: Bearer ${{ secrets.BUILDER_INFRA_DISPATCH_TOKEN }}" \
            -H "Accept: application/vnd.github+json" \
            https://api.github.com/repos/Takishima/nix-builder-infra/dispatches \
            -d '{"event_type":"nix-fork-push"}'
```

Note: GitHub disables `schedule` triggers on repos with no activity for 60
days; the notifier (or a manual dispatch) is immune to that.

## Builder protocol tests

The `builder-protocol-tests` workflow validates that a deployed builder works
as an ssh-ng:// remote builder, in stages (each stage gates the next):

1. **preflight** — SSH sanity probe; hard-fails if the daemon lacks the
   `build-coordinator` experimental feature (enabled by `builder.nix`).
2. **single-build** — one fresh derivation (`builtins.currentTime` tag, so it
   can never be a cache hit) builds remotely. Runs twice: with a **stock**
   upstream Nix client (old wire protocol) and with the **fork** client
   (new protocol features negotiated in the handshake).
3. **concurrent-builds** — two *different* fresh derivations submitted at
   once; builder-side start clocks in the logs prove the executions
   overlapped. Again for both client flavours.
4. **dedup** — the new coordinator feature: a single `.drv` is evaluated up
   front, then two clients (separate local stores) build it concurrently while
   it holds itself in-flight ~30s. Passing means the builder ran ONE build:
   the late joiner received the replayed pre-attach log marker and both
   clients saw the same build token.

Trigger via `workflow_dispatch` (inputs: `target_ip`, `hold_seconds`) or, from
a web session, by bumping the nonce in `tests/request.json` and pushing to
`main`. The test derivation (`tests/remote-build.nix`) has no inputs at all —
its builder is the sandbox's `/bin/sh` — so only the `.drv` itself crosses the
wire, which is exactly the protocol path under test.

## Everyday config deploys

1. Edit `builder.nix` (or hostnames in `flake.nix`).
2. Validate: `nix flake check` /
   `nix eval .#nixosConfigurations.nix-builder-01.config.system.build.toplevel.drvPath`
3. Push to `main`. comin converges each builder within ~60s.
4. Observe via the `builder-check` workflow, or commit statuses if the status
   token is installed on the builders.

## Recovering a wedged builder

On fork revisions whose local-build path is broken, a failed comin deploy can
leave coordinator processes behind (inside the comin cgroup) holding the
exclusive store lock; from then on every daemon build session hangs a few
minutes and dies with "Nix daemon disconnected unexpectedly". The
`builder-ops` workflow is the remote-hands fix (`workflow_dispatch`, inputs
`target_ip` + `action`):

- `status` — units, nix processes, recent comin journal; read-only.
- `recover` — stop comin (killing the stale cgroup), restore the
  socket-activated nix daemon. Leaves comin stopped: start it again only once
  a working fork pin is on `main`, or every deploy attempt can re-wedge the
  box.
- `start-comin` — resume GitOps deploys.
- `reboot` — boot the current generation from scratch.

If the machine is beyond that, reinstall it in place with the
`bootstrap-builder` workflow (~5 min, wipes the disk; the builders are
stateless), which builds the system runner-side and so does not depend on the
on-box daemon at all.
