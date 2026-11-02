# pve-wdcbalancer guide

Version 0.1.0

How the balancer works, how it maps to vSphere DRS, and how to configure it.

## vSphere DRS to pve-wdcbalancer

| vSphere DRS | pve-wdcbalancer | Notes |
| --- | --- | --- |
| DRS cluster | the Proxmox VE cluster | one configuration per cluster, on pmxcfs (`/etc/pve/wdcbalancer/`) |
| Automation level: Manual / Partially / Fully Automated | `automation`: `manual` / `partial` / `full` | 0.1: `manual` only |
| Migration threshold 1–5 | `threshold` 1–5 | same meaning: a recommendation is shown when its priority ≤ threshold |
| VM DRS score, cluster DRS score | VM score, cluster score | 0–100 %, same buckets |
| Run DRS Now | **Run now**, `wdcbalancer run` | |
| DRS recommendations (apply / dismiss) | Recommendations (dismiss) | 0.1 recommends only |
| VM Overrides (DRS automation level) | Overrides: `disabled`, `manual`, … | |
| VM/Host groups | VM groups, host groups | |
| VM/Host rules: must/should (not) run on | `vm-host` rules, `mode` = `must`, `should`, `must-not`, `should-not` | |
| VM-VM affinity / anti-affinity | `together` / `separate` rules | |
| DRS faults | Faults | |
| History | History | |
| EVC | CPU check | guests with `cpu: host` (or `max`) only move between identical CPUs |
| vMotion | live migration | |
| Maintenance mode | 0.3 | nodes in HA maintenance are already avoided |
| Initial placement | 0.3 (Power On (balanced)) | placement explanation already available |
| DPM, resource pools | not planned | |
| Storage DRS | pve-fcsan (datastore clusters) | |

## Passes

`wdcbalancer.timer` runs every minute on every node. The node that holds the
lease runs a **pass** when the interval is up, every 5 minutes by default. The
lease is in `/etc/pve/wdcbalancer/lease.json` and is taken over after 3 minutes
without renewal, for example when its node is down. **Run now** runs a pass at once
on the node serving the request.

A pass:

1. **Collects**:
   - the cluster resources;
   - the 1-minute RRD averages over the interval for every running guest and node
     (CPU, memory, host memory of the guest, network and PSI pressure);
   - the guest configs (disks, devices, bridges, CPU type, lock);
   - the storages available on each node;
   - each node's CPU model and flags and its bridges (cached for 15 minutes);
   - SDN vnets, native HA rules and the CRS settings.
2. **Scores** every running guest where it is.
3. **Recommends**, in this order:
   1. **Mandatory moves** (priority 1, at every threshold):
      - guests on a node in maintenance;
      - violations of *must* VM/Host rules;
      - violations of *separate* rules (the guest with the most memory stays);
      - violations of *together* rules (the guests join the node that already
        has most of them).
   2. **Soft rule fixes** (priority 2, threshold ≥ 2): violations of *should*
      VM/Host rules.
   3. **Balancing** (threshold ≥ 2): repeatedly the single move with the best
      net gain, until no move reaches a priority within the threshold, or until
      `max_moves`.
4. **Stores** the result in `/etc/pve/wdcbalancer/state.json`, and the pass in
   the history.

Each recommendation assumes the earlier ones were applied. "After
recommendations" in the GUI shows the cluster as it would be after all of them.

## Demand and scores

**CPU demand** of a guest is its CPU usage in cores, raised by its CPU pressure
(PSI "some"). Time a guest spends waiting for a CPU is demand it didn't get.
This is the counterpart of vSphere's CPU ready time.

**Memory demand** depends on `memory_metric`:
- `active` (the default) is the memory the guest reports as used, plus a quarter
  of the rest of what the host holds for it. This matches vSphere's default idle
  consumed-memory share.
- `consumed` is the host memory of the guest.

Either one is raised by memory pressure (PSI "full").

**Node load** is the node's own overhead (usage its guests don't explain, such as
services or Ceph; the ZFS ARC is not counted) plus the demand of its guests.
Utilization is load divided by capacity (cores, memory).

**VM score.** A guest's score is the share of its demand it would get at its
node's utilization:

| | full service up to | then | above capacity |
| --- | --- | --- | --- |
| CPU | 80 % | falls to 90 % at 100 % | 0.9 / utilization |
| memory | 90 % | falls to 70 % at 100 % | 0.7 / utilization |
| network (network-aware only) | `net_threshold` | falls to 50 % at 100 % | 0.5 / utilization |

The score is the lowest of the three, × 100. A guest that hardly uses CPU
(under 0.1 core) barely notices CPU contention.

**Cluster score** is the average VM score. **Imbalance** is the standard deviation
of node CPU and memory utilization.

## Gain, priority and threshold

The objective of a pass is the **sum of all VM scores** minus a **spread** term.
The spread is half the sum of the squared deviations of node utilization from
the cluster mean, weighted so that evening out a tenth of a node's capacity
between a busy and an idle node is worth about 10 points.

