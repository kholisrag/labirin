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

**One container, no volumes.** Both pieces of state live somewhere that already
exists — payloads in RustFS, index in the PostgreSQL the panel already runs.

| Piece | Role |
| --- | --- |
| `github-actions-cache-server` container | The server itself, on `127.0.0.1:3400` |
| [RustFS](../rustfs/README.md) bucket `gha-cache` | Every byte of every cache archive |
| 1Panel's **PostgreSQL app install** | Cache index, leases, upload state |
| `1panel-network` (external) | How the container reaches that database |
| 1Panel Compose (`from: edit`) | Owns the stack; panel writes the files |
| 1Panel website + OpenResty | TLS termination for `<cache-host>` |

## Layout

```text
live/ansible/playbooks/gha-cache/
├── install-gha-cache.yaml      # entrypoint — talks to the 1Panel API
├── templates/
│   └── docker-compose.yml.j2   # one service, pushed as `file`/`content`
└── vars/
    ├── main.yaml               # version, ports, budget, network
    └── vault.yaml              # the database coordinate (ansible-vault)
```

The reverse proxy is **not** here — it lives with the other 1Panel websites:

```text
live/ansible/playbooks/1panel/
├── vars/main.yaml                         # the <cache-host> entry
└── templates/proxy-gha-cache.conf.j2      # the nginx location block
```

S3 credentials are **not** here either. `install-gha-cache.yaml` reads them from
`../rustfs/vars/vault.yaml`, so a RustFS key rotation is one edit rather than two
files that can drift apart.

## Where the traffic actually goes

```text
  runner microVM
        |  ACTIONS_RESULTS_URL=https://<cache-host>
        v
  1Panel VM (10.10.99.10) — OpenResty, network_mode: host
        |  TLS terminated with the *.<internal-domain> wildcard
        |  http://127.0.0.1:3400
        v
  cache server container, same VM, published on loopback only
        |
        +--> postgresql container, over 1panel-network   (index, leases, uploads)
        |
        +--> https://<s3-host>/gha-cache
                    |  an Unbound alias onto THIS host, so back out
                    |  through OpenResty, TLS terminated there
                    v
              rustfs-01 (10.10.99.14) — /data/rustfs0
```

`127.0.0.1` in the proxy config is doing real work and is not a copy-paste slip.
1Panel's OpenResty runs with `network_mode: host`, so its loopback *is* the
host's loopback. That is what lets the server publish on `127.0.0.1:3400`
instead of `0.0.0.0:3400` — the TLS website becomes the only way in.

**The RustFS hop looks like a detour and is meant to.** `<s3-host>`
is an Unbound alias onto `<panel-host>`, so a container on this box
resolves it to its own host, hits OpenResty, and is proxied on to
`10.10.99.14:9000`. Pointing `AWS_ENDPOINT_URL` straight at that address would
save a hop and would also drop TLS on the wire and give this one client a
different endpoint string from every other S3 client on the LAN. Don't.

One name, because there is no second guest to address:

| Name | Resolves to | For |
| --- | --- | --- |
| `<cache-host>` | Unbound **alias** → `<panel-host>` | Every runner. Nothing else. |

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
`unbound_host_aliases`, pointing `actions-cache` at `<panel-host>` —
the same shape as the existing `goproxy` alias. No `dnsmasq_hosts` reservation
and no A record: there is no new guest to address.

```yaml
  - target: "<panel-host>"
    alias: "actions-cache"
    domain: "<internal-domain>"
    description: "Alias for GitHub Actions Cache Server"
    enabled: true
    state: "present"
```

```bash
ansible-playbook live/ansible/playbooks/opnsense/manage-local-dns.yaml \
  -e opnsense_host=opnsense.<internal-domain>
```

> [!NOTE]
> `opnsense_host` in that vault is `opnsense.<public-zone>`, which does not resolve
> from a workstation whose `/etc/resolver/` only covers `<internal-domain>`.
> Hence the `-e` override — same box, and the wildcard covers it, so TLS still
> verifies.

### 2. The bucket

**The playbook does not create it**, and the server will not create it either:
`S3Adapter.fromEnv()` sends a `HeadBucket` at startup and refuses to start with
`Bucket gha-cache does not exist`. RustFS has no Ansible module here, so this is
a hand step — in the console at <https://<console-host>>, or:

```bash
aws --endpoint-url https://<s3-host> s3 mb s3://gha-cache
```

