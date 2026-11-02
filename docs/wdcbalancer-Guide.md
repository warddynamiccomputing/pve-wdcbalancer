# pve-wdcbalancer guide

Version 0.3.0

How the balancer works, how it maps to vSphere DRS, and how to configure it.

## vSphere DRS to pve-wdcbalancer

| vSphere DRS | pve-wdcbalancer | Notes |
| --- | --- | --- |
| DRS cluster | the Proxmox VE cluster | one configuration per cluster, on pmxcfs (`/etc/pve/wdcbalancer/`) |
| Automation level: Manual / Partially / Fully Automated | `automation`: `manual` / `partial` / `full` | |
| Migration threshold 1–5 | `threshold` 1–5 | same meaning: a recommendation is shown when its priority ≤ threshold |
| VM DRS score, cluster DRS score | VM score, cluster score | 0–100 %, same buckets |
| Run DRS Now | **Run now**, `wdcbalancer run` | |
| DRS recommendations (apply / dismiss) | Recommendations: Apply, Apply all, Dismiss | |
| VM Overrides (DRS automation level) | Overrides: `disabled`, `manual`, … | |
| VM/Host groups | VM groups, host groups | |
| VM/Host rules: must/should (not) run on | `vm-host` rules, `mode` = `must`, `should`, `must-not`, `should-not` | |
| VM-VM affinity / anti-affinity | `together` / `separate` rules | |
| DRS faults | Faults | |
| History | History | |
| EVC | CPU check | guests with `cpu: host` (or `max`) only move between identical CPUs |
| vMotion | live migration | containers: restart migration; HA guests: HA migration |
| DRS rules honoured by vSphere HA | rules mirrored into native HA rules | for HA guests |
| Maintenance mode (Enter / Exit) | Maintenance mode (Enter / Exit) | Datacenter or node panel, CLI |
| Initial placement at power-on | Power On (balanced) | Proxmox's own Start button isn't changed |
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

## Applying recommendations

**Apply** (selected recommendations), **Apply all**, `wdcbalancer apply
[--ids ...]` or `POST apply` start a task (`wdcbapply`, in the task list):

- Moves run in the order of the pass, up to `max_concurrent` at a time per
  node (the source and the target both count), one move per guest at a time.
- Just before a move starts, the guest is checked again. It must still be on
  its source node and unlocked, and the target must be online. If not, the
  move is skipped and the reason logged.
- **VMs** are live-migrated. **Containers** are migrated in restart mode,
  so they restart on the new node. **HA guests** are moved with
  `ha-manager crm-command migrate`, so HA doesn't move them back.
- A move is done when the guest's config is on the target node. A failed
  migration task is reported with its error. The task fails if any move
  failed.
- Moved guests start their cooldown, and every move is in the history with
  its result and duration.

Only one apply task runs at a time. Applying needs `Sys.Modify` on `/` and
`VM.Migrate` on every guest that is moved. Nothing is moved while Proxmox CRS
auto-rebalancing is on.

## Automation

| Level | What happens |
| --- | --- |
| `manual` | Recommendations only; **Power On (balanced)** shows the ranking of nodes and you pick. |
| `partial` | Recommendations only for balancing; **Power On (balanced)** places guests automatically. |
| `full` | After each pass, the timer applies the recommendations within the threshold in an apply task. |

Per-VM overrides take precedence:
- `disabled`: never moved.
- `manual` or `partial`: recommended, never moved automatically.
- `full`: moved automatically even when the cluster is `manual`.

With full automation, containers are moved only when `containers` is
`restart`. Otherwise they stay as recommendations, because moving them
restarts them.

## Maintenance mode