The **gain** of a move is its change in the objective, minus its cost: 2 points
per minute of migration at `migration_speed`. A move that relieves a contended
node counts for every guest on that node, so gains don't shrink as the cluster
grows.

| Gain (points) | Priority |
| --- | --- |
| mandatory | 1 |
| ≥ 50 | 2 |
| ≥ 20 | 3 |
| ≥ 8 | 4 |
| ≥ 2 | 5 |

With the default threshold 3, moves that clearly improve VM scores are
recommended. A cluster where every guest is happy is left alone even if some
nodes are busier than others; that is what threshold 4 and 5 are for.

A guest moved within `cooldown` (30 minutes) is not moved again for balancing.
A dismissed recommendation isn't made again for an hour.

## Constraints

A guest **can't be moved** at all when it:
- is a template, not running, or locked;
- has its automation override set to *disabled*;
- has a disk, mount point or CD-ROM image on storage that isn't shared, or a
  host device or path as a disk;
- has PCI or USB passthrough, or raw `lxc.mount.entry` lines.

A guest **may not run on a node** when:
- the node is offline or in maintenance (HA node maintenance counts);
- a *must* or *must-not* rule keeps it off that node;
- a strict native HA node-affinity rule keeps it off that node;
- one of its storages isn't available on the node, or one of its bridges
  doesn't exist there (SDN vnets count as present everywhere);
- its CPU type is `host` or `max` and the node's CPU model or flags differ
  (the counterpart of EVC);
- the node lacks the memory for it while keeping `headroom` free.

**Explain** (GUI: **Placement**; CLI: `wdcbalancer explain <vmid>`) shows all of
this for one guest.

## Rules

- **Keep VMs together** (`together`): the guests run on one node. Balancing
  moves them only as a group.
- **Separate VMs** (`separate`): no two of the guests on the same node.
- **VMs to hosts** (`vm-host`): a VM group and a host group with one of these modes:
  - `must` / `must-not`: hard. Never broken by balancing, and fixed at every
    threshold.
  - `should` / `should-not`: soft. Fixed from threshold 2, and never broken by
    balancing.

A rule can be disabled. When a rule is saved, it is checked against the other
enabled rules. A conflicting rule can't be saved enabled:
- *together* and *separate* sharing two VMs;
- *must* rules leaving a VM no node;
- *together* VMs whose *must* rules have no node in common;
- a *separate* rule with more VMs than the nodes they may use.

A violation that can't be fixed (for example, the guest is on local storage) is
a **fault**.

## Settings

| Setting | Default | |
| --- | --- | --- |
| `automation` | `manual` | `partial` and `full` come with automatic moves |
| `threshold` | 3 | 1–5 |
| `interval` | 300 | seconds between passes; also the averaging window |
| `memory_metric` | `active` | or `consumed` |
| `containers` | `manual` | `restart`: containers may be moved with a restart (from 0.2) |
| `max_moves` | 8 | balancing moves per pass |
| `max_concurrent` | 2 | concurrent migrations per node (from 0.2) |
| `cooldown` | 1800 | seconds |
| `headroom` | 10 | % of node memory kept free |
| `migration_speed` | 1000 | MB/s, for the cost of a move |
| `network_aware` | 0 | |
| `net_capacity` | 1250 | MB/s per node |
| `net_threshold` | 80 | % |

## Proxmox CRS

Proxmox VE 9.2's Cluster Resource Scheduler can rebalance HA guests itself
(`crs: ha-auto-rebalance=1`). With both on, two balancers would compete, so
while it is on, pve-wdcbalancer reports a fault and won't move anything (from
0.2). HA placement modes (`ha=basic|static|dynamic`) for starting and
recovering HA guests are fine to keep.

## API

Everything is under `/nodes/{node}/wdcbalancer`. Any node answers, because
the configuration and the last pass are cluster-wide.

| Path | Methods | |
| --- | --- | --- |
| `status` | GET | scores, node load, last pass |
| `recommendations` | GET | |
| `dismiss` | POST `id` | |
| `run` | POST | Run DRS now |
| `guests` | GET | VM scores and movability |
| `faults`, `history` | GET | |
| `explain` | GET `vmid` | placement per node |
| `settings` | GET, PUT | |
| `groups`, `groups/{name}` | GET, POST, PUT, DELETE | |
| `rules`, `rules/{name}` | GET, POST, PUT, DELETE | |
| `overrides`, `overrides/{vmid}` | GET, PUT, DELETE | |

Viewing needs `Sys.Audit` on `/`; changes need `Sys.Modify` on `/`.

## Uninstall

```bash
apt remove pve-wdcbalancer
```

This removes the API and GUI lines. The cluster-wide configuration stays in
`/etc/pve/wdcbalancer/`; delete that directory after removing the package from
every node.