No bucket policy, no lifecycle rule. Retention is the cache server's job — see
[Retention](#retention) — and a bucket-side expiry would delete objects the
database still has rows for.

### 3. The database

**This is the step that is easiest to skip and hardest to diagnose.** The stack
carries no Postgres of its own; it uses the PostgreSQL that 1Panel already runs
as an app install, alongside the databases for the other apps on that box.

Create it in the dashboard — **Databases → PostgreSQL → Create** — and then copy
what the panel shows you into the vault. Three things matter:

- **1Panel appends a random suffix to the name you type.** Ask for `gha_cache`
  and you get something like `gha_cache_a1b2c3`. The vault has to carry the
  *generated* name, which is why nothing in this repo dictates one.
- **1Panel mints the user and the password too**, and records them in its own
  store. A database created by hand with `psql`, behind the panel's back, will
  not appear in *Databases* and will not pass the playbook's preflight.
- **The playbook will not create it.** Creating a database is a dashboard
  action; doing it over the API from here would produce a database the panel
  does not know it owns.

### 4. Secrets

```bash
sops -d .vault_pass.enc > .vault_pass && chmod 600 .vault_pass
ansible-vault edit live/ansible/playbooks/gha-cache/vars/vault.yaml
```

The vault ships with `vault_gha_cache_db_host` and `vault_gha_cache_db_port`
already correct, and with **`CHANGEME` placeholders** for the name, user and
password from step 3. The playbook's first assertion fails while they are still
in place, so a half-configured vault costs ten seconds rather than a
crash-looping container.

If you set a password of your own rather than accepting the generated one, keep
it alphanumeric: it reaches the container through the stack's `.env`, which
Docker Compose parses and expands `${...}` inside, so a `$` or a quote becomes a
parse surprise that presents as authentication failing against a database that
is running perfectly.

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

### What the preflight checks, and what it cannot

Four things, all read-only against the panel's API, all before the compose file
is pushed:

| Check | Catches |
| --- | --- |
| host port `3400` unpublished | a clash that would leave a stack that will not start |
| `1panel-network` exists | `external: true` failing at `compose up` |
| an app install runs the configured container | the database being stopped or renamed |
| the configured database is in the panel's list | a typo'd or uncreated database |

**The password is not among them.** The panel holds it, but reading it back to
compare would put a live credential through this playbook for no gain, so a
wrong password is the one failure left to the container's own log.

## Verify

```bash
curl -fsS https://<cache-host>/health     # -> healthy
```

That is the only unauthenticated endpoint. Everything else wants a runner token,
so the real test is a workflow: run one twice and look for `Cache restored from
key:` on the second pass.

```bash
# what is actually stored
aws --endpoint-url https://<s3-host> \
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

**Path style and TLS trust both need nothing set, which is worth knowing before
you go looking for the knob.** `forcePathStyle: true` is hardcoded upstream and
is not exposed as an environment variable — which happens to be exactly what
RustFS needs, since `RUSTFS_SERVER_DOMAINS` is unset there and virtual-host
style would address `gha-cache.<s3-host>`, a name with neither a
DNS alias nor certificate coverage. And the wildcard is a public Let's Encrypt
certificate that Node verifies against its own compiled-in Mozilla root set
rather than the OS store, so the image's package list does not come into it. If
verification ever does fail, the fix is `NODE_EXTRA_CA_CERTS` — **never**
`NODE_TLS_REJECT_UNAUTHORIZED`.

**nginx's 1 MiB default body cap 413s the first cache save.** A cache smaller
than the client's chunk size arrives as one PUT, so the cap has to cover a whole
archive rather than a chunk. `proxy-gha-cache.conf.j2` sets `client_max_body_size
2g` and turns `proxy_request_buffering` off — without the second one nginx
spools every upload to the 1Panel guest's 50 GiB root disk before forwarding a
byte.

**Joining `1panel-network` puts this container next to every other app on the
box.** That is the price of reaching the panel's PostgreSQL by name, and it is
the same position every 1Panel app install is already in. The alternative —
reaching Postgres over the host — does not work as written, because Postgres
publishes on `127.0.0.1:5432` and a container's `127.0.0.1` is its own loopback,
not the host's; it would need an `extra_hosts` host-gateway mapping or the
bridge gateway address, both more fragile than a network name the panel
maintains itself.

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
row after `ORPHANED_STORAGE_GRACE_PERIOD_HOURS` (24). It also means this stack
is no longer self-contained — restoring the 1Panel guest has to bring the
PostgreSQL app install back before this container will start at all.
