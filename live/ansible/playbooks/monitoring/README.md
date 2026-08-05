# monitoring — Prometheus + Grafana

One 1Panel Compose stack on the 1Panel guest, two services, two TLS websites —
plus `node_exporter` on the four [Fireactions](../fireactions/README.md) hosts,
which is the one part of this playbook that touches a machine other than the
1Panel guest.

**The Fireactions inventory is now required**, and the run fails without it
rather than quietly installing no exporter and scraping no host:

```bash
# 1. the stack, and node_exporter on the Fireactions hosts
ansible-playbook -i live/ansible/inventories/petruk-pve/petruk-pve0/pve-vms/fireactions \
  live/ansible/playbooks/monitoring/install-monitoring.yaml

# 2. the DNS aliases (first run only)
ansible-playbook live/ansible/playbooks/opnsense/manage-local-dns.yaml \
  -e opnsense_host=opnsense.<internal-domain>

# 3. the websites in front of them
ansible-playbook -i live/ansible/inventories/petruk-pve/petruk-pve0/pve-vms/1panel \
  live/ansible/playbooks/1panel/manage-websites.yaml
```

Names are vaulted — `ansible-vault view live/ansible/playbooks/monitoring/vars/vault.yaml`.
The Grafana admin username and bootstrap password are in the same file.

## Why one stack and not two

Grafana has to reach Prometheus. In one stack they share a Compose network and
`http://prometheus:9090` resolves through Docker's embedded DNS, so the query
never leaves the box and the datasource works before any website exists. Split
into two stacks they land on different bridge networks, and Grafana's only route
to Prometheus is out to the host and back in through `host.docker.internal` — a
second path to keep working, for nothing.

The loopback publishes (`127.0.0.1:9090`, `127.0.0.1:3500`) exist for OpenResty,
not for Grafana. OpenResty runs `network_mode: host` on this guest, so its
loopback *is* the host's, and the TLS websites are the only way in from the LAN.

## Ports

`3500` for Grafana rather than its default `3000`, because Gitea already holds
`3000` on this box — the same collision Athens hit. It continues the `3300`
(Athens) / `3400` (gha-cache) sequence. Prometheus keeps its own `9090`, which
was free.

`install-monitoring.yaml` preflights both against the panel's live container
list and fails before creating anything, because docker reports a port clash
only *after* the stack is recorded — leaving a stack that exists and will not
start.

Three files have to agree on those numbers and nothing links them:
`vars/main.yaml` here, `upstream` in `../1panel/vars/main.yaml`, and the
`ports:` in `templates/docker-compose.yml.j2` (which reads this file, so really
it is two).

## Prometheus has no authentication

This is the trade this playbook makes, stated rather than buried.

Prometheus ships no login. `prometheus.<internal-domain>` therefore lets any
host on the LAN that can resolve it read every metric and run any query. That is
accepted for a homelab — the alternative is an auth proxy in front of a metrics
UI — but the destructive surface is bounded in two places that must stay in
agreement:

- **`--web.enable-lifecycle` and `--web.enable-admin-api` are both off** (the
  `command:` block in `templates/docker-compose.yml.j2`). Without them `/-/quit`,
  `/-/reload` and the delete-series API do not exist.
- **`../1panel/templates/proxy-prometheus.conf.j2` returns 403** for those paths
  anyway, so flipping a flag "just for a moment" does not silently publish them.

Grafana is the authenticated view and is where a browser should normally land.
Its own front door is `GF_USERS_ALLOW_SIGN_UP: "false"` — already the default,
set explicitly because it is the setting that decides whether a stranger can
mint themselves an account against an unauthenticated backend.

**Turning the lifecycle API back on is not the way to reload config.** The
playbook restarts the container instead — see below.

## How a config change takes effect

`from: edit` writes `docker-compose.yml` and a sibling `.env`, and nothing else,
so `prometheus.yml` and the Grafana datasource go in through the panel's Files
API. Two things follow, and the second is the one that bites:

1. **`/api/v2/files/save` will not create a missing file** — it answers code 500
   `The target path does not exist!`. Every write is create-then-save, with the
   create tolerating the already-exists that is the steady state after run one.
