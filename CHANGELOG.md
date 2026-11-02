# Changelog

The Debian changelog (`debian/changelog`) is the authoritative history; this is
the readable summary.

## 0.4.0
Hardening before 1.0; no new settings.
- **Safe concurrent writers.** Passes, apply tasks and dismissals update
  `state.json` under the cluster lock without undoing each other: **Run now**
  during an apply no longer hides the running task (which let a second apply
  start), and moves or dismissals made while a pass runs are kept.
- **Stale apply tasks.** An apply task writes a heartbeat; one whose node is
  offline, whose process is gone or whose heartbeat stopped for 10 minutes
  no longer blocks passes for up to four hours.
- **Circuit breaker.** Automation pauses after 3 failed moves in a row or 5
  within an hour, with a fault and a notification. **Resume automation** in
  the Summary or `wdcbalancer resume`.
- **Holds.** Without quorum nothing is recommended. For 10 minutes after the
  online nodes change, and while usage data is missing, only mandatory moves
  are recommended; a guest without usage data is never moved for balancing.
- **Live checks before each move**: the cluster must be quorate, the target
  not in maintenance mode and with the guest's memory free now.
- **Less churn.** Every migration costs a fixed 3 points, moving a guest back
  to the node it left within 4 hours costs 25 more, and each threshold
  tolerates some imbalance (0.20 to 0.07) before evening out load noise.
  In simulations with noisy load, thresholds 2 to 4 now make at most a move
  or two in six hours of steady load (before: up to 35).
- **One recommendation per guest and pass**: a guest that a later step would
  move again gets a new target instead of a second migration. Keep-together
  rule fixes gather the guests on the best node, not the one with most of
  them, and rules that share a guest are fixed together.
- Rule validation catches keep-together rules that, through a shared guest,
  tie together guests a separate rule keeps apart.
- Fault notifications are sent once per fault even when its details change.
- The history file has a size limit; long messages are cut.
- `config.json` has a schema version; a config from a newer release is
  refused (and a node that can't read it leaves the timer lease to others).
- Tests: properties over thousands of random clusters, multi-pass
  simulations with noisy load, concurrency, breaker and holds.

## 0.3.0
- **Maintenance mode** per node: Datacenter → Load Balancing → Maintenance,
  a **Load Balancing** panel in each node's menu, and `wdcbalancer
  maintenance`. Running guests are moved off at once (HA guests through HA
  node maintenance), optionally the stopped ones too; guests that can't move
  are listed. Nothing is placed on a node in maintenance.
- **Power On (balanced)**: stopped guests start on the best node and are
  moved there offline first. With manual automation you see the ranking of
  nodes and pick. `wdcbalancer placement` and `wdcbalancer poweron`.
- Stopped guests are moved offline (on shared storage only their config moves).

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
