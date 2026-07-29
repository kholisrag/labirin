# monitoring — Prometheus + Grafana

One 1Panel Compose stack on the 1Panel guest, two services, two TLS websites.

```bash
# 1. the stack
ansible-playbook live/ansible/playbooks/monitoring/install-monitoring.yaml

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

The two services in this stack, and nothing else. Prometheus scrapes itself and
Grafana's `/metrics`, so the stack reports its own health from the first run.

That is deliberate, not an omission. Scraping the rest of the estate means an
exporter per guest — `node_exporter` on the PVE hosts, cAdvisor for this box's
containers, Harbor's and RustFS's own endpoints — and each is its own playbook
and its own firewall decision. Adding one once the exporter exists is an entry
in `monitoring_scrape_configs` plus a re-run; the format and a worked example
are in the comment above that variable.

Targets there take the guest's **IP**, for the same reason `upstream` does in
`../1panel/vars/main.yaml`: the addresses are static DHCP reservations keyed on
the VM's MAC, so they are as stable as the name and do not make scraping depend
on Unbound being up.

Alertmanager is not here either. It is a third container plus a routing decision
— who gets woken, on what, through ntfy or e-mail — which is a playbook, not an
empty stanza pretending to be wired up.

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
| `install-monitoring.yaml` | the whole thing — stack, config, websites' prerequisites |
| `vars/main.yaml` | versions, ports, retention, scrape targets |
| `vars/vault.yaml` | the two hostnames, the Grafana bootstrap credentials |
| `templates/docker-compose.yml.j2` | the stack |
| `templates/prometheus.yml.j2` | rendered from `monitoring_scrape_configs` |
| `templates/grafana-datasource.yml.j2` | the provisioned Prometheus datasource |
| `../1panel/templates/proxy-grafana.conf.j2` | websockets for Grafana Live, long timeouts |
| `../1panel/templates/proxy-prometheus.conf.j2` | long timeouts, destructive paths denied |
