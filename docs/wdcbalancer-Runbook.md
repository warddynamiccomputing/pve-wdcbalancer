# pve-wdcbalancer Runbook

Version 0.4.0

## Purpose and scope

`wdcbalancer` (Debian package `pve-wdcbalancer`) gives a Proxmox VE 9 cluster the resource scheduling vSphere DRS gives a vSphere cluster:
- it scores every running guest by how much of its CPU and memory demand it gets;
- it recommends live migrations that improve those scores or fix rule violations, and applies them when you ask or automatically;
- it adds VM/Host rules, maintenance mode and balanced power-on.

You can use it from the web GUI (**Datacenter → Load Balancing**, and per node under **Node → Load Balancing**), from the `wdcbalancer` CLI on any node, or through the REST API under `/nodes/{node}/wdcbalancer`.

It covers **every guest**: VMs and containers, with or without HA. Proxmox VE's own Cluster Resource Scheduler (CRS) only places and rebalances HA resources.

| vSphere DRS action | wdcbalancer GUI | wdcbalancer CLI |
| --- | --- | --- |
| Cluster DRS score, VM DRS scores | Summary; Guests tab | `wdcbalancer status`, `wdcbalancer guests` |
| Run DRS Now | Recommendations → **Run now** | `wdcbalancer run` |
| View, apply, dismiss recommendations | Recommendations → **Apply**, **Apply all**, **Dismiss** | `wdcbalancer recommendations`, `apply [--ids]`, `dismiss <id>` |
| Automation level, migration threshold | Configuration → Edit | `wdcbalancer settings set --automation ... --threshold ...` |
| VM Overrides | VM Overrides tab; Guests → **Set override** | `wdcbalancer override set <vmid> <level>` |
| VM/Host Groups | VM/Host Groups tab | `wdcbalancer group add/set/remove` |
| VM/Host Rules, VM-VM affinity and anti-affinity | VM/Host Rules tab | `wdcbalancer rule add/set/remove` |
| Faults | Faults tab, Summary banners | `wdcbalancer faults` |
| History | History tab | `wdcbalancer history` |
| Enter / Exit Maintenance Mode | Maintenance tab; node → Load Balancing | `wdcbalancer maintenance enter/exit <node>` |
| Power on with initial placement | Guests → **Power On (balanced)** | `wdcbalancer poweron <vmids>` |
| "Why can't this VM go there?" | Guests or Recommendations → **Placement** | `wdcbalancer explain <vmid>` |

Not in scope: DPM (powering hosts off), resource pools, reservations, limits and shares. Storage DRS is a separate feature of pve-fcsan (datastore clusters).

> **Status: 0.4, release candidate for 1.0.** Everything here is implemented and covered by automated tests, and the read-only parts (scores, recommendations, rules, explain) run on a lab cluster. Live moves have not yet been run on a cluster with shared storage; 1.0 follows that test ([test plan](wdcbalancer-Test-Plan.md)). Start at the default **manual** level and apply recommendations by hand until you trust them.

## Prerequisites

**Software**

- Proxmox VE 9.0 or later on every node. The balancer reads the PVE 9 RRD format, which includes pressure stall information (PSI).
- The same pve-wdcbalancer version on every node. The configuration is cluster-wide.

**For moves to be possible**

- **Shared storage** for the guests that should move: Ceph RBD, NFS, iSCSI or FC LVM (for example pve-fcsan datastores), or anything else Proxmox marks `shared`. Guests with a disk on local storage are scored but reported as "can't be moved".
- **The same bridges** (or SDN vnets) on every node a guest may move to.
- **A migration network** (`migration:` in `datacenter.cfg`) fast enough for your memory sizes. Set `migration_speed` to what it really delivers (P5).
- **Identical CPUs** for guests with `cpu: host` or `cpu: max`, or a CPU model that every node supports (`x86-64-v2-AES`, `x86-64-v3`, …). The counterpart of EVC is choosing such a model.
- **Proxmox CRS auto-rebalancing off** (`crs: ha-auto-rebalance=0`, the default). With both on, two balancers would compete, so wdcbalancer refuses to move anything (P16). The CRS placement modes `ha=basic|static|dynamic` are fine.

**Permissions**

| Action | Required privilege |
| --- | --- |
| View status, recommendations, guests, faults, history, settings, groups, rules, overrides, placement | `Sys.Audit` on `/` |
| Run now, dismiss, resume, change settings, groups, rules, overrides, exit maintenance mode, HA rule sync | `Sys.Modify` on `/` |
| Apply recommendations | `Sys.Modify` on `/` and `VM.Migrate` on every guest that is moved |
| Enter maintenance mode | `Sys.Modify` on `/` and `VM.Migrate` on `/vms` |
| Power On (balanced) | `VM.PowerMgmt` and `VM.Migrate` on every guest |

The **Load Balancing** menu entries are only shown to users with `Sys.Audit` on `/`.

## Installation, upgrade, uninstall

Install the same package on every node.

**From the apt repository (recommended).** On each node, as root:

```bash
curl -fsSL https://warddynamiccomputing.github.io/pve-wdcbalancer/pve-wdcbalancer.gpg -o /usr/share/keyrings/pve-wdcbalancer.gpg
cat > /etc/apt/sources.list.d/pve-wdcbalancer.sources <<'EOF'
Types: deb
URIs: https://warddynamiccomputing.github.io/pve-wdcbalancer
Suites: stable
Components: main
Signed-By: /usr/share/keyrings/pve-wdcbalancer.gpg
EOF
apt update
apt install pve-wdcbalancer
```

After that, `apt upgrade` installs new versions with your Proxmox VE updates. The repository is signed with the key `FBCA 7A62 0928 1FAA 796F  AFD0 ACCA EEE8 1834 4A99`, the same key as the pve-fcsan repository; check it with `gpg --show-keys /usr/share/keyrings/pve-wdcbalancer.gpg`.

