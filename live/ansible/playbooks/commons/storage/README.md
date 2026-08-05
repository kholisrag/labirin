# storage

`clean-storage.yaml` reclaims disk space on a Debian-family guest. It is
host-agnostic — point it at any inventory in this tree.

```bash
source .labirin_venv/bin/activate

ansible-playbook -i live/ansible/inventories/petruk-pve/petruk-pve0/pve-vms/cloudflared \
  live/ansible/playbooks/commons/storage/clean-storage.yaml
```

## A full disk breaks Ansible before it breaks the playbook

This is the failure that motivated it, and it does not look like a disk
problem:

```text
TASK [Gathering Facts] *********************************************************
[ERROR]: Task failed: mkdir: cannot create directory
'/tmp/ansible-tmp-1785886323.066606-45077-165721258896029': No space left on device
fatal: [cloudflared_vm]: UNREACHABLE! => {"changed": false, ...}
```

`UNREACHABLE` reads as a connectivity or SSH problem. It is neither. Ansible
copies every module — **including the implicit `setup`** — into `remote_tmp`
before it can run it, and `ansible.cfg` sets that to `/tmp`. At 100% there is
nowhere to put it, so the run dies before task one and no ordinary playbook can
help.

So the first play here uses **`ansible.builtin.raw`** and nothing else, with
`gather_facts: false`. `raw` runs the command straight down the SSH channel and
needs neither a temp directory nor Python on the target. It frees the journal
and the apt cache — both pure deletes, which is what makes them work at zero
bytes free — and hands a usable filesystem to the second play, which uses
ordinary modules from there.

If even that is not enough, the playbook **stops with the reason** rather than
letting the next play repeat the `UNREACHABLE` above.

## What it removes

| | Default | Notes |
| --- | --- | --- |
| systemd journal | keep 100 MiB / 14 days | systemd's own default is 10% of the filesystem — 300 MiB of unread logs on a 3 GiB root |
| apt cache | emptied | every `.deb` in `/var/cache/apt/archives` is re-downloadable |
| orphaned packages | `autoremove --purge` | usually the biggest win: superseded kernels and their headers |
| rotated logs | older than 14 days | `*.gz`, `*.xz`, `*.zst`, `*.old`, `*.1`, … under `/var/log` |
| `/tmp`, `/var/tmp` | untouched for 7 days | by **atime**, not mtime — a file read daily is in use even if never rewritten |
| docker | **off** | `clean_storage_docker_prune=true` to enable, per run |

Every default is a play var, so override with `-e`:

```bash
ansible-playbook … clean-storage.yaml -e clean_storage_journal_max_size=50M
```

Tags: `journal`, `apt`, `logs`, `tmp`, `docker`.

## What it will not do

- **Delete a live log file.** Only rotated ones. Unlinking a log a daemon holds
  open frees nothing until that daemon restarts, which is a confusing way to
  discover the disk is still full.
- **Remove the running kernel.** `apt-get autoremove` already protects it; the
  playbook re-checks `/boot/vmlinuz-$(uname -r)` afterwards and fails loudly if
  it is ever wrong, because the cost of being wrong is a guest that does not
  come back from its next reboot.
- **Touch a service's data.** Nothing under `/data`, `/opt`, `/srv` or a
  compose volume is in scope.
- **Prune docker.** Not without being asked. Stopped containers and dangling
  images on a 1Panel box are frequently one `docker compose up` from wanted.

## `APT SKIPPED` in the summary

Something holds `/var/lib/dpkg/lock-frontend` or `/var/lib/apt/lists/lock`, so
the apt reclaim did not run. The playbook checks before it tries, because
`ansible.builtin.apt` waits `lock_timeout` seconds and then fails with

```text
Failed to lock apt for exclusive operation
```

which names neither the holder nor how long it has been there — and it aborts
the play, so the log and scratch reclaim never reaches the host that needed it.
Skipping keeps the rest of the run useful and prints the holder with its
elapsed time.

**An `apt-get` measured in days is wedged, not busy.** `cloudflared` on
2026-08-05 had this, and it is the reason the check exists:

```text
240949 61-19:58:58 apt-get -qq -y update
```

61 days, from `apt.systemd.daily`, stuck on the disk that was already full —
and still slowly refilling `/var/cache/apt` behind the cleanup, which is how a
run reclaims a *negative* number of MiB. Clear it before re-running:

```bash
sudo systemctl stop apt-daily.service apt-daily-upgrade.service
sudo kill <pid>          # SIGKILL only if it does not go
```

Safe for an `update`: it holds the **lists** lock, not the dpkg one, so there
is no half-applied package state to corrupt. Confirm that first —
`sudo fuser -v /var/lib/dpkg/lock-frontend` returning nothing is the check.

## `REBOOT PENDING` in the summary

Means the running kernel is not the newest installed one:

```text
REBOOT PENDING: running 6.8.0-106-generic, newest installed 6.8.0-124-generic.
Superseded kernels cannot be autoremoved until the running one is the newest one.
```

`autoremove` keeps two kernels — the running one **and** the newest installed —
so a guest that takes kernel updates and never reboots accumulates all of them,
at roughly 300 MiB each once headers and `linux-tools` are counted. The pile
only collapses on the reboot that makes those two the same package. Until then
this playbook has found everything it can and the space is still gone.

## When cleaning is the wrong answer

The playbook reports free space before and after. If the reclaim is small and
the guest is full again next week, it is not accumulating rubbish — the disk is
too small, and the fix belongs in the OpenTofu unit that sizes it, not here.

Check what the base install actually costs:

```bash
sudo du -xh --max-depth=1 / | sort -rh | head
sudo lsof -nP +L1        # space held open by files already deleted
```

`cloudflared` on 2026-08-05 is the worked example: 2.9 GiB root, of which
`/usr` alone is 2.0 GiB. No amount of log rotation fixes that shape.
