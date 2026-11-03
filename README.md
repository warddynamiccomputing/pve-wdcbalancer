# pve-wdcbalancer (`wdcbalancer`)

**Cluster load balancing for Proxmox VE 9, modelled on vSphere DRS.**

`wdcbalancer` gives a Proxmox VE cluster the resource scheduling VMware admins
know from DRS:
- **VM scores:** every guest is scored by how much of its CPU and memory demand it actually gets.
- **Recommendations:** live migrations, each with a priority and a vSphere-style reason.
- **Rules:** VM groups, host groups, and VM/Host and VM-VM rules.
- **Controls:** a migration threshold, automation levels and per-VM overrides.

It covers **every guest**, not only HA-managed ones. Proxmox's own CRS load
balancer only acts on HA resources.

> **Status: 0.4, release candidate for 1.0.** Everything on the roadmap is
> implemented and covered by automated tests, but it has not yet moved guests
> on a real cluster with shared storage; 1.0 follows that test. Start with the
> default manual level.

## Features

| Area | What you get |
| --- | --- |
| Scores | A **VM score** (0–100 %) per guest: the share of its CPU and memory demand it gets on its node. Demand is the usage plus PSI pressure (CPU waiting is the counterpart of vSphere's CPU ready time). Also a **cluster score**, the vSphere score buckets, and node imbalance before and after the recommendations. |
| Recommendations | Ordered moves, each with a priority 1–5, a reason ("Fix VM/Host affinity rule violation", "Balance average CPU load", "Improve VM DRS score", …) and the expected gain. **Run now** (Run DRS Now), **Apply**, **Apply all**, **Dismiss**. |
| Automation | **Manual** (recommendations; Power On asks where), **Partially automated** (recommendations; Power On places automatically), **Fully automated** (the timer also applies the recommendations within the threshold). Moves run as a task, up to `max_concurrent` per node, each guest checked again just before it moves: live migration for VMs, restart migration for containers (when allowed), HA migration for HA guests. |
| HA | Rules are mirrored into native HA rules (node and resource affinity) for HA guests, so the HA manager honours them when it starts or recovers them. HA rules made by hand are never touched. |
| Notifications | New faults and moves through Proxmox notification targets (Datacenter → Notifications). |
| Maintenance mode | **Enter maintenance mode** per node (Datacenter or the node's own Load Balancing panel): running guests are moved off now (HA guests through HA node maintenance), optionally the stopped ones too, and what can't move is listed. Nothing is placed on the node until it leaves maintenance mode. |
| Initial placement | **Power On (balanced)**: stopped guests are started on the best node (expected demand, rules, memory), moved there offline first. With manual automation you see the ranking and pick. |
| Migration threshold | Five levels, from 1 (mandatory moves only) to 5 (aggressive). A recommendation is shown when its priority is within the threshold, as in vSphere. |
| Constraints | A guest is only recommended where it can actually run. It is never moved if it is on local storage, has passthrough devices, a local ISO or a lock, or would need a missing bridge or storage. It is never moved between different CPUs with `cpu: host`, never into a node without the memory for it (with headroom), and never against a strict HA rule. |
| Groups and rules | VM groups and host groups. Rules: **keep VMs together**, **separate VMs**, and **VMs to hosts** with *must run on*, *should run on*, *must not run on* and *should not run on*. Conflicting rules can't be saved enabled. Rule violations are fixed first (priority 1), and balancing never breaks a rule. |
| Overrides | Per-VM automation level: *disabled* keeps a guest where it is; *fully automated* moves it automatically even in a manual cluster. |
| Placement | For any guest, every node with "allowed / why not" and the VM score it would get there. |
| Faults and history | Violations that can't be fixed, and a conflict with Proxmox CRS auto-rebalancing. A history of passes and dismissals. |
| Interfaces | GUI (**Datacenter → Load Balancing**), the `wdcbalancer` CLI, and a REST API under `/nodes/{node}/wdcbalancer`. |

## Documentation

- [Runbook](docs/wdcbalancer-Runbook.md) ([PDF](docs/wdcbalancer-Runbook.pdf)): install, every procedure, settings, troubleshooting, monitoring, CLI/API reference
- [How It Works](docs/wdcbalancer-How-It-Works.md) ([PDF](docs/wdcbalancer-How-It-Works.pdf)): the DRS mapping, architecture, data model, the pass step by step, scores and costs, locking, applying, HA mirroring, tests
- [1.0 test plan](docs/wdcbalancer-Test-Plan.md): the checks on a cluster with shared storage before 1.0

## Requirements

- Proxmox VE 9.0 or later (it uses the PVE 9 RRD format with pressure stall data).
- For moves to be possible: guests on shared storage (Ceph, NFS, iSCSI or FC LVM, …).
  Guests on local disks are scored, but are reported as "can't be moved".

## Install

On every node of the cluster, from the signed apt repository (setup in the
[Runbook](docs/wdcbalancer-Runbook.md#installation-upgrade-uninstall)):

```bash
apt install pve-wdcbalancer
```

or from a release `.deb`: `apt install ./pve-wdcbalancer_0.4.0_all.deb`.

The package:
- adds its API and GUI to `pve-manager` (one marked line each, re-applied after
  `pve-manager` updates; check with `/usr/share/pve-wdcbalancer/wdcbalancer-integrate status`);
- enables `wdcbalancer.timer`. One node at a time (the lease holder) runs a
  pass every 5 minutes.

Reload the GUI (Ctrl+F5) and open **Datacenter → Load Balancing**.

If Proxmox CRS automatic rebalancing is on (`crs: ha-auto-rebalance=1` in
`datacenter.cfg`), the balancer reports a fault and makes no moves, because two
balancers would compete. `ha=static` or `ha=dynamic` for HA recovery placement is fine.

## Use

```bash
wdcbalancer status                 # cluster score, node load, last pass
wdcbalancer run                    # Run DRS now
wdcbalancer recommendations
wdcbalancer explain 101            # where could guest 101 run, and why not elsewhere
wdcbalancer guests                 # VM scores, demand, movable or why not
wdcbalancer settings set --threshold 4
wdcbalancer group add web vm 101,102,103
wdcbalancer group add rack-a host node1,node2
wdcbalancer rule add web-apart separate --vms 101,102
wdcbalancer rule add web-on-a vm-host --vm-group web --host-group rack-a --mode should
wdcbalancer override set 104 disabled
wdcbalancer apply                  # apply all recommendations (a task)
wdcbalancer apply --ids 101:node1:node3
wdcbalancer settings set --automation full
wdcbalancer maintenance enter node2 --move-stopped 1
wdcbalancer maintenance exit node2
wdcbalancer placement 201,202      # where would they start
wdcbalancer poweron 201,202        # Power On (balanced)
```

## Roadmap

1. **0.1:** scores, recommendations, rules, overrides, GUI, CLI, API.
2. **0.2:** applying recommendations (HA guests through `ha-manager`), Partially
   and Fully Automated levels, concurrency limits and cooldown, notifications,
   rules mirrored into HA rules.
3. **0.3:** maintenance mode, Power On (balanced) for initial placement,
   offline moves for stopped guests (network-aware balancing and container
   moves came earlier).
4. **0.4:** hardening (this release): safe concurrent passes and applies,
   stale-task detection, a circuit breaker for automation, holds on lost
   quorum, node changes and missing data, live checks before each move,
   damping against load noise and back-and-forth moves, a config schema
   version.
5. **1.0:** after a full test on a cluster with shared storage ([test plan](docs/wdcbalancer-Test-Plan.md)).

Storage DRS (datastore clusters) is part of
[pve-fcsan](https://github.com/warddynamiccomputing/pve-fcsan).

## Development

```bash
make test     # unit tests; PVE modules are stubbed when not installed
make lint     # shellcheck, perlcritic, actions pinned
make deb
```

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).

## License

AGPL-3.0-or-later.