**Or get the package yourself.** Download the `.deb` from the project's GitHub releases. Each release also carries a `SHA256SUMS` file and a signed build-provenance attestation:

```bash
sha256sum -c SHA256SUMS --ignore-missing
gh attestation verify pve-wdcbalancer_0.4.0_all.deb --repo warddynamiccomputing/pve-wdcbalancer
apt install ./pve-wdcbalancer_0.4.0_all.deb
```

To build it on a Debian 13 machine or a Proxmox node instead:

```bash
apt install build-essential debhelper git
git clone https://github.com/warddynamiccomputing/pve-wdcbalancer.git
cd pve-wdcbalancer
make test
make deb
```

**Check each node** after installing:

```bash
/usr/share/pve-wdcbalancer/wdcbalancer-integrate status
systemctl status wdcbalancer.timer
wdcbalancer status
```

`wdcbalancer-integrate status` must report both `Nodes.pm` and `index.html.tpl` as integrated. Reload the browser with Ctrl+F5, then open **Datacenter → Load Balancing**. The first pass runs within a few minutes; until then `wdcbalancer status` says "no pass yet".

**What the package changes**

| Change | Where | Undone by |
| --- | --- | --- |
| One marked line registering the API | `/usr/share/perl5/PVE/API2/Nodes.pm` | `apt remove` |
| One marked `<script>` line loading the GUI | `/usr/share/pve-manager/index.html.tpl` | `apt remove` |
| dpkg trigger: re-applies both lines when pve-manager replaces those files | `debian/triggers` | `apt remove` |
| `wdcbalancer.timer` and `wdcbalancer.service`, enabled | `/lib/systemd/system` | `apt remove` |
| Notification templates | `/usr/share/pve-manager/templates/default/wdcbalancer-alert-*.txt.hbs` | `apt remove` |
| Cluster-wide configuration and state | `/etc/pve/wdcbalancer/` | kept; delete by hand (below) |

The API line loads the balancer inside an `eval`. If the module ever fails to load, only `/nodes/{node}/wdcbalancer` is missing and a warning goes to the pveproxy and pvedaemon journal; the rest of the Proxmox API keeps working. The integration script compile-checks the patched `Nodes.pm` and rolls it back if it doesn't compile.

pve-fcsan and pve-wdcbalancer can be installed together: each has its own marked line, and wdcbalancer's goes after pve-fcsan's so neither moves the other.

**Upgrade**, one node at a time:

```bash
apt update && apt install pve-wdcbalancer
/usr/share/pve-wdcbalancer/wdcbalancer-integrate status
```

You can leave automation on during a rolling upgrade. `config.json` carries a schema version: a newer release upgrades an older config when it reads it. If a release ever raises the schema, nodes still on the old version refuse the new config ("written by a newer pve-wdcbalancer"), stop running passes and leave the lease to the upgraded nodes. Finish the rollout to clear that fault. To be extra careful, set automation to `manual` first and back afterwards.

**Uninstall**, on every node:

```bash
apt remove pve-wdcbalancer
```

This removes the API and GUI lines and the timer. The configuration stays in `/etc/pve/wdcbalancer/`, because other nodes may still use it. After removing the package from the last node:
- exit maintenance mode for any node first, or turn HA node maintenance off yourself (`ha-manager crm-command node-maintenance disable <node>`);
- delete the mirrored HA rules: every rule named `wdcb-…` with the comment `managed by pve-wdcbalancer` (`ha-manager rules list`);
- then remove the directory: `rm -r /etc/pve/wdcbalancer`.

## How a pass works, in one page

`wdcbalancer.timer` runs every minute on every node. One node, the **lease holder**, does the work: it runs a **pass** every `interval` (5 minutes by default). Another node takes over the lease when the holder hasn't renewed it for 3 minutes.

A pass:
1. averages the last `interval` of 1-minute usage data for every node and running guest (CPU, memory, network, CPU and memory pressure);
2. scores every guest where it is: the share of its demand its node can serve (100 % = no contention);
3. recommends, in this order:
   1. **mandatory moves** (priority 1): evacuating nodes in maintenance mode, fixing *must* rules, *separate* rules and *keep together* rules;
   2. **soft rule fixes** (priority 2): *should* rules;
   3. **balancing**: one move at a time, the one that raises the scores and evens out the load most after the cost of the migration;
4. with `full` automation, starts an apply task for the recommendations within the threshold.

Each recommendation has a priority from 1 (mandatory) to 5 (small gain). The **migration threshold** (1–5) is the lowest priority that is shown and applied: threshold 1 shows only mandatory moves, threshold 5 everything. The details, from the demand model to the damping, are in [How It Works](wdcbalancer-How-It-Works.md).

## Procedures

### P1. First start: manual and read-only

After installing on every node:

1. Open **Datacenter → Load Balancing → Summary**, or run `wdcbalancer status`. Check:
   - the leader and the time of the last pass;
   - every node with its CPU and memory utilization;
   - `automation: manual, threshold 3`.
2. Open **Guests** (`wdcbalancer guests`). For each guest:
   - **score**: its VM score now; **expected**: after the recommendations;
   - **movable**: if it can't be moved at all, the reason. Typical reasons are local storage, passthrough, a lock, a template, or an override `disabled`.
