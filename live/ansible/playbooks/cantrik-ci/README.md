# cantrik-ci — the one runner that holds `/dev/kvm`

A plain GitHub Actions runner installed directly on a VM. **Not fireactions**,
and the reason is not a preference.

## Why not fireactions

oprek.sh splits CI into two tiers, and the split is **by what can host
`/dev/kvm`**, not by speed:

| Tier | Runs | Where |
| --- | --- | --- |
| 0 | builds, unit tests, `tofu validate`, **and the guest-kernel build** | fireactions — one ephemeral Firecracker microVM per job |
| 1 | boot a real Machine on the Firecracker / jailer / kernel under test, and SSH in | **here** |

A fireactions job runs **inside** a Firecracker microVM, and Firecracker cannot
expose VMX/SVM to its guest — oprek.sh ADR-0021, stated in `design.md` §6.1 as
*"nested virtualization (Kata, QEMU, Incus VMs, **Firecracker-in-Playground**) is
impossible without it."* So a fireactions job has no `/dev/kvm` and cannot start
a Machine. No fireactions configuration fixes this; it is a property of the VMM.

Tier 1 is the **only** test that proves a Firecracker, jailer, guest-kernel, or
CNI bump. Every Tier 0 check can pass on a kernel that does not boot.

## Why it is a separate VM

A self-hosted runner executes repository code on a box holding `/dev/kvm`.
On `cantrik-01/02/03` that would be a direct path from "a bot opened a PR" to
root beside other Users' Machines.

This bounds the blast radius. It does not eliminate it — a breakout still lands
on `petruk-pve0`, which oprek.sh ADR-0026 already says the Workers share.

## Why the kernel *build* is not here

Building a kernel needs cores and memory; it does not need KVM. Keeping it on
fireactions is what lets this VM be 4 vCPU / 8 GiB on a node the fireactions
unit records as **already overcommitted** — 251.5 GiB physical against 274.0 GiB
allocated. Read that comment before growing this box.

## Running it

```bash
ansible-playbook \
  -i inventories/petruk-pve/petruk-pve0/pve-vms/cantrik-ci/inventory.yaml \
  playbooks/cantrik-ci/install-runner.yaml \
  -e github_runner_pat="$(gh auth token)"
```

The PAT needs only `repo` scope on `oprek-sh/oprek.sh`. It is used **once**, to
mint a registration token that expires in about an hour, and is never written to
disk or logged. Registration tokens are not stored because they cannot usefully
be.

## Targeting a job here

```yaml
runs-on: [self-hosted, cantrik-ci, kvm]
```

**`kvm` is the label that matters.** A job that does not name it must never land
here — that is what keeps ordinary CI on the ephemeral fireactions runners, and
it is a security boundary rather than a routing convenience.

## What this host deliberately does not install

Firecracker, jailer, and the guest kernel. A Tier 1 job installs the versions
**under test** itself. Installing them from this playbook would test this file
rather than the pin, which defeats the point of oprek.sh ADR-0035.

## The weak point, stated plainly

The runner is not re-imaged between jobs. `--ephemeral` unregisters it after one
job and systemd starts a fresh one, so state does not silently carry forward
inside the runner's own bookkeeping — but the **filesystem does**. Tier 0 gets a
new microVM per job; this tier structurally cannot, because the thing it needs is
the host.

Two things keep that acceptable, and both are conditional:

- **The repository is private**, so there are no fork pull requests from
  strangers and every job runs code from someone with write access.
- **The runner account has no sudo.** Its only grant is `kvm` group membership,
  which means "may start a VM", not "may become root".

If `oprek-sh/oprek.sh` ever goes public, the first of those disappears and the
workflow needs
`if: github.event.pull_request.head.repo.full_name == github.repository`.
Never `pull_request_target` on this runner, under any visibility.
