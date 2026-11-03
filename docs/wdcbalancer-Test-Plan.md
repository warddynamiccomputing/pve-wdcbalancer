# pve-wdcbalancer 1.0 acceptance test

Version 0.4.0

The checks a cluster must pass before pve-wdcbalancer is called 1.0. They need
real live migrations, so they run on a lab cluster with **shared storage**
(Ceph, NFS, iSCSI or FC LVM, for example through pve-fcsan datastores).

Record for each check: date, result (pass / fail), and the task ID or
`wdcbalancer history` lines that show it.

## Setup

- At least 3 nodes, quorate, the same pve-wdcbalancer version on every node
  (`dpkg -l pve-wdcbalancer`, `wdcbalancer-integrate status`).
- A shared storage on all nodes, and a migration network
  (`datacenter.cfg: migration:`).
- **Test guests on the shared storage:**
  - 6 small Linux VMs (2 vCPU, 2–4 GiB) with a CPU load tool (`stress-ng`);
  - 1 VM with `cpu: host` (for the CPU check);
  - 2 containers;
  - 2 VMs under HA (`ha-manager add vm:<id>`).
- Proxmox CRS: `ha=static` or `dynamic`, `ha-auto-rebalance` off.
- A notification target for `type=wdcbalancer` (for example mail to yourself).
- Settings start at the defaults (`wdcbalancer settings get`); `interval` may
  be lowered to 60 s for the test.

## 1. Scores and recommendations (manual)

1. All test guests idle: `wdcbalancer status` → every VM score ≥ 80 %, no
   recommendations.
2. Start `stress-ng --cpu 0` in all 6 VMs on one node so the node's CPU demand
   goes over 100 %. After 1–2 passes, expect:
   - recommendations with reasons "Improve VM DRS score" or "Balance average
     CPU load";
   - the "after recommendations" utilization of that node ≤ 80 %.
3. Threshold 1: only mandatory moves (none). Threshold 5: more moves than at
   threshold 3.
4. **Explain**: `wdcbalancer explain <vmid>` for the `cpu: host` VM lists
   nodes with a different CPU as not allowed (if the cluster has them).
5. Dismiss one recommendation: it doesn't come back for an hour.

## 2. Applying (manual)

1. **Apply** one recommendation in the GUI. Check:
   - a `wdcbapply` task;
   - the VM live-migrates (no reboot; `uptime` inside it);
   - history: move `ok` with its duration.
2. **Apply all**: at most `max_concurrent` migrations at once per node
   (watch the task list).
3. A recommendation for a container: it restarts on the new node.
4. A recommendation for an HA VM: moved through `ha-manager crm-command
   migrate`; `ha-manager status` shows it on the new node and HA doesn't move
   it back.
5. A failing move: lock a VM (`qm set <id> --lock backup`) before applying →
   skipped, reported in the task and the history. Unlock it afterwards.
6. Applying as a user without `VM.Migrate` on a VM is refused.
7. After the moves, the next pass recommends nothing new (no ping-pong), and
   the moved guests aren't moved again within `cooldown`.

## 3. Full automation

1. `wdcbalancer settings set --automation full`, load one node again → within
   one or two passes, a `wdcbapply` task started by the timer moves guests.
   Notification received.
2. Per-VM override `disabled` on one loaded VM → it is never moved.
3. Override `full` with the cluster on `manual` → only that VM moves on its own.
4. Containers are not moved automatically until `containers` is `restart`.
5. Turn on CRS `ha-auto-rebalance` → fault "two balancers would compete", no
   automatic moves, **Apply** refused. Turn it off again.
6. Stop the leader node's timer (`systemctl stop wdcbalancer.timer`) → within
   about 3 minutes another node takes the lease and runs the passes. Start it
   again.
7. Circuit breaker: make three automatic moves fail in a row (for example,
   remove the target's migration network bridge or block the migration port
   between two nodes while automation moves to them) → fault and error
   notification "automation paused", no further automatic moves, recommendations
   still shown. **Resume automation** in the Summary → automation resumes.

## 4. Rules

1. VM group + host group, rule **must run on**:
   - VMs outside the hosts → priority 1 recommendations to move them in;
   - balancing never moves them out.
2. **should run on**: fixed at threshold ≥ 2, never broken by balancing.
3. **must not / should not run on**: the opposite.
4. **Keep together** with two VMs on different nodes → the stray one joins the
   other. Under load, the pair moves as one.
5. **Separate** with two VMs on one node → one moves. Balancing never puts
   them together.
6. Conflicting rules (keep together + separate on the same VMs) → can't be
   saved enabled.
7. **HA mirroring**: a rule with the HA VMs creates `wdcb-<rule>` in
   `ha-manager rules list`. Changing or disabling the rule updates or removes
   it. A hand-made HA rule is never touched.
8. A rule that can't be met (VM on local storage) → fault + notification.

## 5. Maintenance mode

1. **Enter maintenance mode** on a node with test VMs, containers and an HA
   VM:
   - the running VMs move off;
   - the HA VM is moved by HA (`ha-manager status`: node in maintenance);
   - the node gets nothing new.
2. With **move stopped guests**: the stopped test VMs move too (config only).
3. A VM on local storage on that node → listed as "can't be moved"; the task
   fails but the node stays in maintenance mode.
4. **Exit maintenance mode** → HA node maintenance off; later passes balance
   onto the node again.
5. Reboot the node while it is in maintenance mode, then exit → nothing breaks.

## 6. Power On (balanced)

1. Stop 3 test VMs that are on one node.
2. With **partial** automation, **Power On (balanced)** all three → they start
   spread over the nodes (`wdcbalancer placement` shows the same).
3. With **manual**, Power On one VM → the ranking window opens; pick another
   node → it moves and starts there.
4. Power On an HA VM → started through HA.
5. A VM with a *must run on* rule → starts only on those hosts.

## 7. Robustness

1. A node goes offline during a pass → the pass reports it, no moves to it;
   the next passes show the hold "the online nodes changed" and recommend
   only mandatory moves for 10 minutes.
2. A node goes offline during an apply → that move fails cleanly, the others
   finish.
3. Power off the node running an apply task (hard) → within 10 minutes the
   Summary no longer shows the task as running, and the next pass runs.
4. During a long apply, click **Run now** → the Summary still shows the apply
   task; a second **Apply** is refused while it runs.
5. Fill a target node's memory (a large VM or a memory hog) after a pass that
   recommended a move there, then apply → the move is skipped with "not
   enough free memory now".
6. Cut quorum (stop corosync on enough nodes, in a maintenance window) →
   fault "not quorate", no recommendations; recommendations come back after
   quorum (and 10 minutes of settling).
7. Upgrade `pve-manager` (or reinstall it) → `wdcbalancer-integrate status`
   still integrated (dpkg trigger), GUI and API work.
8. Install and remove the package on one node → the Proxmox API and GUI
   keep working; `/etc/pve/wdcbalancer` stays.
9. 24 hours with full automation and normal load → no guest moved back to a node it left
   within 4 hours, no unexpected faults.

## Result

1.0 is released when sections 1–7 pass.
