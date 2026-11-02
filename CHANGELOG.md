# Changelog

The Debian changelog (`debian/changelog`) is the authoritative history; this is
the readable summary.

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
