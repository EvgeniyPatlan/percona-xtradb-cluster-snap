# percona-xtradb-cluster

Percona XtraDB Cluster (Galera) packaged as a strict-confinement snap: the
`percona-xtradb-cluster-server`, `percona-xtradb-cluster-client`, and
`percona-xtradb-cluster-garbd` packages staged unmodified from Percona's
official apt repository at `repo.percona.com` — nothing is compiled from
source. Two major versions are published as separate branches/tracks, each
pinned to an exact upstream package version (see below). Base: `core26`.

## Why this snap

Installing this snap gets a complete, self-contained Percona XtraDB Cluster
node: server, client tools, and the Galera Arbitrator (`garbd`), with every
package pinned to an exact upstream version rather than "whatever is latest
on 8.4". The install hook initializes the data directory and bootstraps a
single-node cluster automatically (`wsrep` enabled, empty `gcomm://`), and
switches `root@localhost` to `auth_socket` authentication, so there is no
separate setup step to get a running node. State Snapshot Transfer (SST)
uses Percona XtraBackup bundled inside the server package itself
(`xtrabackup-v2`) — no separate backup tool needs to be installed for a node
to join a cluster. Each supported major (8.4, 9.7) is a distinct
branch/track, so moving to a new major is an explicit channel switch rather
than something the snap decides for you on refresh.

## Tracks and branches

| Branch | apt source | Version | Status |
|---|---|---|---|
| `8.4/edge` | `repo.percona.com/pxc-84-lts/apt` (resolute, `main`) | 8.4.10-10 | GA |
| `9.7/edge` | `repo.percona.com/pxc-97-lts/apt` (resolute, `testing`) | 9.7.1-1 | Pre-GA — **does not currently build**, see below |

The `9.7/edge` branch is built from Percona's pre-GA testing repository
(`components: [testing]`, not `main`). The build is currently blocked
upstream: the pre-GA `.deb` declares `Depends: iproute`, a package name that
does not exist on the `resolute` archive this snap builds against (it was
renamed `iproute2`). This is tracked in-repo as a `TODO(9.7 GA)` comment in
`snap/snapcraft.yaml` on the `9.7/edge` branch, to be re-verified (including
the `pxc_extra/pxb-8.4` SST path and the prime lib-exclusion list) once
Percona fixes the dependency upstream.

## Getting the snap

### From a CI build

Every push to a `*/edge` branch, every pull request, and every manual
`workflow_dispatch` run of the `Tests` workflow builds the snap (amd64 and
arm64) and runs the full spread suite against it.

1. Open the workflow run in GitHub Actions and download the
   `snap-packages` artifact.
2. Unzip it.
3. Install:
   ```
   sudo snap install ./percona-xtradb-cluster_<version>_amd64.snap --dangerous --jailmode
   ```
   (substitute the `arm64` filename on that architecture).

### From source

```
git clone https://github.com/EvgeniyPatlan/percona-xtradb-cluster-snap.git
cd percona-xtradb-cluster-snap
git checkout 8.4/edge   # or 9.7/edge (currently fails to build, see above)
snapcraft pack
sudo snap install ./percona-xtradb-cluster_*.snap --dangerous --jailmode
```

Requires the `snapcraft` and `lxd` snaps.

Store channels exist for each track (`8.4/edge`, `9.7/edge`), but the
release workflow only publishes when the repository's `RELEASE_ENABLED`
variable is set, so Store availability isn't guaranteed.

## First steps

`mysqld` starts automatically on install and bootstraps a single-node
cluster. The install hook switches `root@localhost` to `auth_socket`
authentication, so connect locally without a password:

```
sudo percona-xtradb-cluster.mysql -u root
```

A TCP connection as `root@localhost` is denied by design — `auth_socket`
only accepts the local Unix socket — so create a dedicated user with a
password for TCP/network access.

## Services and apps

| App | Kind | Purpose |
|---|---|---|
| `mysqld` | daemon, auto-started | Cluster node, run under a supervisor loop that re-execs on the SQL `RESTART` statement (exit code 16) |
| `mysql` | CLI | interactive/batch SQL client |
| `mysqladmin` | CLI | server administration (ping, status, shutdown, …) |
| `mysqlcheck` | CLI | table check/repair/analyze/optimize |
| `mysqldump` | CLI | logical backup |
| `mysqlimport` | CLI | load delimited text files |
| `mysqlshow` | CLI | list databases/tables/columns |
| `mysqlslap` | CLI | load-testing/benchmark tool |
| `clustercheck` | CLI | Galera cluster health probe (HTTP-style response body) |
| `garbd` | daemon, disabled by default | Galera Arbitrator — a voting-only, dataless cluster member |

