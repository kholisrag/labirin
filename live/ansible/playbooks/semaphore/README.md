# Semaphore UI — the unattended Fireactions apply

A [Semaphore UI](https://semaphoreui.com/) Community stack on the 1Panel box,
running `../fireactions/install-fireactions.yaml` against the real inventory so
a merged pool change reaches all four Fireactions hosts without a person at a
terminal.

Two decision records govern this, and both live in the **platform repository's**
`docs/adr/` rather than here — cited by number because this tree is public and
that repository is not:

- **ADR-0119**, *"The apply is a Semaphore template, and the vault password
  never reaches a Fireactions host"* — why a central controller instead of a
  pull timer on each host, and why the vault password lives here rather than on
  the four machines that run untrusted CI inside microVMs.
- **ADR-0125**, *"The trigger is a poll"* — why there is no merge trigger, and
  what replaced it.

**Everything the playbook cannot do is in [Configuring Semaphore](#configuring-semaphore)
below, and the order there matters.** `install-semaphore.yaml` creates the
container. It does not create the project, the Key Store entries, the templates
or the schedules — those need a logged-in session the playbook does not have.

## What it runs, and what it deliberately does not

`--tags fireactions`, plus `always`.

That covers the Fireactions binary, its config template and the service, and
the preflight assertions that gate every unattended run. It excludes the
devmapper thin pool (**wiped on first run**), the guest kernel, containerd and
CNI — each either irreversible on a live host or needing a cold stop to
recover. None of it is what a pool-config change touches. ADR-0119 §E.

The play carries `serial: 1` and `max_fail_percentage: 0` **on the play
itself**, so one host applies at a time and a failure stops the roll — and a
run from your laptop gets the same protection. ADR-0119 §D.

## Install

Three steps, in order.

```bash
# 1. Generate this stack's own credentials and put them in the vault.
#    The vault file does not exist yet; this creates it.
ansible-vault create live/ansible/playbooks/semaphore/vars/vault.yaml
```

It needs these six keys. Generate the first three with the command below —
never by hand, and never reuse one from another service:

```bash
head -c32 /dev/urandom | base64   # run three times, once per key
```

| Key | What it is |
| --- | --- |
| `vault_semaphore_access_key_encryption` | **Not rotatable casually.** Encrypts every Key Store item at rest, including the Ansible vault password and the SSH key. Read from the environment at *every* start — never written to `config.json`. Lose it and every stored credential must be re-entered. |
| `vault_semaphore_cookie_hash` | Session cookie integrity. |
| `vault_semaphore_cookie_encryption` | Session cookie confidentiality. |
| `vault_semaphore_admin_user` | Bootstrap admin. **First run only** — `semaphore setup` runs only while `config.json` is absent. |
| `vault_semaphore_admin_password` | The same. Change it in the UI afterwards; editing the vault later does nothing. |
| `vault_semaphore_admin_email` | The same. |

`vault_semaphore_host` goes in `../opnsense/vars/vault.yaml` as an
`unbound_host_aliases` entry onto the 1Panel host, like every other name here —
otherwise it does not resolve and the website is unreachable.

None of the six may contain `$`, a quote, or a leading/trailing space: Docker
Compose parses the stack's `.env` itself and would expand or strip them. The
playbook asserts this before it writes anything.

```bash
# 2. Create the stack.
ansible-playbook -i live/ansible/inventories/petruk-pve/petruk-pve0/pve-vms/1panel \
  live/ansible/playbooks/semaphore/install-semaphore.yaml

# 3. Create the website, so it is reachable over TLS.
ansible-playbook -i live/ansible/inventories/petruk-pve/petruk-pve0/pve-vms/1panel \
  live/ansible/playbooks/1panel/manage-websites.yaml
```

## Configuring Semaphore

Log in as the bootstrap admin and **change the password first**.

### 1. Key Store — before anything that references it

| Type | Name | Contents |
| --- | --- | --- |
| SSH Key | `fireactions-ansible` | The private key for the `ansible` user on `fireactions_vm_01`…`_04`. |
| Vault Password | `labirin-vault` | The contents of `.vault_pass`. |

**The vault password is passed as `--vault-id=default@prompt`,** with Semaphore
answering the prompt. Leave the vault entry's name blank — Semaphore then uses
the literal identity `default`, which is what matches this repository's 13
whole-file vaults, none of which carries a `--vault-id` label.

`ansible.cfg` names `vault_password_file = ./.vault_pass`, and that file is
gitignored, so it is **absent from the clone Semaphore makes**. That is fine and
was checked rather than assumed: with a vault secret supplied on the command
line, ansible logs *"Error getting vault password file (default): … was not
found"* as a **warning** and decrypts normally. Do not "fix" `ansible.cfg` to
make the warning go away — a laptop run needs that line.

### 2. Repository, inventory, environment

- **Repository** — `https://github.com/kholisrag/labirin.git`, branch `main`,
  access key `None` (it is public).
- **Inventory** — type *File*, path
  `live/ansible/inventories/petruk-pve/petruk-pve0/pve-vms/fireactions/inventory.yaml`,
  SSH key `fireactions-ansible`.
- **Environment** — name `fireactions`. Under **Environment Variables**:

  | Variable | Value |
  | --- | --- |
  | `SEMAPHORE_PROJECT_ID` | this project's id, from the URL |
  | `SEMAPHORE_APPLY_TEMPLATE_ID` | the id of the template in step 3, from its URL |

  and under **Secrets**, one of type **Environment variable**:

  | Secret | Value |
  | --- | --- |
  | `SEMAPHORE_API_TOKEN` | an API token from *User Settings → API Tokens* |

  A secret rather than a variable so it is stored encrypted and never rendered
  into a task log.

### 3. Template — `fireactions-apply`

| Field | Value |
| --- | --- |
| App | Ansible |
| Playbook | `live/ansible/playbooks/fireactions/install-fireactions.yaml` |
| Inventory | the one above |
| Environment | `fireactions` |
| Vault | the `labirin-vault` entry, name left blank |
| Tags | `fireactions` |

Leave **Limit** empty — the play's own `serial: 1` is what sequences the hosts,
and a `--limit` here would silently narrow the roll to part of the fleet.

### 4. Template — `fireactions-gate`

| Field | Value |
| --- | --- |
| App | Bash |
| Script | `live/ansible/playbooks/semaphore/files/gate-fireactions.sh` |
| Repository | the one above |
| Environment | `fireactions` |

This is the piece that makes the schedule a trigger rather than a timer. It
compares the checked-out `HEAD` against the newest **successful**
`fireactions-apply` task's `commit_hash` and starts an apply only when they
differ — and refuses to start one while another is queued or running. Read its
header before changing it; both of those guards exist for a reason the script
states. ADR-0125 §B, §E.

### 5. Two schedules, and they do different jobs

| Schedule | Cron | Template |
| --- | --- | --- |
| gate | `*/5 * * * *` | `fireactions-gate` |
| reconcile | `0 4 * * *` | `fireactions-apply` |

The daily one is **ungated on purpose**. A broken gate looks exactly like a
repository that has not changed — nothing fires, nothing goes red — so the
second schedule bounds that at 24 hours. It costs one idempotent `changed=0`
run a day. ADR-0125 §F.

## Verifying

```bash
curl -fsS https://<semaphore host>/api/ping        # from any box on the LAN
```

Then, in order:

1. Run `fireactions-gate` by hand. With no apply on record it should fire one.
2. Watch `fireactions-apply`: **four hosts, one at a time**, each reaching
   *Assert Fireactions is running* before the next begins.
3. Run `fireactions-gate` again. It should log
   `already applied <sha> — nothing to do` and start nothing.

Step 3 is the one that matters. A gate that fires every five minutes forever is
the failure this design is most likely to have, and it is invisible except by
looking.

**Only a real pool roll proves the whole thing.** The play's assert proves a
host is *healthy*, never that it is on the *new* configuration — a silent no-op
is indistinguishable from a clean apply. The task log is where that difference
lives, which is why the gate exists to keep it free of no-op runs.
ADR-0119 §D, ADR-0125 §E.

## Known limits

- **Semaphore down means nothing applies.** It fails to the status quo — a
  person at a terminal — which is safe, but the pull design it replaced would
  have degraded per host. ADR-0119 §H.
- **This box is now a high-value target**: SSH to four hosts plus the estate
  vault password, behind a login page. ADR-0119 §C argues it is still the better
  placement than four CI hosts; it does not argue the target is cheap.
- **`ansible-core` is unpinned in `requirements.txt`, and the image tag is the
  only pin there is.** `semaphore_version` selects the image, which ships
  `ansible==13.5.0` in its own venv — so moving that tag moves the Ansible that
  renders every template here, with no commit in this repository in between.
  ADR-0119 §H.
- **`curl`, `jq`, `git` and `bash` for the gate come from the same image** and
  are pinned by nothing else. ADR-0125 §H.