2. **`docker compose up` on an unchanged service definition leaves the container
   alone.** Correct, and it means a run where *only* `prometheus.yml` moved
   brings nothing into effect — neither process re-reads its file while running.

So the playbook reads both files back before writing, and restarts only the
containers whose file actually changed. Skipped on the first run, where the
containers have just started against current files.

> [!WARNING]
> `POST /api/v2/containers/operate` answers `200 success` for a container name
> docker has never heard of. A typo there fails **silently** and presents as
> configuration that did not take effect. The names come from `vars/main.yaml`,
> which is also what the compose template names the containers — do not add a
> hand-typed name to that list.

## What it scrapes

Four jobs: this stack's own two, the
[Actions cache server](../gha-cache/README.md) next door, and `node_exporter` on
the [Fireactions](../fireactions/README.md) hosts.

| Job | Target | Why |
| --- | --- | --- |
| `prometheus` | `prometheus:9090` | the stack's own health, from the first run |
| `grafana` | `grafana:3000` | the same |
| `gha-cache` | `gha-cache:3000` | `cache_requests_total`, `cache_uploads_total`, `cache_storage_bytes` |
| `node` | each Fireactions host on `:9100` | the transmit counters — see [below](#node_exporter-on-the-fireactions-hosts) |

Everything else on the estate is still unscraped, and that is still the honest
state of it. `node_exporter` on the PVE hosts and cAdvisor for this box's
containers do not exist yet, and each is its own playbook and its own firewall
decision. Adding one is an entry in `monitoring_scrape_configs` plus a re-run;
the format and a worked example are in the comment above that variable.

A target on **another guest** takes that guest's **IP**, for the same reason
`upstream` does in `../1panel/vars/main.yaml`: the addresses are static DHCP
reservations keyed on the VM's MAC, so they are as stable as the name and do not
make scraping depend on Unbound being up. A target in **another stack on this
box** takes its container name, and is reached over the bridge below.

**The `node` job is the exception, and it is one because the addresses are not
knowable from here.** The Fireactions hosts are the only group in this tree with
no IP written down anywhere: their inventory carries A records so that it
resolves from something other than one operator's laptop, and the four targets
are read straight out of it. Writing four addresses here to satisfy the
preference would put the host list in a second place and make it wrong the first
time a reservation moved. The cost is that those four targets go down with
Unbound — visibly, as `up == 0`, which is forwarded.

Alertmanager is not here either. It is a third container plus a routing decision
— who gets woken, on what, through ntfy or e-mail — which is a playbook, not an
empty stanza pretending to be wired up.

### Reaching another stack

Prometheus joins **`1panel-network`** — 1Panel's own bridge, `external: true` —
alongside this stack's own network. `../gha-cache` is already on it, to reach
the panel's PostgreSQL.

**The obvious alternative does not work, and it is worth knowing before you try
it.** Every stack on this guest publishes on `127.0.0.1` only. A container's
`127.0.0.1` is its *own* loopback, and an `extra_hosts` host-gateway mapping
resolves to the bridge gateway address — which a port bound to the host's
loopback does not answer on. So there is no route over the host at all between
two stacks here; the shared bridge is not an optimisation, it is the only door.

**Scraping needs nothing opened.** `/metrics` on the cache server is
unauthenticated and is reached over the bridge, not through the TLS website — so
the WAF and the OIDC token check in front of that API are untouched. Nothing in
[`../gha-cache/vars/main.yaml`](../gha-cache/vars/main.yaml) had to move, and in
particular `SKIP_TOKEN_VALIDATION` is still absent and must stay that way.

**What it costs**, stated rather than buried: Prometheus becomes reachable from
everything else on that bridge, and Prometheus has no authentication. That is
bounded by the two flags the compose template deliberately does not set — with
no `--web.enable-lifecycle` and no `--web.enable-admin-api` there is no shutdown
and no delete-series API to reach — so what a neighbouring container gains is
the ability to *read* metrics that it is already exporting to this Prometheus
anyway. **Grafana deliberately does not join.** It talks only to Prometheus,
over this stack's own network, and it is the one service here holding
credentials.

> [!IMPORTANT]
> The port in a cross-stack target is the **container's**, not the published
> one. `gha-cache` is published on the host as `127.0.0.1:3400`, but that
> mapping does not exist on the bridge — over the network it answers on the
> `3000` it actually listens on. Using `3400` fails in the way that is hardest
> to spot: a connection refused every fifteen seconds, reported nowhere but the
> target page.

A cross-stack target is also a container name written *here* and defined
*elsewhere*, with nothing linking the two. `monitoring_required_containers` is
the list the playbook asserts against the panel's live container list before it
writes anything, so that drift arrives as a failed run rather than as a target
sitting `down` behind a query that returns no data.

## `node_exporter` on the Fireactions hosts

The first play of `install-monitoring.yaml` installs `node_exporter` on every
host in the `fireactions_all` inventory group, as a systemd unit under an
unprivileged system account, listening on `:9100`. It is in this playbook rather
than in a playbook of its own because the thing that installs the exporter and
the thing that scrapes it have to agree on a port and a host list, and two
playbooks are two places for those to drift.

### What it is for

Guests on this pool have been seen going quiet on the network while still
running — transmitting at a fraction of what they receive, and on two occasions
transmitting nothing at all for ten minutes, until the job they were running was
declared lost from the other end.

Every candidate still standing is host-side and on the transmit path: the
tap/veth pair, offload (GSO/TSO/GRO) on the tap or on the uplink, and a path-MTU
problem that only bites full-size segments. Two of the three fail by
**black-holing** rather than by slowing, and both surface the same way — as
transmit errors, drops or carrier losses on an interface of the *host*.

Nothing on this estate exported those counters, so every event so far has been
read from the far side, where a mute guest and a dead guest look identical.
**This is useless retroactively**: metrics that do not exist during an event
cannot be consulted after it, and there is no backfill. It has to be standing
before the next one.

### What leaves the box, and what does not

Three metric names are added to the remote-write allowlist:

| | |
| --- | --- |
| `node_network_transmit_errs_total` | the driver refused or failed the frame |
| `node_network_transmit_drop_total` | the frame was dropped on the way out |
| `node_network_transmit_carrier_total` | the link went away underneath it |

Everything else `node_exporter` produces — filesystem, CPU, memory, the whole of
netdev's receive side — stays in the local TSDB at full resolution for 90 days,
and is queryable from the Grafana on this box.

Those three are **per interface**, which is where the cost sits. The uplink,
`lo` and the CNI bridge are stable; the per-microVM veth is not, because a guest
is destroyed after each job and the next one comes back under a new name. At any
instant that is bounded by the pool replicas — ten guests a host — while over a
month it is however many jobs ran. The churn is the point: the per-guest
interface is exactly where a black hole would be, and a counter aggregated away
from it answers nothing.

### It is unauthenticated, on purpose

Prometheus lives on another guest, so `:9100` is bound on all interfaces and any
host on the LAN that can reach a Fireactions host can read its metrics. That is
the same trade Fireactions' own `:8081` already makes on those hosts and the
same one Prometheus makes on this one. The unit runs with `NoNewPrivileges`,
`ProtectSystem=strict` and `ProtectHome`, and the account has no shell — this
process reads `/proc` and `/sys` and writes nothing.

### Failure modes worth knowing

- **A run without the Fireactions inventory installs nothing.** Ansible answers
  an unmatched host pattern with `skipping: no hosts matched` and carries on, so
  the stack would come up with a `node` job that has no targets and looks
  configured. The second play asserts on the targets the first one recorded, and
  fails the run instead.
- **An unreachable Fireactions host does not block the stack.** The first play
  carries `ignore_unreachable: true`, and without it a play whose every host is
  unreachable ends the whole run — so Grafana could not be deployed or updated
  during exactly the outage you would want it for. The skipped host keeps its
  scrape target and shows up as `up == 0`.
- **The host list has one home.** The first play's `hosts:` is the only place it
  is named; the scrape targets are derived from that play's own host list on the
  way out. `hosts:` cannot itself be a variable — it is resolved before any
  `vars_files` are read — which is why the derivation runs at the end of the
  play rather than in `vars/main.yaml`.
- **The version check is the whole idempotency story.** `node_exporter
  --version` is compared against the pin in `vars/main.yaml`; a matching version
  skips the download entirely, and a bump reinstalls and restarts. Editing the
  unit template also restarts, through the handler. **Both streams are
  searched**, because kingpin has printed the version banner to stderr in some
  releases and reading only stdout there would reinstall on every single run.
- **The archive is pinned by checksum, not by tag.** `get_url` is given the
  release's `sha256sums.txt` and matches this asset by name, the same as
  `../fireactions/tasks/fireactions.yaml` — GitHub release assets are mutable.
- **The last task scrapes the exporter from the host itself.** That proves the
  process is up and listening, and *not* that Prometheus can reach it — that
  half is the `up` series, which is in the allowlist for exactly this reason.

## Shipping metrics to Grafana Cloud

Prometheus scrapes locally and forwards a **subset** onward. Nothing about what
is scraped or what is kept locally changes: remote write is a copy of samples as
they are ingested, and the 90d/20GB TSDB is unaffected.

**Why forward at all, given there is a Grafana on this box.** Because the local
one is on the same guest as everything it watches, behind the same OpenResty, on
the same disk. It is the right place to *look at* metrics and the wrong place to
be *told about* them — an outage that takes the box out takes the alert with it,
which is the failure mode of every homelab monitor that has only ever been
tested while the box was up.

### It is off until you configure it

Three values in the vault, all shipping as `CHANGEME`:

| Key | What |
| --- | --- |
| `vault_grafana_cloud_prom_url` | the Prometheus push endpoint |
| `vault_grafana_cloud_prom_username` | the numeric instance id |
| `vault_grafana_cloud_prom_password` | an Access Policy token, `metrics:write` |

While **any** of them is still the placeholder, no `remote_write` block is
rendered at all: Prometheus starts exactly as it did before, scrapes exactly
what it scraped before, and the run prints what to populate. That is not a
half-finished state — the alternative, asserting on them, would break a re-run
of a working stack for a feature nobody had asked to turn on.

```bash
sops -d .vault_pass.enc > .vault_pass && chmod 600 .vault_pass
ansible-vault edit live/ansible/playbooks/monitoring/vars/vault.yaml
ansible-playbook -i live/ansible/inventories/petruk-pve/petruk-pve0/pve-vms/fireactions \
  live/ansible/playbooks/monitoring/install-monitoring.yaml
```

All three come from the Cloud portal's Prometheus *Send Metrics* panel; the
token is minted under *Access Policies*. **Scope it to `metrics:write` and
nothing else.** This process only ever pushes, and a token that can also read or
delete turns a compromised guest into a compromised history.

The token is written to a file of its own at `0600` and read through
`basic_auth`'s `password_file`, rather than inlined. `prometheus.yml` is `0644`
and is the file that gets rendered in the panel's file browser, pasted into a
ticket and quoted in a diff; this one is neither. Same reasoning that puts the
Grafana admin password in the stack's `.env` instead of the compose file.

> [!NOTE]
> `password_file` is read at configuration load, not per request. A rotated
> token that is written and not bounced leaves Prometheus authenticating with
> the old one, and remote write then fails in the background with 401s that
> reach no scrape target and redden nothing. The playbook restarts Prometheus
> when that file changes, for exactly this reason.

A trailing newline in that file is **not** a problem, which is worth knowing
before you go looking for it: `FileSecret.Fetch` in `prometheus/common` returns
`strings.TrimSpace(string(fileBytes))`, so whatever the Files API appends is
stripped before the token is used. The playbook compares trimmed for the same
reason — otherwise every run would see a difference and bounce Prometheus.

### The allowlist, and why it is that way round

`monitoring_remote_write_keep_metrics` names the metrics that leave the box.
Anything else is dropped by a `write_relabel_configs` `keep` before it goes,
while the local TSDB still holds all of it at full resolution.

**Grafana Cloud bills on active series**, and the jobs above export well over a
hundred each — most of it the cache server's Node event-loop histograms, Go's
own process gauges and `node_exporter`'s several hundred defaults, which nobody
will open and all of which would be paid for every month. So the list is an
allowlist and is short on purpose. Getting it wrong in this direction costs a
missing series, which is visible; getting it wrong in the other direction costs
a bill.

`up` and `process_start_time_seconds` are on it for a reason that is easy to
trim by mistake. `up` is what distinguishes a target that stopped answering from
a target with nothing to say. `process_start_time_seconds` is what distinguishes
a counter reset from a genuine flatline — a restarted container zeroes every
counter it exports, and an alert reading those counters cannot otherwise tell
which happened.

`monitoring_external_labels` is attached to forwarded series only, so more than
one estate can push to the same stack without `up{job="prometheus"}` colliding.
Those two labels are **not** vaulted, unlike every hostname here: they are
already in this tree's directory names, they resolve nowhere, and a label whose
value is secret is a label nobody can paste into a ticket.

## The Grafana admin password is bootstrap-only

`GF_SECURITY_ADMIN_USER` / `GF_SECURITY_ADMIN_PASSWORD` are read **only** while
Grafana initialises an empty database. Once `./grafana/data` exists the account
lives in Grafana's own SQLite and editing the vault does nothing.

To rotate afterwards:

```bash
docker exec -it grafana grafana-cli admin reset-admin-password '<new>'
ansible-vault edit live/ansible/playbooks/monitoring/vars/vault.yaml   # keep them in step
```

Deleting `./grafana/data` to force a re-bootstrap also deletes every dashboard.

## The datasource is provisioned, so it is read-only in the UI

`templates/grafana-datasource.yml.j2` is written to
`grafana/provisioning/datasources/`, which Grafana reads at startup. A
provisioned datasource cannot be edited in the UI — that is the point: the stack
can be rebuilt from nothing and comes back wired up. `deleteDatasources` clears
a same-named hand-made one first so the two cannot collide.

It points at `http://prometheus:9090` — the **container** name and the
**container** port. Not the public name, which would send every panel refresh
out to OpenResty and back through a WAF that has no business in a query path,
and would make Grafana depend on the TLS website existing.

## Storage and ownership

Both images run unprivileged and neither can fix a bind mount it was handed:

| | uid:gid | Host directory |
| --- | --- | --- |
| Prometheus | `65534:65534` (`nobody`) | `prometheus/data` |
| Grafana | `472:0` | `grafana/data` |

Grafana's group `0` is not a privilege — the image chowns its data to `472:root`
so it works under an arbitrary uid on OpenShift, and the bind mount has to match
what the process actually runs as.

The playbook creates and chowns these **before** the stack comes up, because
docker creates a missing bind-mount source as a root-owned directory and the
result is a container restart-looping on a permission error.

> [!IMPORTANT]
> Quote the ids when calling `/api/v2/files/owner`. `FileRoleUpdate` declares
> `User` and `Group` as `string`; an unquoted number fails Gin's body binding and
> the handler never runs — HTTP 200, task green, directory still root-owned.

Retention is bounded on **both** axes —
`--storage.tsdb.retention.time=90d` and `--storage.tsdb.retention.size=20GB`.
The time bound is what you reason about; the size bound is what stops a
scrape-target explosion filling the guest's 50 GiB root disk, which is shared
with every other app on the box.

## Files

| Path | What it is |
| --- | --- |
| `install-monitoring.yaml` | the whole thing — the exporters, the stack, config, websites' prerequisites |
| `vars/main.yaml` | versions, ports, retention, scrape targets, the remote-write allowlist |
| `vars/vault.yaml` | the two hostnames, the Grafana bootstrap credentials, the Grafana Cloud coordinates |
| `tasks/node-exporter.yaml` | `node_exporter` on the Fireactions hosts |
| `templates/node-exporter.service.j2` | its systemd unit |
| `templates/docker-compose.yml.j2` | the stack |
| `templates/prometheus.yml.j2` | rendered from `monitoring_scrape_configs` |
| `templates/grafana-datasource.yml.j2` | the provisioned Prometheus datasource |
| `../1panel/templates/proxy-grafana.conf.j2` | websockets for Grafana Live, long timeouts |
| `../1panel/templates/proxy-prometheus.conf.j2` | long timeouts, destructive paths denied |