`mysqld` is enabled by default; `garbd` is disabled until configured (see
below):

```
sudo snap stop percona-xtradb-cluster.mysqld
sudo snap start percona-xtradb-cluster.mysqld
sudo snap restart percona-xtradb-cluster.mysqld
```

This snap also exposes a `mysql-sockets` content slot (`content:
socket-directory`, read/write on `$SNAP_DATA/run`) for other snaps that need
direct access to the cluster socket.

## Configuration and data paths

| Item | Path |
|---|---|
| Read-only defaults | `/snap/percona-xtradb-cluster/current/etc/my.cnf` (`!includedir` pulls in the directory below) |
| Editable config | `/var/snap/percona-xtradb-cluster/current/etc/mysqld.cnf` |
| `clustercheck` defaults file | `/var/snap/percona-xtradb-cluster/current/etc/clustercheck.cnf` (written by the install hook: `root` over the local socket) |
| Data directory | `/var/snap/percona-xtradb-cluster/common/data` (survives snap refreshes; auto-generated cluster-encryption SSL certificates — `*.pem` — also live here) |
| Error log | `/var/snap/percona-xtradb-cluster/current/log/error.log` |
| Slow / general / binlog logs | `/var/snap/percona-xtradb-cluster/current/log/{mysql-slow,query,mysql-bin}.log` (disabled by default; uncomment the relevant lines in `mysqld.cnf`) |
| Socket | `/var/snap/percona-xtradb-cluster/current/run/mysqld.sock` |
| X Protocol socket | `/var/snap/percona-xtradb-cluster/current/run/mysqlx.sock` (port 33060) |

## Joining an existing cluster

The install hook always bootstraps a fresh single-node cluster
(`wsrep_cluster_address = gcomm://`). To join an existing cluster instead,
edit `/var/snap/percona-xtradb-cluster/current/etc/mysqld.cnf`:

```
wsrep_cluster_address = gcomm://10.0.0.1:4567,10.0.0.2:4567
wsrep_node_address    = <this node's IP>
wsrep_node_name       = <unique node name>
```

then `sudo snap restart percona-xtradb-cluster.mysqld`. The address must be
set **before** the restart — a node that restarts with the default empty
`gcomm://` bootstraps a new single-node cluster instead of rejoining.
Cluster traffic encryption is on by default, so every node must share the
SSL certificates auto-generated in the first node's data directory
(`/var/snap/percona-xtradb-cluster/common/data/*.pem`) before it can join.

## Galera Arbitrator (garbd)

`garbd` ships disabled. Configure and start it with `snap set`:

```
sudo snap set percona-xtradb-cluster garbd.address=gcomm://<ip>:4567 garbd.group=<cluster-name>
sudo snap set percona-xtradb-cluster garbd.options="<extra galera options>"   # optional
sudo snap start percona-xtradb-cluster.garbd
```

Both `garbd.address` and `garbd.group` are required — the wrapper exits
with an error if either is unset. This is exercised in CI
(`garbd_membership` suite): starting `garbd` against a running node raises
`wsrep_cluster_size` from 1 to 2, and stopping it shrinks the cluster back
to 1.

## Health checks (clustercheck)

```
percona-xtradb-cluster.clustercheck
```

With no arguments, `clustercheck` runs as `root` over the local socket
using the defaults file the install hook writes
(`clustercheck.cnf`), and prints an HTTP-style response body (e.g. `200
OK` when the node is `Synced` and part of the `Primary` component) —
this is the exact form the `cluster_bootstrap` suite checks in CI. Any
arguments passed to the app are forwarded straight to the underlying
`clustercheck` script; for unprivileged use, create a MySQL user with the
`PROCESS` privilege and pass its credentials as arguments instead of
relying on the root defaults file.

## Backups with mysqldump

State Snapshot Transfer (node provisioning / rejoining the cluster) is
handled internally by the bundled XtraBackup
(`/snap/percona-xtradb-cluster/current/usr/bin/pxc_extra/pxb-8.4/bin/xtrabackup`,
driven by `wsrep_sst_xtrabackup-v2`) — it is not exposed as a standalone
snap app. For ad-hoc logical backups, use the `mysqldump` app.
`--single-transaction` is required, not optional: this cluster's default
`pxc_strict_mode = ENFORCING` rejects `mysqldump`'s `LOCK TABLES` fallback
outright.

