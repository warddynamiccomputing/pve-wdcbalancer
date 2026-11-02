# Changelog

The Debian changelog (`debian/changelog`) is the authoritative history; this is
the readable summary.

## 0.2.0
- Recommendations can be applied: **Apply**, **Apply all**, `wdcbalancer apply`.
  VMs are live-migrated, containers migrated with a restart, HA guests moved
  through the HA manager, in a task with up to `max_concurrent` moves per
  node. Each move is checked again just before it starts.
- Automation levels: with **Fully automated**, the timer applies the
  recommendations within the threshold after each pass. Per-VM overrides
  (disabled, manual, partial, full) and the container setting are honoured.
  Nothing is moved while Proxmox CRS auto-rebalancing is on.
- Rules are mirrored into native HA rules for HA guests (`wdcb-<rule>`), so
  the HA manager honours them too; hand-made HA rules are never touched.
- Notifications for new faults and moves; moves in the history with their
  result and duration.
- CLI: `apply`, `ha-sync`, and readable times in `history`.

## 0.1.0
- First release: load balancing that **recommends** moves; nothing is moved
  automatically yet.
- VM score per guest and a cluster score, from CPU and memory demand (usage
  plus pressure stall data), with node imbalance before and after.
- Recommendations with priority 1–5, vSphere-style reasons and expected gain,
  in the order they would be applied: maintenance and rule fixes first, then
  soft rules, then balancing within the migration threshold (1–5).
- Constraints: shared storage, passthrough, locks, bridges, storage per node,
  CPU compatibility for `cpu: host`, memory with headroom, strict HA rules.
- VM groups, host groups, keep-together and separate rules, VM/Host rules
  (must, should, must not, should not) with conflict checks; per-VM overrides.
- Placement explanation per guest; faults (including a conflict with Proxmox
  CRS auto-rebalancing) and history.
- Datacenter → Load Balancing in the GUI, the `wdcbalancer` CLI and a REST API
  under `/nodes/{node}/wdcbalancer`.
