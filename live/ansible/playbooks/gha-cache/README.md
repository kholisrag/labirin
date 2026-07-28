# gha-cache

[github-actions-cache-server](https://github.com/falcondev-oss/github-actions-cache-server)
is a **drop-in replacement for GitHub's hosted Actions cache** — what
[Athens](../athens/README.md) is for Go modules and
[Harbor](../harbor/README.md) is for container images, but for `actions/cache`.
Workflows keep using `actions/cache` unchanged; only the endpoint the runner is
pointed at moves, so anything that caches *through* that action (`setup-go`,
`setup-node`, `docker/build-push-action`) comes along for free.

Like Athens and unlike Harbor, it does **not** get its own VM. It is a Compose
stack on the 1Panel guest, created through 1Panel's API so it appears in
*Containers → Compose* exactly like one made in the dashboard.

| Piece | Role |
| --- | --- |
| `github-actions-cache-server` container | The server itself, on `127.0.0.1:3400` |
| `postgres` container, same stack | Cache index, leases, upload state |
| [RustFS](../rustfs/README.md) bucket `gha-cache` | Every byte of every cache archive |
| 1Panel Compose (`from: edit`) | Owns the stack; panel writes the files |
| 1Panel website + OpenResty | TLS termination for `actions-cache.internal.khol.is` |

## Layout

```text
live/ansible/playbooks/gha-cache/
├── install-gha-cache.yaml      # entrypoint — talks to the 1Panel API
├── templates/
│   └── docker-compose.yml.j2   # both services, pushed as `file`/`content`
└── vars/
    ├── main.yaml               # version, ports, budget, database
    └── vault.yaml              # database password (ansible-vault)
```

The reverse proxy is **not** here — it lives with the other 1Panel websites:

```text
live/ansible/playbooks/1panel/
├── vars/main.yaml                         # the actions-cache.internal.khol.is entry
└── templates/proxy-gha-cache.conf.j2      # the nginx location block
```

S3 credentials are **not** here either. `install-gha-cache.yaml` reads them from
`../rustfs/vars/vault.yaml`, so a RustFS key rotation is one edit rather than two
files that can drift apart.

## Where the traffic actually goes

```text
  runner microVM
        |  ACTIONS_RESULTS_URL=https://actions-cache.internal.khol.is
        v
  1Panel VM (10.10.99.10) — OpenResty, network_mode: host
        |  TLS terminated with the *.internal.khol.is wildcard
        |  http://127.0.0.1:3400
        v
  cache server container, same VM, published on loopback only
        |
        +--> gha-cache-db, same stack       (index, leases, upload state)
        +--> https://rustfs.internal.khol.is/gha-cache
                    |  back out through OpenResty on the same box
                    v
              rustfs-01 (10.10.99.14) — /data/rustfs0
```

`127.0.0.1` in the proxy config is doing real work and is not a copy-paste slip.
1Panel's OpenResty runs with `network_mode: host`, so its loopback *is* the
host's loopback. That is what lets the server publish on `127.0.0.1:3400`
instead of `0.0.0.0:3400` — the TLS website becomes the only way in.

One name, because there is no second guest to address:

| Name | Resolves to | For |
| --- | --- | --- |
| `actions-cache.internal.khol.is` | Unbound **alias** → `1panel.internal.khol.is` | Every runner. Nothing else. |

## What actually keeps caches apart

The server verifies the runner's OIDC token on every request. `lib/scope.ts`
derives the JWKS URL as `{ACTIONS_TOKEN_ISSUER}/.well-known/jwks`, verifies the
signature against it, requires a `repository_id` claim, and then matches every
read and write on `repoId` plus `scope`.

**That is the whole boundary.** There is no second check, no allowlist, no
network ACL between one repository's cache and another's.

> [!WARNING]
> `SKIP_TOKEN_VALIDATION` replaces `jose.jwtVerify()` with `jose.decodeJwt()` —
> the token is decoded and **never verified**, with a single WARN line as the
> only trace. Anything that can reach the website could then present a
> self-signed token claiming any `repository_id` and read or overwrite that
> repository's cache.
>
> It is tempting while debugging, because a JWKS fetch failure and a genuinely
> bad token both surface as `401 Invalid token`. There is no variable for it in
> `vars/main.yaml` on purpose. Debug it by reading the container logs and
> checking that the box can reach `token.actions.githubusercontent.com`.

## Prerequisites

### 1. DNS

Add the alias in `live/ansible/playbooks/opnsense/vars/vault.yaml` under
`unbound_host_aliases`, pointing `actions-cache` at `1panel.internal.khol.is` —
the same shape as the existing `goproxy` alias. No `dnsmasq_hosts` reservation
and no A record: there is no new guest to address.

```yaml
  - target: "1panel.internal.khol.is"
    alias: "actions-cache"
    domain: "internal.khol.is"
    description: "Alias for GitHub Actions Cache Server"
    enabled: true
    state: "present"
```

```bash
ansible-playbook live/ansible/playbooks/opnsense/manage-local-dns.yaml \
  -e opnsense_host=opnsense.internal.khol.is
```

> [!NOTE]
> `opnsense_host` in that vault is `opnsense.khol.is`, which does not resolve
> from a workstation whose `/etc/resolver/` only covers `internal.khol.is`.
> Hence the `-e` override — same box, and the wildcard covers it, so TLS still
> verifies.

### 2. The bucket

**The playbook does not create it**, and the server will not create it either:
`S3Adapter.fromEnv()` sends a `HeadBucket` at startup and refuses to start with
`Bucket gha-cache does not exist`. RustFS has no Ansible module here, so this is
a hand step — in the console at <https://rustfs-console.internal.khol.is>, or:

```bash
aws --endpoint-url https://rustfs.internal.khol.is s3 mb s3://gha-cache
```

No bucket policy, no lifecycle rule. Retention is the cache server's job — see
[Retention](#retention) — and a bucket-side expiry would delete objects the
database still has rows for.

### 3. Secrets

```bash
sops -d .vault_pass.enc > .vault_pass && chmod 600 .vault_pass
ansible-vault edit live/ansible/playbooks/gha-cache/vars/vault.yaml
```

`vault_gha_cache_db_password` ships populated with 48 random alphanumeric
characters. **Keep it alphanumeric**: it reaches Postgres through the stack's
`.env`, which Docker Compose parses and expands `${...}` inside, so a `$` or a
quote becomes a parse surprise that presents as authentication failing against a
database that is running perfectly.

The 1Panel API key comes from `../1panel/vars/vault.yaml` and the S3 credentials
from `../rustfs/vars/vault.yaml` — same panel, same object store, not duplicated
here.

## Install

```bash
# 1. the stack
ansible-playbook live/ansible/playbooks/gha-cache/install-gha-cache.yaml

# 2. the website that puts TLS in front of it
ansible-playbook -i live/ansible/inventories/petruk-pve/petruk-pve0/pve-vms/1panel \
  live/ansible/playbooks/1panel/manage-websites.yaml
```

Both run against `localhost` and talk to the panel over HTTPS; neither needs SSH
to the 1Panel guest.

Re-running is safe. The playbook creates the stack the first time and pushes the
rendered compose file through `/compose/update` after that, so a version bump in
`vars/main.yaml` is a one-line change plus a re-run.

## Verify

```bash
curl -fsS https://actions-cache.internal.khol.is/health     # -> healthy
```

That is the only unauthenticated endpoint. Everything else wants a runner token,
so the real test is a workflow: run one twice and look for `Cache restored from
key:` on the second pass.

```bash
# what is actually stored
aws --endpoint-url https://rustfs.internal.khol.is \
  s3 ls s3://gha-cache/gh-actions-cache/ --summarize
```

## Pointing runners at it

**Not done here, and deliberately.** The runner-side variable is
`ACTIONS_RESULTS_URL`, and where it belongs — baked into the runner image, or
set as a workflow-level `env:` in the consuming repository — is an open
question that this playbook does not answer. Deploying the server and adopting
it are separate changes; until that one is made, this server is running and idle
and no workflow behaves differently.

## Retention

Two independent bounds, and only one of them can stop a busy week filling the
disk.

| Knob | Bounds | Value here |
| --- | --- | --- |
| `CACHE_MAX_SIZE_BYTES` | total size | 50 GiB |
| `CACHE_CLEANUP_OLDER_THAN_DAYS` | staleness | 90 days |

**The byte budget is not optional in practice.** It is optional in the schema,
and omitting it does not fall back to something sensible:
`enforceStorageBudget()` asks the adapter for filesystem usage, the S3 adapter
does not implement that, so with no explicit budget there is nothing to compare
against and the function returns immediately. The cache then grows without any
bound at all — which is [exactly the shape Athens has](../athens/README.md), on
this same shared hardware.

50 GiB of a 200 GiB single-disk XFS volume. A build cache is by definition
reconstructible — the worst a full eviction costs is one slow CI run — so it
should not crowd out data that is not. And upstream's ADR-0008 is explicit that
eviction runs only *after* an upload completes, with no reservations and no
capacity lock: concurrent completions can overshoot, so the gap between 50 and
200 GiB is headroom that is doing real work, not slack.

Steady state sits between 45 and 50 GiB — eviction triggers above the budget and
deletes in cache-recency order until usage is at most 90% of it.

## Things that will bite

**`API_BASE_URL` is the URL the runner is told to use, not the one the server
listens on.** It comes back in the Twirp `CreateCacheEntry` response as
`signed_upload_url` and in `GetCacheEntryDownloadURL` as the download URL. Point
it at `127.0.0.1` or at the container name and every cache save fails from the
runner's side while the server's own logs look perfectly healthy.

**There is no `STORAGE_S3_ENDPOINT`.** Looking for one is how an afternoon goes
missing. `lib/storage.ts` builds its `S3Client` with `region`, `forcePathStyle`
and a request handler and **no `endpoint` key at all**, so the endpoint comes
from the AWS SDK's own config resolution. `AWS_ENDPOINT_URL` is the variable
this project declares in `lib/schemas.ts`, exercises in `tests/setup.ts` and
ships in its Helm chart. Omit it and the SDK quietly resolves the real Amazon
endpoint for `AWS_REGION`; the failure is a signature or DNS error that reads
like a RustFS problem.

`forcePathStyle: true` is hardcoded upstream, which is exactly what RustFS
needs — `RUSTFS_SERVER_DOMAINS` is unset there, so virtual-host addressing is
not available. Nothing to configure; it is just the reason the pair works.

**nginx's 1 MiB default body cap 413s the first cache save.** A cache smaller
than the client's chunk size arrives as one PUT, so the cap has to cover a whole
archive rather than a chunk. `proxy-gha-cache.conf.j2` sets `client_max_body_size
2g` and turns `proxy_request_buffering` off — without the second one nginx
spools every upload to the 1Panel guest's 50 GiB root disk before forwarding a
byte.

**Postgres 18 moved the data directory.** `PGDATA` is
`/var/lib/postgresql/18/docker` and the volume is `/var/lib/postgresql`, not the
`/var/lib/postgresql/data` every pre-18 example shows. Mount the old path
against an 18 image and Postgres initialises a fresh empty cluster inside it and
reports success. A **major** version bump is a migration, not a tag change.

**No chown task, unlike Athens.** The official Postgres entrypoint starts as
root, chowns `PGDATA` to the `postgres` user on every start, and only then
re-execs itself under `gosu`. A root-owned bind mount is the expected input —
adding a `user:` to the service is what breaks it.

**1Panel answers a rejected request body with HTTP 200.** The status line is not
a result; the outcome is the `code` field in the JSON body. Every write task in
`install-gha-cache.yaml` checks `json.code` for this reason. See the same note
in [Athens' README](../athens/README.md) for the version of this that cost a
day.

**If everything returns 403 with `Server: openresty`, suspect the WAF before the
token.** 1pwaf is on by default for every 1Panel website and its stock header
rule substring-matches `TomcatBypass|Command|Base64`; that is what
`manage-waf-overrides.yaml` exists to narrow for the RustFS sites. Nothing the
cache protocol sends is currently known to trip it, so this site is **not** in
`onepanel_waf_ua_command_sites` — but a 403 whose body is HTML rather than JSON
is the WAF, not the cache server.

**The database is the index, not the cache.** Losing it does not lose the
objects, but it does orphan them: the cleanup job reaps storage with no matching
row after `ORPHANED_STORAGE_GRACE_PERIOD_HOURS` (24). Restoring the stack
without its Postgres volume means a cold cache and a day of quiet deletion, not
a broken server.