> **Under strict confinement, redirecting a snap app's stdout directly to a
> file can silently produce an empty file with exit code 0.** Pipe the
> output through `cat` instead of redirecting it directly — this is the
> CI-proven pattern used in this repo's `cli_mysqldump` suite:
>
> ```
> sudo percona-xtradb-cluster.mysqldump -u root --single-transaction --set-gtid-purged=OFF --databases mydb | cat > backup.sql
> ```

## Testing

Every push and pull request runs the full spread suite against a real
snapd install inside an LXD `ubuntu-24.04` VM, on both `amd64` and
`arm64`. Suites: `aliases`, `cli_mysqladmin`, `cli_mysqlcheck`,
`cli_mysqlcli`, `cli_mysqldump`, `cli_mysqlimport`, `cli_mysqlshow`,
`cli_mysqlslap`, `cluster_bootstrap`, `daemon_mysqld`, `garbd_membership`,
`smoke`, and `storage` — 13 suites, all run on every push. `upgrade` is
marked `manual: true` (installs from the `8.4/edge` Store channel first,
which is not guaranteed to be published — see `RELEASE_ENABLED` above) and
is excluded from the automatic run. As of the current `8.4/edge` head, all
13 non-manual suites pass in CI on both architectures; this reflects the
latest run, not a permanent guarantee.

To reproduce locally:

```
snapcraft pack
CRAFT_ARTIFACT=$(pwd)/percona-xtradb-cluster_<version>_amd64.snap spread -v
```

(`spread` from `go install github.com/canonical/spread/cmd/spread@latest`;
needs the `lxd` snap.)

## Updating to a new Percona release

`scripts/bump-version.sh` checks every exact-pinned package in
`snap/snapcraft.yaml` against the apt indexes declared under
`package-repositories`, and bumps any pin (and the top-level `version:`
field, derived from the `percona-xtradb-cluster-server` pin with its
trailing Debian revision stripped — e.g. `1:8.4.10-10-1.resolute` ->
`8.4.10-10`) that is out of date.

Each track (`8.4/edge`, `9.7/edge`) pins three packages from its own apt
source (`percona-xtradb-cluster-server`, `percona-xtradb-cluster-client`,
`percona-xtradb-cluster-garbd`, from `repo.percona.com/pxc-<NN>-lts/apt`);
`util-linux` is deliberately left unpinned. The second `package-repositories`
entry, `repo.percona.com/telemetry/apt`, exists only to satisfy
`percona-xtradb-cluster-server`'s dependency on `percona-telemetry-agent`
(pruned from the snap at prime time) and contributes no pins of its own.

### Automated

The `Update check` workflow (`.github/workflows/update-check.yaml`) runs
weekly (05:37 UTC every Monday) and, for each `*/edge` branch — `8.4/edge`
and `9.7/edge` — runs the same script and opens a pull request per branch
that has an available update. The PR:

- touches only `snap/snapcraft.yaml`, with the pin diff as the commit;
- contains the script's summary table (old/new version per package) in its
  description;
- is verified the same way any other PR is: CI (`Tests`) builds the snap for
  `amd64` and `arm64` and runs the full spread suite against it. Merging the
  PR into its track branch produces the downloadable `snap-packages`
  artifact described above.

On `9.7/edge`, CI is expected to stay red until Percona fixes the upstream
`iproute` dependency problem described under Tracks and branches above —
the workflow still runs there regardless, and is exactly what will surface
a fixed pin the moment Percona rebuilds the package.

To trigger an immediate check instead of waiting for the weekly run, start
the `Update check` workflow manually from the Actions tab (`workflow_dispatch`,
optionally scoped to one branch via the `branch` input).

If a bump PR is closed without merging, its `bump/<track>-<version>` branch
is left behind and that exact version is skipped on every future run until
the branch is deleted (or a newer version ships) — delete the branch if you
want the check retried for that version.

### Manual

```
./scripts/bump-version.sh
git diff
```

Review the diff, then commit and push as usual.

### Scope

The script only updates pins within the current track/branch it is run on
(`8.4` or `9.7`). A new Percona XtraDB Cluster major means a new
track/branch and, per the Percona publishing model, a new apt repository
path (`repo.percona.com/pxc-<NN>-lts/apt`) — that's a manual, one-time setup,
not something this script does.

## License

The snap packaging is Apache-2.0. Upstream component licenses (Percona
XtraDB Cluster server, client, garbd, qpress, and util-linux) are shipped
under `licenses/` inside the snap.
