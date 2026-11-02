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

> **Status: 0.1, recommendations only.** This release scores the cluster and
> recommends moves; it never migrates anything itself. Apply a recommendation
> by migrating the guest. Automatic moves, maintenance mode and initial
> placement follow in the next releases (see the [roadmap](#roadmap)).

## Features

| Area | What you get |
| --- | --- |
| Scores | A **VM score** (0–100 %) per guest: the share of its CPU and memory demand it gets on its node. Demand is the usage plus PSI pressure (CPU waiting is the counterpart of vSphere's CPU ready time). Also a **cluster score**, the vSphere score buckets, and node imbalance before and after the recommendations. |
| Recommendations | Ordered moves, each with a priority 1–5, a reason ("Fix VM/Host affinity rule violation", "Balance average CPU load", "Improve VM DRS score", …) and the expected gain. **Run now** (Run DRS Now), **Dismiss**. |
| Migration threshold | Five levels, from 1 (mandatory moves only) to 5 (aggressive). A recommendation is shown when its priority is within the threshold, as in vSphere. |
| Constraints | A guest is only recommended where it can actually run. It is never moved if it is on local storage, has passthrough devices, a local ISO or a lock, or would need a missing bridge or storage. It is never moved between different CPUs with `cpu: host`, never into a node without the memory for it (with headroom), and never against a strict HA rule. |
| Groups and rules | VM groups and host groups. Rules: **keep VMs together**, **separate VMs**, and **VMs to hosts** with *must run on*, *should run on*, *must not run on* and *should not run on*. Conflicting rules can't be saved enabled. Rule violations are fixed first (priority 1), and balancing never breaks a rule. |
| Overrides | Per-VM automation level. *Disabled* keeps a guest where it is. |
| Placement | For any guest, every node with "allowed / why not" and the VM score it would get there. |
| Faults and history | Violations that can't be fixed, and a conflict with Proxmox CRS auto-rebalancing. A history of passes and dismissals. |
| Interfaces | GUI (**Datacenter → Load Balancing**), the `wdcbalancer` CLI, and a REST API under `/nodes/{node}/wdcbalancer`. |

How it maps to vSphere and how the scores are computed:
[docs/wdcbalancer-Guide.md](docs/wdcbalancer-Guide.md).

## Requirements

- Proxmox VE 9.0 or later (it uses the PVE 9 RRD format with pressure stall data).
- For moves to be possible: guests on shared storage (Ceph, NFS, iSCSI or FC LVM, …).
  Guests on local disks are scored, but are reported as "can't be moved".

## Install

On every node of the cluster:

```bash
apt install ./pve-wdcbalancer_0.1.0_all.deb
```

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
```

## Roadmap

1. **0.1:** scores, recommendations, rules, overrides, GUI, CLI, API (this release).
2. **0.2:** applying recommendations (HA guests through `ha-manager`), Partially
   and Fully Automated levels, concurrency limits and cooldown, notifications,
   rules mirrored into HA rules.
3. **0.3:** maintenance mode, Power On (balanced) for initial placement,
   network-aware balancing, moving containers with a restart.
4. **1.0:** after a full test on a cluster with shared storage.

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