**Enter maintenance mode** (Datacenter → Load Balancing → Maintenance, the
node's own **Load Balancing** panel, or `wdcbalancer maintenance enter
<node> [--move-stopped 1]`) starts a task (`wdcbmaint`):

1. The node is marked in the configuration. From now on no pass places
   anything there, and every pass recommends moving its running guests
   (priority 1, at every threshold).
2. If the node has HA guests, the HA manager's own node maintenance is turned
   on, so HA moves them and doesn't bring them back.
3. The other running guests are moved now, whatever the automation level:
   entering maintenance mode is an explicit request, as in vSphere. Moves are
   chosen like any other (rules, memory, scores) and repeated for up to five
   rounds while guests are still moving.
4. With **move stopped guests**, the powered-off guests are moved too
   (offline; on shared storage only their config moves).
5. Guests that can't be moved (local disks, passthrough, a rule that leaves
   them nowhere) are listed. The task then fails, but the node stays in
   maintenance mode, so you can move or shut down those guests yourself.

**Exit maintenance mode** removes the mark (and HA node maintenance, if it
turned it on). Later passes balance onto the node again.

## Initial placement (Power On (balanced))

**Power On (balanced)** (Guests tab, `wdcbalancer poweron <vmids>`) starts
stopped guests on the best node:

- A stopped guest has no usage yet, so its expected demand is a quarter of
  its configured cores and all of its configured memory.
- Guests started together are placed one after the other, each counting for
  the next, so they spread out.
- Placement honours the same constraints and rules as balancing: shared
  storage (a guest on local storage starts where its disk is), memory with
  headroom, CPU type, nodes in maintenance, *must* rules, *separate* from
  running members, *together* with running partners. It prefers nodes that
  meet *should* rules.
- A guest on another node is moved there offline first, then started. HA
  guests are started through HA (`ha-manager set ... --state started`), and
  the HA manager's CRS places them.

With **manual** automation, Power On for one guest shows the ranking of nodes
(VM score there, or why not) and you pick. With **partial** and **full** it
places at once. `wdcbalancer placement <vmids>` shows the placement without
starting anything.

Proxmox's own **Start** button is not changed: it starts a guest where it is.

## HA rules

For guests under HA, every enabled rule is also written as a native HA rule,
so the HA manager honours it when it starts, recovers or fences guests:

| Rule | HA rule |
| --- | --- |
| VMs to hosts, must / should | node-affinity, positive, strict / not strict |
| VMs to hosts, must not / should not | node-affinity, negative, strict / not strict |
| Keep together / separate | resource-affinity, positive / negative (with at least two HA guests) |

Mirrored rules are named `wdcb-<rule>` and carry the comment `managed by
pve-wdcbalancer`. Only those are changed or deleted. A hand-made HA rule with
the same name is left alone, and a fault reports the clash. The rules are
synced after every rule or group change and on every pass. `wdcbalancer
ha-sync` syncs them at once.

## Notifications

With `notify` on (the default), these go through the Proxmox VE notification
system (**Datacenter → Notifications**; metadata `type=wdcbalancer`):
- new faults, once per fault;
- automatic moves (info, or warning if one failed);
- failed moves applied by hand.

The templates are `/usr/share/pve-manager/templates/default/wdcbalancer-alert-*.txt.hbs`.

## Settings

| Setting | Default | |
| --- | --- | --- |
| `automation` | `manual` | `partial` and `full` come with automatic moves |
| `threshold` | 3 | 1–5 |
| `interval` | 300 | seconds between passes; also the averaging window |
| `memory_metric` | `active` | or `consumed` |
| `containers` | `manual` | `restart`: automation may move containers (with a restart) |
| `max_moves` | 8 | balancing moves per pass |
| `max_concurrent` | 2 | concurrent migrations per node (source and target count) |
| `cooldown` | 1800 | seconds |
| `headroom` | 10 | % of node memory kept free |
| `migration_speed` | 1000 | MB/s, for the cost of a move |
| `network_aware` | 0 | |
| `notify` | 1 | notifications for new faults and moves |
| `net_capacity` | 1250 | MB/s per node |
| `net_threshold` | 80 | % |

## Proxmox CRS

Proxmox VE 9.2's Cluster Resource Scheduler can rebalance HA guests itself
(`crs: ha-auto-rebalance=1`). With both on, two balancers would compete, so
while it is on, pve-wdcbalancer reports a fault and won't move anything. HA placement modes (`ha=basic|static|dynamic`) for starting and
recovering HA guests are fine to keep.

## API

Everything is under `/nodes/{node}/wdcbalancer`. Any node answers, because
the configuration and the last pass are cluster-wide.

| Path | Methods | |
| --- | --- | --- |
| `status` | GET | scores, node load, last pass |
| `recommendations` | GET | |
| `apply` | POST `ids` (optional) | apply recommendations in a task; also needs `VM.Migrate` on each guest |
| `ha-sync` | POST | mirror the rules into HA rules now |
| `maintenance` | GET | maintenance state of every node |
| `maintenance/{host}/enter` | POST `move-stopped` | enter maintenance mode (a task); needs `VM.Migrate` on `/vms` too |
| `maintenance/{host}/exit` | POST | |
| `placement` | GET `vmids` | where stopped guests would start |
| `poweron` | POST `vmids`, `target` | Power On (balanced) (a task); needs `VM.PowerMgmt` and `VM.Migrate` on each guest |
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