3. Fix what keeps guests you want balanced from moving (move their disks to shared storage, change `cpu: host` to a common model), or set an override `disabled` for guests that must stay where they are (P7).
4. Open **Faults** (`wdcbalancer faults`). A new cluster has none. See [Faults](#faults) for each type.

Nothing moves at the manual level unless you click **Apply**.

### P2. Read the Summary

```text
# wdcbalancer status
last pass: Mon Nov  2 10:15:01 2026 on pve1 (timer, 4.2s); leader: pve1
automation: manual, threshold 3
cluster score: 91% (after recommendations: 97%), imbalance 0.184 -> 0.061
VM scores: 0-20%: 0  20-40%: 0  40-60%: 1  60-80%: 2  80-100%: 22
guests: 25 running, 21 movable; 3 recommendation(s), 0 fault(s)

NODE                CPU    MEM  CPU AFT  MEM AFT GUESTS STATE
pve1                92%    61%      71%      58%     11 online
pve2                38%    55%      52%      57%      8 online
pve3                41%    49%      49%      51%      6 online
```

- **Cluster score**: the average VM score. **After recommendations**: what it would be once all recommendations are applied.
- **Imbalance**: the spread of node utilization (CPU and memory, standard deviation). 0 = perfectly even.
- **VM scores** buckets: as in vSphere. Guests below 80 % are losing a noticeable share of their demand to contention.
- **CPU AFT / MEM AFT**: node utilization after the recommendations.
- Extra lines appear when something holds the balancer back: a Proxmox CRS conflict, lost quorum, a hold, the circuit breaker, or a running apply task. Each is explained in [Faults](#faults).

The GUI Summary shows the same: the scores and buckets, a table of the nodes with their utilization now and after the recommendations, and banners for the CRS conflict, the circuit breaker, lost quorum and holds.

### P3. Run now, read and check recommendations

1. **Recommendations → Run now** (`wdcbalancer run`) runs a pass at once on the node you're connected to. It takes a few seconds.
2. Read the list (`wdcbalancer recommendations`):

   | Column | Meaning |
   | --- | --- |
   | priority | 1 mandatory, 2–5 by gain |
   | vmid, name, from → to | the move |
   | reason | "Host pve2 is entering maintenance mode", "Fix VM/Host affinity rule violation", "Fix VM anti-affinity rule violation", "Fix VM affinity rule violation", "Fix soft VM/Host affinity rule violation", "Improve VM DRS score", "Balance average CPU load", "Balance average memory load", "Balance network load" |
   | gain | the expected improvement in score points after the cost of the move |
   | kind | `maintenance`, `rule` or `balance` |
   | rule | the rule a fix is for |
   | id | `vmid:from:to`, used by `apply --ids` and `dismiss` |

3. The list is in order: each recommendation assumes the earlier ones were applied. A guest appears at most once.
4. To see why a guest goes to one node and not another, select it and click **Placement**, or run `wdcbalancer explain <vmid>`:

   ```text
   NODE   CURRENT  OK  SCORE  GAIN  CPU    MEM    REASON
   pve1   1        1   72           0.921  0.612
   pve2            1   100    38.4  0.381  0.552
   pve3            0                0.410  0.490  storage 'ceph-ssd' is not available on pve3
   ```

   **score** is the VM score the guest would get there, **gain** the change in the objective before the cost of the move.

### P4. Apply or dismiss

- **Apply** the selected recommendations, or **Apply all**. On the CLI:

  ```bash
  wdcbalancer apply                                 # all of them
  wdcbalancer apply --ids 101:pve1:pve2,104:pve1:pve3
  ```

  This starts a `wdcbapply` task (in the task list; the CLI runs it in the foreground and exits non-zero if a move failed). The task log shows each move:

  ```text
  start  qemu 101: pve1 -> pve2 (Improve VM DRS score)
  OK     qemu 101: pve1 -> pve2 in 14s
  FAILED qemu 104: pve1 -> pve3 (skipped: guest is locked (backup))
  ```

  Moves run in list order, up to `max_concurrent` at a time per node (the source and the target both count). Just before each move starts it is checked again on live data; see P17 for what "skipped" means.

- **Dismiss** (`wdcbalancer dismiss <id>`) removes a recommendation. The same move isn't recommended again for an hour.

Recommendations are refreshed by every pass. If you apply an ID from an old list, the API answers "no recommendation '…' (run a pass to refresh the list)". **Apply** is refused while another apply task runs, while Proxmox CRS auto-rebalancing is on, and when the last pass found the cluster not quorate.

### P5. Tune the settings

**Configuration → Edit**, or:

```bash
wdcbalancer settings get
wdcbalancer settings set --threshold 4 --max_moves 4
wdcbalancer settings set --delete max_moves,cooldown      # back to the defaults
```

| Setting | Default | Range | What it does |
| --- | --- | --- | --- |
| `automation` | `manual` | `manual`, `partial`, `full` | See P6 |
| `threshold` | 3 | 1–5 | The lowest priority that is shown and applied |
| `interval` | 300 | 60–86400 s | Time between passes, and the averaging window (the 1-minute RRD data covers about the last hour) |
| `memory_metric` | `active` | `active`, `consumed` | `active`: memory the guest uses plus a quarter of the rest the host holds for it. `consumed`: all host memory of the guest |
| `containers` | `manual` | `manual`, `restart` | `restart` lets automation move containers (they restart) |
| `max_moves` | 8 | 1–256 | Balancing moves per pass (mandatory moves don't count) |
| `max_concurrent` | 2 | 1–16 | Concurrent migrations per node |
| `cooldown` | 1800 | 0–86400 s | A moved guest isn't moved again for balancing within this time |
| `headroom` | 10 | 0–50 % | Node memory kept free when placing guests |
| `migration_speed` | 1000 | 10–100000 MB/s | Expected live-migration speed; used for the cost of a move |
| `network_aware` | 0 | 0, 1 | Count network load (P14) |
| `net_capacity` | 1250 | MB/s per node | Network capacity of a node (1250 = 10 GbE) |
| `net_threshold` | 80 | 10–100 % | Network utilization above which a node is saturated |
| `notify` | 1 | 0, 1 | Notifications for new faults and moves (P15) |

**Choosing the threshold**

| Threshold | Shows | Use it when |
| --- | --- | --- |
| 1 | Mandatory moves only (maintenance, *must*, *separate*, *keep together*) | You want rules and maintenance mode, no balancing |
| 2 | Plus *should* rules and moves that relieve clear contention (gain ≥ 50) | Very conservative balancing |
| 3 (default) | Plus moves with gain ≥ 20 | Most clusters |
| 4 | Plus moves with gain ≥ 8; tolerates less imbalance | You want nodes evened out even when every guest is happy |
| 5 | Plus moves with gain ≥ 2 | Aggressive; on a busy cluster with noisy load it can move a guest every pass or two (never straight back) |

Each threshold also tolerates some imbalance (0.20, 0.15, 0.10, 0.07 for thresholds 2–5). Within it, balancing stops when every guest scores at least 95 %, and otherwise only makes priority 2 moves.

**Other tuning**

- Set `migration_speed` to what your migration network achieves (watch a migration's task log: "average migration speed"). A slower network makes big guests more expensive to move.
- Raise `headroom` if nodes run close to full memory, so moves never fill a target.
- Lower `interval` only for testing. Shorter windows mean noisier averages.

### P6. Turn on automation

| Level | Balancing | Power On (balanced) |
| --- | --- | --- |
| `manual` | Recommendations only | Shows the ranking of nodes; you pick |
| `partial` | Recommendations only | Places guests automatically |
| `full` | After each pass, the lease holder applies the recommendations within the threshold in a `wdcbapply` task | Places guests automatically |

A safe rollout:

1. Run at `manual` for a few days. Apply recommendations by hand and check the results (History, the guests' performance).
2. Move to `partial`: `wdcbalancer settings set --automation partial`.
3. Try full automation on a few guests first: keep the cluster at `partial` and give those guests the override `full` (P7). Only they move on their own.
4. Then the whole cluster: `wdcbalancer settings set --automation full`. Set the overrides of guests that must never move on their own to `manual` or `disabled`.
5. Make sure a notification target receives `type=wdcbalancer` (P15), so you see every automatic move and every fault.

With `full`:
- containers are moved automatically only with `containers` set to `restart`; otherwise they stay as recommendations;
- nothing moves while Proxmox CRS auto-rebalancing is on, while the circuit breaker has paused automation (P17), or while the cluster isn't quorate;
- mandatory moves (maintenance, *must* rules) are applied too, because they are within every threshold.

**Emergency stop.** `wdcbalancer settings set --automation manual` stops automatic moves from the next pass on. A running apply task finishes its current moves; to stop it at once, stop its task (task list → Stop). To stop the balancer entirely, also stop the timer on every node: `systemctl stop wdcbalancer.timer` (`start` to resume).

### P7. VM overrides

An override sets one guest's automation level, whatever the cluster's level:

| Override | Effect |
| --- | --- |
| `disabled` | Never moved, not even by maintenance mode or rule fixes (those report a fault instead) |
| `manual`, `partial` | Recommended, never moved automatically |
| `full` | Moved automatically, even when the cluster is `manual` |

```bash
wdcbalancer override set 104 disabled
wdcbalancer override list
wdcbalancer override remove 104
```

In the GUI: **VM Overrides → Add**, or **Guests → Set override**.

### P8. Groups and rules

Rules work on VM groups and host groups, or (for keep together and separate) directly on VM IDs.

```bash
# groups
wdcbalancer group add web vm 101,102,103
wdcbalancer group add rack-a host pve1,pve2
wdcbalancer group add licensed vm 301,302
wdcbalancer group set web --members 101,102,103,105
wdcbalancer group list

# keep VMs apart (anti-affinity): no two on the same node
wdcbalancer rule add web-apart separate --vms 101,102,103
# keep VMs together (affinity): all on one node
wdcbalancer rule add app-db together --vms 201,202
# VMs to hosts
wdcbalancer rule add web-on-a vm-host --vm-group web --host-group rack-a --mode should
wdcbalancer rule add lic-on-a vm-host --vm-group licensed --host-group rack-a --mode must

wdcbalancer rule list
wdcbalancer rule set web-on-a --enabled 0
wdcbalancer rule remove web-on-a
```

| Rule | Mode | Fixed at | Balancing |
| --- | --- | --- | --- |
| Separate VMs | | every threshold (priority 1); the guest with the most memory stays | never puts two on one node |
| Keep VMs together | | every threshold (priority 1); the group gathers on the node where it does best after the cost of the moves | moves them only as a group |
| VMs to hosts | `must`, `must-not` | every threshold (priority 1) | never breaks it |
| VMs to hosts | `should`, `should-not` | threshold ≥ 2 (priority 2) | never breaks it |

**Validation.** A rule is checked against the other enabled rules when it is saved. These can't be saved enabled (save them disabled, or fix the other rule first):
- a *keep together* and a *separate* rule that share two VMs, also through other *keep together* rules (if 1+2 and 2+3 are kept together, 1 and 3 can't be kept apart);
- *must* / *must-not* rules that leave a VM no node;
- *keep together* VMs whose *must* rules have no node in common;
- a *separate* rule with more VMs than the nodes they may use.

A group used by a rule can't be removed. The rules list shows each rule's state from the last pass: `ok`, `violated (fix recommended)`, `violated (no fix)` or `disabled`.

**Rules that can't be met right now** (a VM on local storage, no node with memory for the whole group) are faults, and are sent as notifications once.

**Rules and HA.** For HA guests, every enabled rule is also written as a native HA rule (P9), so the HA manager honours it when it recovers guests after a node failure.

### P9. HA guests

HA guests are balanced like other guests, but moved through the HA manager:
- a move is `ha-manager crm-command migrate vm:<id> <node>`, so HA doesn't move the guest back;
- in maintenance mode, the HA manager's own node maintenance is turned on and HA moves its guests;
- Power On (balanced) starts an HA guest with `ha-manager set vm:<id> --state started`; the HA manager's CRS picks the node.

**Rule mirroring.** For guests under HA, every enabled rule is mirrored into a native HA rule:

| wdcbalancer rule | HA rule |
| --- | --- |
| VMs to hosts, `must` / `should` | node-affinity, positive, strict 1 / 0 |
| VMs to hosts, `must-not` / `should-not` | node-affinity, negative, strict 1 / 0 |
| Keep together / separate | resource-affinity, positive / negative (only with at least two HA guests in the rule) |

Mirrored rules are named `wdcb-<rule name>` and have the comment `managed by pve-wdcbalancer`. They are synced after every rule or group change and on every pass; `wdcbalancer ha-sync` syncs them at once and prints what changed.

- Only rules with that name prefix **and** that comment are ever changed or deleted. HA rules you made yourself are never touched.
- If a hand-made HA rule already has the name `wdcb-<rule>`, it is left alone and a fault says "HA rule 'wdcb-…' exists and was not made by pve-wdcbalancer". Rename one of them.
- Don't edit mirrored rules by hand: the next sync puts them back. Change the wdcbalancer rule instead.
- Strict HA node-affinity rules you made yourself are honoured by the balancer as hard constraints.

### P10. Containers

A container can't be live-migrated: moving it stops it, moves it and starts it again (restart migration).
- Container moves are always recommended, marked as restarts. You can apply them by hand.
- Automation moves containers only with `containers` set to `restart`: `wdcbalancer settings set --containers restart`.
- Containers with raw `lxc.mount.entry` lines, or mount points on local storage, can't be moved.

### P11. Maintenance mode

**Enter maintenance mode** on a node before patching, rebooting or repairing it. GUI: **Maintenance → Enter maintenance mode**, or the node's own **Load Balancing** panel. CLI:

```bash
wdcbalancer maintenance enter pve2
wdcbalancer maintenance enter pve2 --move-stopped 1    # also move powered-off guests
wdcbalancer maintenance list
```

This starts a `wdcbmaint` task:
1. The node is marked in the cluster configuration. From now on no pass and no power-on places anything there, and every pass recommends moving its running guests (priority 1).
2. If the node has HA guests, HA node maintenance is turned on (`ha-manager crm-command node-maintenance enable pve2`), so HA moves them and doesn't bring them back.
3. The other running guests are moved at once, whatever the automation level (entering maintenance mode is an explicit request, as in vSphere). Targets are chosen like any other move: rules, memory, CPU type, scores. Up to five rounds run while guests are still moving.
4. The task waits up to an hour for HA to move its guests.
5. With **move stopped guests**, the powered-off guests are moved too, offline. On shared storage only their config moves.
6. The task ends with the list of guests that couldn't be moved and why (local disks, passthrough, an override `disabled`, a rule that leaves no node). It then **fails, but the node stays in maintenance mode**: shut down or move those guests yourself.

`wdcbalancer maintenance list` shows each node's state: `online`, `entering maintenance` (running guests remain) or `in maintenance`, with who entered it and when.

**Exit maintenance mode** (GUI button, or `wdcbalancer maintenance exit pve2`) removes the mark, and turns HA node maintenance off if entering turned it on. Later passes balance guests back onto the node; nothing is moved back right away.

A node in maintenance mode keeps it across reboots: the mark is in the cluster configuration.

### P12. Rolling cluster updates

To update and reboot every node of the cluster without downtime for guests on shared storage:

1. Check there is room: with one node empty, the others must hold all running guests with `headroom` to spare. `wdcbalancer status` shows memory utilization per node.
2. For each node in turn:
   1. `wdcbalancer maintenance enter <node>` and wait for the task to end. Deal with any guests it lists as blocked.
   2. `apt update && apt full-upgrade`, then reboot.
   3. Wait for the node to be back online in the cluster.
   4. `wdcbalancer maintenance exit <node>`.
3. For 10 minutes after a node goes down or comes back, balancing is on hold (only mandatory moves); this lets HA recovery and the load settle. Expect the cluster to rebalance gradually afterwards.

### P13. Power On (balanced) and placement

Proxmox's own **Start** button starts a guest where it is. To start stopped guests on the best node instead, use **Guests → Power On (balanced)**, or:

```bash
wdcbalancer placement 201,202,203      # where would they start (changes nothing)
wdcbalancer poweron 201,202,203        # move if needed, then start (a wdcbpoweron task)
wdcbalancer poweron 201 --target pve3  # start one guest on a node you pick
```

- A stopped guest has no usage yet, so placement assumes it will use a quarter of its configured cores and all of its configured memory.
- Guests started together are placed one after the other, each counting for the next, so they spread out.
- The constraints and rules apply: shared storage (a guest with local disks starts where its disks are), memory with headroom, CPU type, nodes in maintenance, *must* rules, *separate* from running members, *together* with running partners. Nodes that meet *should* rules are preferred.
- A guest is moved offline to its node first (on shared storage only its config moves), then started.
- HA guests are started through HA, and the HA manager places them.

With `manual` automation, Power On (balanced) for one guest opens the ranking (VM score per node, or why not) and you pick. With `partial` and `full` it places at once. `--target` is refused for a node where the guest can't run.

### P14. Network-aware balancing

With `network_aware` on, network load counts as a third resource: a node whose network is above `net_threshold` of `net_capacity` is saturated, and the guests on it score lower.

```bash
wdcbalancer settings set --network_aware 1 --net_capacity 2500 --net_threshold 80
```

Set `net_capacity` per node in MB/s: 1250 for 10 GbE, 2500 for 2×10 GbE or 25 GbE, 12500 for 100 GbE. It is one value for all nodes. Balancing moves then carry the reason "Balance network load" when the network is the busiest resource.

### P15. Notifications

With `notify` on (the default), these go through the Proxmox VE notification system (**Datacenter → Notifications**):

| Event | Severity |
| --- | --- |
| New faults (once per fault; missing data and balancing holds are not sent) | warning |
| Automatic moves | info, or warning if a move failed |
| Failed moves you applied by hand | warning |
| The circuit breaker pausing automation | error |

Each notification carries the metadata fields `type=wdcbalancer` and `hostname=<node>`. To route them, add a matcher on `type` = `wdcbalancer` and point it at a target (mail, webhook, Gotify, …). The templates are `/usr/share/pve-manager/templates/default/wdcbalancer-alert-subject.txt.hbs` and `-body.txt.hbs`.

A fault is "the same fault" from pass to pass when its type, rule and guests are the same (or, without guests, its message apart from numbers such as minutes left). It is notified again only after it went away and came back.

### P16. Proxmox CRS

Proxmox VE 9.2's CRS can rebalance HA guests itself (`crs: ha-auto-rebalance=1`). With both on, two balancers would compete, so while it is on, wdcbalancer reports the fault "Proxmox CRS automatic rebalancing (ha-auto-rebalance) is on", refuses **Apply**, and its automation does nothing.

To turn CRS auto-rebalancing off, edit **Datacenter → Options → Cluster Resource Scheduling**, or `/etc/pve/datacenter.cfg`, and keep only the placement mode, for example:

```text
crs: ha=static
```

The HA placement modes (`ha=basic|static|dynamic`, and `ha-rebalance-on-start`) only decide where HA starts and recovers guests; keep whichever you use.

### P17. Failed moves and the circuit breaker

**A skipped move.** Just before a move starts, it is checked again on live data, because the pass planned on averages that can be minutes old. A move is skipped, with the reason in the task log and the history, when:

| Message | Meaning |
| --- | --- |
| `skipped: guest is gone` | the guest was deleted |
| `skipped: guest is on <node> now, not <from>` | it was moved meanwhile |
| `skipped: <node> is not online` | the target went offline |
| `skipped: guest is locked (<lock>)` | a backup, snapshot or migration is running |
| `skipped: the cluster is not quorate` | quorum was lost |
| `skipped: <node> is in maintenance mode` | the target entered maintenance mode |
| `skipped: not enough free memory on <node> now (x GiB needed, y GiB free)` | memory on the target filled up since the pass |
| `skipped: memory of <node> not available` | the target's status couldn't be read |

The next pass plans again on fresh data. Skipped moves don't count for the circuit breaker.

**A failed move.** The migration was started but didn't finish: `migration task: <exit status>`, the last line of the migration's error, `timed out waiting for the guest to arrive` (after 4 hours), or `migration finished but the guest is on <node>`. Open the migration task on the source node for the full log.

**Circuit breaker.** When 3 moves in a row fail, or 5 within an hour, automation pauses:
- a fault and an error notification say why ("3 moves in a row failed");
- passes still recommend, and you can still apply by hand;
- the timer applies nothing.

To recover:
1. Read the failed moves: `wdcbalancer history`, and the migration tasks they name.
2. Fix the cause. Common ones: a migration network problem, a storage missing on the target, a full target, an HA resource in error state, a firewall blocking the migration ports.
3. Try one recommendation by hand (P4).
4. **Resume automation** on the Summary, or `wdcbalancer resume`. This clears the counters.

### P18. Back up and restore the configuration

The configuration is one file on pmxcfs, replicated to every node: `/etc/pve/wdcbalancer/config.json`. Back it up with the rest of `/etc/pve`, or on its own:

```bash
cp /etc/pve/wdcbalancer/config.json /root/wdcbalancer-config-$(date +%F).json
```

To restore, copy it back to `/etc/pve/wdcbalancer/config.json` on any node, then run `wdcbalancer run` and `wdcbalancer ha-sync`. The other files (`state.json`, `history.json`, `lease.json`, `nodefacts.json`) are rebuilt by the next passes; you can delete them if they are ever damaged.

## Troubleshooting and recovery

Start from the Summary banners and the Faults tab, then the task log of the last `wdcbapply` or `wdcbmaint` task, then the journal of the timer: `journalctl -u wdcbalancer.service`.

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `no pass yet` for more than 5 minutes | The timer isn't running on any node, or every node fails the pass | `systemctl status wdcbalancer.timer` on each node; `journalctl -u wdcbalancer.service -n 50`; run `wdcbalancer run` by hand to see the error |
| Last pass is old, the leader is a node that is down | Normal for up to 3 minutes; the lease is then taken over | Wait 3 minutes. If it stays, check that the timer runs on the other nodes |
| GUI entry missing after a Proxmox VE update | The integration was overwritten and the trigger failed | `/usr/share/pve-wdcbalancer/wdcbalancer-integrate apply`, then Ctrl+F5 |
| `Load Balancing` entry missing for some users | They lack `Sys.Audit` on `/` | Grant it, or use an account that has it |
| A guest is never recommended | It isn't movable: see **Guests** → reason, or `wdcbalancer explain <vmid>` | Shared storage, a common CPU model, the bridge on the other nodes, remove the lock or the override |
| `<disk> is on local storage '<id>'` | A disk, mount point or ISO on local storage | Move it to shared storage, or detach the ISO |
| `<device> is passed through` | PCI or USB passthrough, or raw `lxc.mount.entry` | Expected; such guests stay put |
| `CPU type 'host' and <node> has a different CPU` | `cpu: host` (or `max`) between nodes with different CPU models or flags | Use a CPU model every node supports |
| `bridge '<br>' does not exist on <node>` | The guest's bridge exists only on some nodes | Create the bridge on every node, or use an SDN vnet |
| `not enough memory on <node>` | The target would have less than `headroom` free | Expected; or lower `headroom` |
| No recommendations although nodes look uneven | Every guest is happy and the imbalance is within the threshold's tolerance; or the cooldown | Expected at threshold 3. Use threshold 4 to even out load anyway |
| Fault `Proxmox CRS automatic rebalancing … is on` | `ha-auto-rebalance=1` in `datacenter.cfg` | P16 |
| Fault `The cluster is not quorate` | Quorum lost | Restore quorum; recommendations come back with the next pass, after 10 minutes of settling |
| Fault `Load balancing is on hold: the online nodes changed; waiting N more minute(s)` | A node went down or came back less than 10 minutes ago | Wait; only mandatory moves are recommended meanwhile |
| Fault `Load balancing is on hold: no recent usage data for node(s) …` | `pvestatd` isn't writing RRD data for that node | `systemctl status pvestatd rrdcached` on that node |
| Fault `… running guests have no recent usage data` | More than a quarter of the running guests have no RRD samples (many just started, or RRD data lost) | Usually passes after a few minutes; else check `pvestatd` and `rrdcached` |
| Data fault `guest <id>: no usage samples yet` | The guest just started | Passes by itself; such a guest isn't balanced until it has data |
| Data fault `node <node>: CPU and network facts not available` | The node's status or network couldn't be read | Check the node is reachable through the API (`pvesh get /nodes/<node>/status`) |
| Fault `HA rule 'wdcb-…' exists and was not made by pve-wdcbalancer` | A hand-made HA rule has the mirrored name | Rename either rule |
| Fault `Automation is paused: …` | The circuit breaker | P17 |
| `another apply task is running` | An apply task is still moving guests | Wait for it, or stop it in the task list. A task whose node died or whose heartbeat stopped for 10 minutes stops counting by itself |
| `no recommendation '<id>' (run a pass to refresh the list)` | The list changed since you loaded it | Reload, or `wdcbalancer run` |
| `the configuration was written by a newer pve-wdcbalancer (schema N …)` | This node runs an older version than another node | Upgrade pve-wdcbalancer on this node |
| `unable to parse /etc/pve/wdcbalancer/config.json` | The file was edited by hand and is broken | Fix the JSON or restore it (P18) |
| `cfs-lock 'wdcbalancer' error: got lock request timeout` | pmxcfs is slow or another node held the lock for 30 s | Retry; check `pve-cluster` and corosync health |
| `cluster resources not available` | `pvesh get /cluster/resources` failed on the node running the pass | Check `pveproxy`/`pvedaemon` on that node |
| A guest moves back and forth | Shouldn't happen: moving back within 4 hours costs 25 points extra, and the cooldown blocks a second move for 30 minutes | Collect `wdcbalancer history` and the threshold; lower the threshold; report it |
| Maintenance task failed, node stays `entering maintenance` | Guests that can't be moved are left; the task log lists them | Move or shut them down yourself; the node is already excluded from placement |

**Useful commands**

```bash
wdcbalancer status
wdcbalancer faults
wdcbalancer history --limit 50
wdcbalancer status --output-format json-pretty
cat /etc/pve/wdcbalancer/config.json
cat /etc/pve/wdcbalancer/lease.json
journalctl -u wdcbalancer.service --since -1h
systemctl list-timers wdcbalancer.timer
ha-manager rules list
/usr/share/pve-wdcbalancer/wdcbalancer-integrate status
```

## Monitoring and health

### H1. Faults

Faults are recomputed by every pass (`wdcbalancer faults`, the Faults tab):

| Type | Raised when | Effect |
| --- | --- | --- |
| `crs` | Proxmox CRS auto-rebalancing is on | No moves, Apply refused |
| `quorum` | The cluster isn't quorate | No recommendations |
| `hold` | The online nodes changed in the last 10 minutes, or usage data is missing | Only mandatory moves |
| `breaker` | The circuit breaker paused automation | No automatic moves |
| `data` | A guest without usage samples, or node facts missing | That guest isn't balanced |
| `maintenance` | A guest on a node in maintenance mode can't be moved, or has no node to go to | It stays |
| `rule` | A rule violation can't be fixed (guest not movable, no node fits) | It stays violated |
| `ha-rules` | Mirroring into HA rules failed or clashed with a hand-made rule | The HA rule isn't changed |

### H2. History

`wdcbalancer history` (newest first, up to 500 events) and the History tab record:

| Event | Details |
| --- | --- |
| `pass` | node, trigger (timer, manual user, maintenance), cluster score, number of recommendations and faults |
| `move` | guest, from → to, result (`ok` / `failed`), message, duration, reason, priority, trigger (`automation` or the user) |
| `dismiss` | the dismissed move and who dismissed it |
| `ha-rules` | the HA rules created, updated or deleted, and errors |
| `maintenance` | enter or exit, the node and the user |
| `poweron` | Power On (balanced): guest, from → to, result |
| `breaker`, `resume` | the circuit breaker tripping, and who resumed automation |

The history is capped at 500 events and 512 KiB (pmxcfs files must stay small); the oldest events go first.

### H3. Tasks

| Task type | Started by |
| --- | --- |
| `wdcbapply` | Apply, Apply all, `wdcbalancer apply`, and full automation (user `root@pam`) |
| `wdcbmaint` | Enter maintenance mode |
| `wdcbpoweron` | Power On (balanced) |

The migrations themselves are ordinary `qmigrate` (VMs) and `vzmigrate` (containers) tasks on the source node. HA moves are started by the HA manager, so their migration task is its own.

### H4. The apply heartbeat

While an apply task runs, the Summary shows "applying N recommendation(s) (task on <node>)", and passes wait for it. The task writes a heartbeat every minute. It stops counting as running, and passes resume, when:
- its node is offline,
- its process is gone (on the same node),
- its heartbeat is 10 minutes old, or
- it started more than 4 hours and 10 minutes ago.

### H5. What to watch in a new cluster

- The cluster score and the bucket histogram after a day. Guests below 80 % point at contention; check their node and recommendations.
- The number of moves per day in the history. At threshold 3 a stable cluster makes few; many moves of the same guests point at load that really changes, or a threshold set too high.
- Faults of type `rule`: a rule that can't be met protects nothing.
- That passes run every `interval` (the time of the last pass in the Summary).

## CLI and API reference

### CLI

Every command maps onto an API method and runs on the local node; `--output-format json|json-pretty|yaml|text` works for the listing commands.

| Command | What it does |
| --- | --- |
| `wdcbalancer status` | Cluster score, buckets, node load now and after, holds, leader, last pass |
| `wdcbalancer run` | Run a pass now (Run DRS now) |
| `wdcbalancer recommendations` | The recommendations of the last pass |
| `wdcbalancer apply [--ids <id>,...]` | Apply all or the listed recommendations (a task); exits 1 if a move failed |
| `wdcbalancer dismiss <id>` | Dismiss a recommendation for an hour |
| `wdcbalancer resume` | Resume automation after the circuit breaker paused it |
| `wdcbalancer guests` | Every guest: node, score, expected score, demand, automation, movable or why not |
| `wdcbalancer explain <vmid>` | Every node: allowed or why not, VM score there, gain |
| `wdcbalancer faults` | Current faults |
| `wdcbalancer history [--limit n]` | Events, newest first (default 100, at most 500) |
| `wdcbalancer ha-sync` | Mirror the rules into HA rules now |
| `wdcbalancer maintenance list` | Maintenance state of every node |
| `wdcbalancer maintenance enter <node> [--move-stopped 1]` | Enter maintenance mode (a task) |
| `wdcbalancer maintenance exit <node>` | Exit maintenance mode |
| `wdcbalancer placement <vmids>` | Where stopped guests would start |
| `wdcbalancer poweron <vmids> [--target <node>]` | Power On (balanced) (a task) |
| `wdcbalancer settings get` | All settings with their values |
| `wdcbalancer settings set [--<setting> <value> ...] [--delete <settings>]` | Change settings, or reset them to the default |
| `wdcbalancer group list` | VM and host groups |
| `wdcbalancer group add <name> vm\|host <members> [--comment ...]` | Create a group |
| `wdcbalancer group set <name> [--members ...] [--comment ...]` | Change a group |
| `wdcbalancer group remove <name>` | Remove a group (refused while a rule uses it) |
| `wdcbalancer rule list` | Rules with their state |
| `wdcbalancer rule add <name> together\|separate --vms <ids>` | VM-VM rule |
| `wdcbalancer rule add <name> vm-host --vm-group <g> --host-group <g> --mode must\|should\|must-not\|should-not` | VM/Host rule |
| `wdcbalancer rule set <name> [--enabled 0\|1] [--vms ...] [--mode ...] [--comment ...]` | Change a rule |
| `wdcbalancer rule remove <name>` | Remove a rule |
| `wdcbalancer override list` | Per-VM automation overrides |
| `wdcbalancer override set <vmid> disabled\|manual\|partial\|full` | Set an override |
| `wdcbalancer override remove <vmid>` | Remove an override |
| `wdcbalancer timer-run` | What the timer runs every minute (lease, pass, HA sync, notifications, automation) |

### API

Everything is under `/api2/json/nodes/{node}/wdcbalancer`. Any node answers, because the configuration and the last pass are cluster-wide; `pvesh` works the same way (`pvesh get /nodes/pve1/wdcbalancer/status`).

| Path | Method | Parameters | Permission | Returns |
| --- | --- | --- | --- | --- |
| `status` | GET | | Sys.Audit | scores, node load, last pass, holds, breaker, running apply |
| `recommendations` | GET | | Sys.Audit | list |
| `apply` | POST | `ids` (optional) | Sys.Modify + VM.Migrate per guest | task ID (`wdcbapply`) |
| `dismiss` | POST | `id` | Sys.Modify | |
| `run` | POST | | Sys.Modify | pass summary |
| `resume` | POST | | Sys.Modify | `{ resumed }` |
| `guests` | GET | | Sys.Audit | list |
| `explain` | GET | `vmid` | Sys.Audit | one row per node |
| `faults` | GET | | Sys.Audit | list |
| `history` | GET | `limit` | Sys.Audit | list, newest first |
| `ha-sync` | POST | | Sys.Modify | `{ changes, errors }` |
| `maintenance` | GET | | Sys.Audit | one row per node |
| `maintenance/{host}/enter` | POST | `move-stopped` | Sys.Modify + VM.Migrate on /vms | task ID (`wdcbmaint`) |
| `maintenance/{host}/exit` | POST | | Sys.Modify | |
| `placement` | GET | `vmids` | Sys.Audit | placement and ranking per guest |
| `poweron` | POST | `vmids`, `target` | VM.PowerMgmt + VM.Migrate per guest | task ID (`wdcbpoweron`) |
| `settings` | GET, PUT | the settings, `delete` | Sys.Audit / Sys.Modify | |
| `groups`, `groups/{name}` | GET, POST, PUT, DELETE | `kind`, `members`, `comment` | Sys.Audit / Sys.Modify | |
| `rules`, `rules/{name}` | GET, POST, PUT, DELETE | `type`, `vms`, `vm-group`, `host-group`, `mode`, `enabled`, `comment` | Sys.Audit / Sys.Modify | |
| `overrides`, `overrides/{vmid}` | GET, PUT, DELETE | `automation` | Sys.Audit / Sys.Modify | |
| `timer-run` | POST | | Sys.Modify | used by the timer |

Permissions are on `/` unless stated otherwise.

### Files

| File | Content |
| --- | --- |
| `/etc/pve/wdcbalancer/config.json` | Settings, groups, rules, overrides, maintenance marks (schema version 1) |
| `/etc/pve/wdcbalancer/state.json` | The last pass, dismissals, last move per guest, the running apply task, the circuit breaker, the online-node set |
| `/etc/pve/wdcbalancer/history.json` | The event history |
| `/etc/pve/wdcbalancer/lease.json` | Which node runs the passes, and when it last renewed |
| `/etc/pve/wdcbalancer/nodefacts.json` | Cached CPU model, CPU flags and bridges per node (refreshed every 15 minutes) |
| `/usr/share/pve-wdcbalancer/wdcbalancer-integrate` | `apply`, `remove`, `status` of the API and GUI lines |
| `/usr/share/pve-manager/js/wdcbalancer.js` | The GUI |
| `/lib/systemd/system/wdcbalancer.{timer,service}` | The timer: every minute, from 2 minutes after boot |
