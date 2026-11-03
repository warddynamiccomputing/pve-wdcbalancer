package PVE::WDCBalancer::Engine;

# One balancing pass, as a pure function:
#
#   pass($snapshot, $config, now => ..., moved => { vmid => time },
#        dismissed => { rec-id => time }) -> {
#       recommendations => [ ... ], faults => [ ... ],
#       guests => { vmid => ... }, nodes => { node => ... }, cluster => { ... } }
#
# Order, like vSphere DRS:
#   1. mandatory moves, priority 1: guests on nodes in maintenance mode, then
#      violations of 'must' VM/Host rules, VM-VM anti-affinity (separate) and
#      affinity (together) rules
#   2. soft VM/Host rule ('should') violations, priority 2 (threshold >= 2)
#   3. load balancing (threshold >= 2): repeatedly the single move with the
#      best gain in the objective (cluster score minus imbalance) after its
#      cost (see move_cost; moving a guest back where it just came from costs
#      more), until no move reaches the threshold's priority or max_moves,
#      or every VM is happy and the imbalance is within the threshold's
#      tolerance.
#      Balancing never breaks a rule, 'should' rules included.
#
# Recommendations are what the moves would be in this order; each later one
# assumes the earlier ones were applied.
#
# Holds (each one a fault):
#   - no quorum: nothing is recommended
#   - the online nodes changed less than $opts{settling} seconds ago, or
#     usage data is missing (an online node, or more than $STALE_SHARE of
#     the running guests, without samples in the window): only mandatory
#     moves; a guest without samples is never moved for balancing

use strict;
use warnings;

use List::Util qw(max min sum0);

use PVE::WDCBalancer::Config;
use PVE::WDCBalancer::Constraints;
use PVE::WDCBalancer::Score;

our $DISMISS_TTL = 3600;
our $STALE_SHARE = 0.25;

# Priority of a balancing move from its net gain in VM-score points (the
# sum over all guests, so one move that relieves a contended node counts for
# every guest on it).
sub priority_for_gain {
    my ($gain) = @_;
    return 2 if $gain >= 50;
    return 3 if $gain >= 20;
    return 4 if $gain >= 8;
    return 5 if $gain >= 2;
    return undef;
}

# A migration costs $MOVE_COST points (the stun at switch-over, load on the
# migration network, the risk of a failure) plus two points per minute it
# takes. Without the fixed part, load noise alone would justify moves.
our $MOVE_COST = 3;

sub move_cost {
    my ($snap, $settings, $vmids) = @_;
    my $bytes = sum0(map { PVE::WDCBalancer::Score::guest_footprint($snap->{guests}->{$_}) } @$vmids);
    my $speed = ($settings->{migration_speed} // 1000) * 1_000_000;
    return $MOVE_COST * @$vmids + 2 * $bytes / $speed / 60;
}

# Moving a guest back to a node it left less than $BOUNCE_WINDOW seconds ago
# costs $BOUNCE_COST more points per guest: going back and forth between the
# same nodes is churn, unless the load really changed.
our $BOUNCE_WINDOW = 4 * 3600;
our $BOUNCE_COST = 25;

# Tolerated imbalance per migration threshold (vSphere: the target
# imbalance). Within it, load noise would make small moves look worthwhile:
# only priority 2 moves (clear contention) are made, and none at all while
# every VM scores at least $HAPPY.
our %TOLERANCE = (2 => 0.20, 3 => 0.15, 4 => 0.10, 5 => 0.07);
our $HAPPY = 95;

# connected keep-together groups: vmid => [ members ]
sub together_units {
    my ($cfg) = @_;
    my %parent;
    my $find;
    $find = sub { my $x = shift; $parent{$x} //= $x; return $parent{$x} eq $x ? $x : ($parent{$x} = $find->($parent{$x})); };
    for my $r (grep { $_->{type} eq 'together' } @{ PVE::WDCBalancer::Config::enabled_rules($cfg) }) {
        my @v = @{$r->{vms}};
        $find->($_) for @v;
        $parent{ $find->($_) } = $find->($v[0]) for @v[1 .. $#v];
    }
    my %sets;
    push @{$sets{ $find->($_) }}, $_ for keys %parent;
    my %unit;
    for my $set (values %sets) {
        my @s = sort { $a <=> $b } @$set;
        $unit{$_} = \@s for @s;
    }
    return \%unit;
}

sub pass {
    my ($snap, $cfg, %opts) = @_;
    my $settings = PVE::WDCBalancer::Config::settings($cfg);
    my $now = $opts{now} // time();
    my $moved = $opts{moved} // {};
    my $dismissed = $opts{dismissed} // {};
    my $left = $opts{left} // {}; # vmid => { node, time }: where it was before its last move
    my $bounce = sub {
        my ($unit, $t) = @_;
        return $BOUNCE_COST * scalar(grep { ($left->{$_}->{node} // '') eq $t && $now - ($left->{$_}->{time} // 0) < $BOUNCE_WINDOW } @$unit);
    };
    my $rules = PVE::WDCBalancer::Config::enabled_rules($cfg);
    my @all_nodes = sort keys %{$snap->{nodes}};

    my %placement;
    for my $vmid (keys %{$snap->{guests}}) {
        my $g = $snap->{guests}->{$vmid};
        next if ($g->{status} // '') ne 'running' || $g->{template};
        next if !$snap->{nodes}->{$g->{node} // ''};
        $placement{$vmid} = $g->{node};
    }
    my $current = PVE::WDCBalancer::Score::evaluate($snap, \%placement, $settings);
    my $ev = $current;

    my %movable;
    for my $vmid (keys %placement) {
        my ($ok, $why) = PVE::WDCBalancer::Constraints::movable($snap, $cfg, $vmid);
        $movable{$vmid} = $ok ? '' : $why;
    }

    my (@recs, @faults, %in_pass);
    my $units = together_units($cfg);

    my %separate_of; # vmid => [ rules ]
    for my $r (grep { $_->{type} eq 'separate' } @$rules) {
        push @{$separate_of{$_}}, $r for @{$r->{vms}};
    }
    my @soft = grep { $_->{type} eq 'vm-host' && $_->{mode} =~ /^should/ } @$rules;

    my $violates_soft = sub {
        my ($vmid, $node) = @_;
        my @hit;
        for my $r (@soft) {
            next if !grep { $_ == $vmid } @{ PVE::WDCBalancer::Config::rule_vms($cfg, $r) };
            my $in = grep { $_ eq $node } @{ PVE::WDCBalancer::Config::rule_hosts($cfg, $r) };
            push @hit, $r->{name} if ($r->{mode} eq 'should') ? !$in : $in;
        }
        return \@hit;
    };

    # may @$vmids move together to $target without breaking a hard rule?
    my $valid = sub {
        my ($vmids, $target) = @_;
        my %moving = map { $_ => 1 } @$vmids;
        my $foot = 0;
        for my $vmid (@$vmids) {
            return (0, 'already there') if $placement{$vmid} eq $target;
            my ($ok, $why) = PVE::WDCBalancer::Constraints::can_run($snap, $cfg, $vmid, $target);
            return (0, $why) if !$ok;
            for my $r (@{$separate_of{$vmid} // []}) {
                for my $other (@{$r->{vms}}) {
                    next if $other == $vmid;
                    return (0, "rule '$r->{name}' keeps it apart from $other") if $moving{$other};
                    return (0, "rule '$r->{name}' keeps it apart from $other")
                        if ($placement{$other} // '') eq $target;
                }
            }
            for my $other (@{ $units->{$vmid} // [] }) {
                next if $other == $vmid || $moving{$other} || !defined($placement{$other});
                return (0, "a keep-together rule ties it to $other") if $placement{$other} ne $target;
            }
            $foot += PVE::WDCBalancer::Score::guest_footprint($snap->{guests}->{$vmid});
        }
        my $load = $ev->{loads}->{$target};
        my $limit = ($snap->{nodes}->{$target}->{maxmem} // 0) * (1 - $settings->{headroom} / 100);
        return (0, "not enough memory on $target") if $load->{foot} + $foot > $limit;
        return (1);
    };

    my $best_target = sub {
        my ($vmids, %o) = @_;
        my ($best, $best_obj, $best_soft, $last_err);
        for my $t (@all_nodes) {
            my ($ok, $why) = $valid->($vmids, $t);
            if (!$ok) { $last_err = $why if $why ne 'already there'; next; }
            next if $o{exclude} && $o{exclude}->{$t};
            my $soft = sum0(map { scalar(@{ $violates_soft->($_, $t) }) } @$vmids);
            next if $o{no_soft} && $soft;
            my $obj = PVE::WDCBalancer::Score::objective_after($snap, $ev, \%placement, $vmids, $t, $settings);
            if (!defined($best) || $soft < $best_soft || ($soft == $best_soft && $obj > $best_obj)) {
                ($best, $best_obj, $best_soft) = ($t, $obj, $soft);
            }
        }
        return ($best, $best_obj, $last_err);
    };

    # One recommendation per guest and pass: a guest that a later fix moves
    # on (a maintenance evacuation, then its keep-together partner's rule)
    # gets its recommendation re-targeted, or dropped when it ends up where
    # it started. It goes last: it was planned on the state after the others.
    my %rec_of;
    my $record = sub {
        my ($vmids, $target, %r) = @_;
        for my $vmid (@$vmids) {
            my $from = $placement{$vmid};
            my $g = $snap->{guests}->{$vmid};
            if (my $old = delete $rec_of{$vmid}) {
                @recs = grep { $_ != $old } @recs;
                $from = $old->{from};
                if ($from eq $target) {
                    $placement{$vmid} = $target;
                    next;
                }
                $r{priority} = min($r{priority}, $old->{priority});
            }
            push @recs, $rec_of{$vmid} = {
                id => "$vmid:$from:$target",
                vmid => $vmid + 0,
                name => $g->{name} // '',
                type => $g->{type},
                from => $from,
                to => $target,
                priority => $r{priority},
                kind => $r{kind},
                reason => $r{reason},
                gain => sprintf('%.1f', $r{gain} // 0) + 0,
                mem => int(PVE::WDCBalancer::Score::guest_footprint($g)),
                ha => $g->{ha} ? 1 : 0,
                restart => $g->{type} eq 'lxc' ? 1 : 0,
                $r{rule} ? (rule => $r{rule}) : (),
            };
            $placement{$vmid} = $target;
            $in_pass{$vmid} = 1;
        }
        $ev = PVE::WDCBalancer::Score::evaluate($snap, \%placement, $settings);
    };

    my $fault = sub {
        my (%f) = @_;
        push @faults, \%f;
    };

    my $mandatory = sub {
        my ($vmids, $kind, $reason, $rule, %o) = @_;
        my @blocked = grep { $movable{$_} } @$vmids;
        if (@blocked) {
            $fault->(type => $kind, rule => $rule, vmids => [ map { $_ + 0 } @$vmids ],
                message => "$reason: $blocked[0] can't be moved ($movable{$blocked[0]})");
            return 0;
        }
        my $obj0 = $ev->{objective};
        my ($t, $obj, $err) = $best_target->($vmids, %o);
        if (!$t) {
            $fault->(type => $kind, rule => $rule, vmids => [ map { $_ + 0 } @$vmids ],
                message => "$reason: no node for " . join(', ', @$vmids) . ($err ? " (last: $err)" : ''));
            return 0;
        }
        $record->($vmids, $t, priority => 1, kind => $kind, reason => $reason, gain => $obj - $obj0, rule => $rule);
        return 1;
    };

    # a guest and its keep-together partners on the same node move as one
    my $unit_of = sub {
        my ($vmid) = @_;
        return [ grep { ($placement{$_} // '') eq $placement{$vmid} } @{ $units->{$vmid} // [ $vmid ] } ];
    };

    # ---- holds ----
    my $quorum_lost = exists($snap->{quorate}) && !$snap->{quorate};
    my $hold;
    my %no_data = map { $_ => 1 } grep { exists($snap->{guests}->{$_}->{samples}) && !$snap->{guests}->{$_}->{samples} }
        keys %placement;
    my @dark = grep { $snap->{nodes}->{$_}->{online} && exists($snap->{nodes}->{$_}->{samples}) && !$snap->{nodes}->{$_}->{samples} }
        @all_nodes;
    if ($quorum_lost) {
        $fault->(type => 'quorum', message => 'The cluster is not quorate: no moves are recommended until quorum is back');
    } elsif ($opts{settling}) {
        $hold = sprintf('the online nodes changed; waiting %d more minute(s) for HA recovery and the load to settle',
            int(($opts{settling} + 59) / 60));
    } elsif (@dark) {
        $hold = "no recent usage data for node(s) " . join(', ', @dark);
    } elsif (%placement && keys(%no_data) > $STALE_SHARE * keys(%placement)) {
        $hold = scalar(keys %no_data) . " of " . scalar(keys %placement) . " running guests have no recent usage data";
    }
    $fault->(type => 'hold', message => "Load balancing is on hold: $hold; only mandatory moves are recommended") if $hold;

    # ---- 1. mandatory ----
    for my $vmid (sort { $a <=> $b } keys %placement) {
        next if !$snap->{nodes}->{$placement{$vmid}}->{maintenance} || $in_pass{$vmid};
        my $unit = $unit_of->($vmid);
        $in_pass{$_} = 1 for @$unit; # tried once, moved or reported
        $mandatory->($unit, 'maintenance', "Host $placement{$vmid} is entering maintenance mode");
    }

    for my $vmid (sort { $a <=> $b } keys %placement) {
        my $allowed = PVE::WDCBalancer::Config::must_nodes($cfg, $vmid, \@all_nodes) // next;
        next if $allowed->{$placement{$vmid}};
        my @r = map { $_->{name} } grep {
            $_->{type} eq 'vm-host' && $_->{mode} =~ /^must/ && grep { $_ == $vmid } @{ PVE::WDCBalancer::Config::rule_vms($cfg, $_) }
        } @$rules;
        $mandatory->($unit_of->($vmid), 'rule', 'Fix VM/Host affinity rule violation', join(',', @r));
    }

    for my $r (grep { $_->{type} eq 'separate' } @$rules) {
        my %on;
        push @{$on{ $placement{$_} }}, $_ for grep { defined($placement{$_}) } @{$r->{vms}};
        for my $node (sort keys %on) {
            my @here = @{$on{$node}};
            next if @here < 2;
            # the one with the largest memory stays: it is the costliest to move
            @here = sort { PVE::WDCBalancer::Score::guest_footprint($snap->{guests}->{$b})
                <=> PVE::WDCBalancer::Score::guest_footprint($snap->{guests}->{$a}) || $a <=> $b } @here;
            for my $vmid (@here[1 .. $#here]) {
                next if $placement{$vmid} ne $node; # moved by an earlier fix
                $mandatory->([ $vmid ], 'rule', 'Fix VM anti-affinity rule violation', $r->{name});
            }
        }
    }

    # per keep-together unit (rules sharing a VM are fixed as one)
    my %unit_seen;
    for my $first (sort { $a <=> $b } keys %$units) {
        my $unit = $units->{$first};
        next if $unit_seen{ $unit->[0] }++;
        my @run = grep { defined($placement{$_}) } @$unit;
        my %on;
        $on{ $placement{$_} }++ for @run;
        next if keys(%on) < 2;
        my %in = map { $_ => 1 } @$unit;
        my $r = { name => join(',', map { $_->{name} } grep { $_->{type} eq 'together' && $in{ $_->{vms}->[0] } } @$rules) };
        # gather where it is best after the cost of the moves (soft rules
        # first, then fewer moves): gathering on the node that has most of
        # them already would just be balanced away by the next pass
        my $best;
        my $obj0 = $ev->{objective};
        for my $node (@all_nodes) {
            my @move = grep { $placement{$_} ne $node } @run;
            next if !@move || grep { $movable{$_} } @move;
            my ($ok) = $valid->(\@move, $node);
            next if !$ok;
            my $soft = sum0(map { scalar(@{ $violates_soft->($_, $node) }) } @run);
            my $net = PVE::WDCBalancer::Score::objective_after($snap, $ev, \%placement, \@move, $node, $settings)
                - $obj0 - move_cost($snap, $settings, \@move);
            my $c = { node => $node, move => \@move, soft => $soft, net => $net };
            $best = $c if !$best || $soft < $best->{soft}
                || ($soft == $best->{soft} && ($net > $best->{net} + 1e-9 || (abs($net - $best->{net}) <= 1e-9 && @move < @{$best->{move}})));
        }
        if ($best) {
            my $obj = PVE::WDCBalancer::Score::objective_after($snap, $ev, \%placement, $best->{move}, $best->{node}, $settings);
            $record->($best->{move}, $best->{node}, priority => 1, kind => 'rule', reason => 'Fix VM affinity rule violation',
                gain => $obj - $obj0, rule => $r->{name});
        } else {
            $fault->(type => 'rule', rule => $r->{name}, vmids => [ map { $_ + 0 } @run ],
                message => "Fix VM affinity rule violation: no node can take all of " . join(', ', @run));
        }
    }

    my $threshold = $settings->{threshold};

    # ---- 2. soft rules ----
    if ($threshold >= 2 && !$hold) {
        for my $vmid (sort { $a <=> $b } keys %placement) {
            my $hit = $violates_soft->($vmid, $placement{$vmid});
            next if !@$hit || $movable{$vmid} || $in_pass{$vmid};
            my @unit = @{ $units->{$vmid} // [ $vmid ] };
            @unit = grep { defined($placement{$_}) } @unit;
            # a unit member moved earlier in this pass: next pass (one move per guest)
            next if grep { $movable{$_} || $in_pass{$_} || $placement{$_} ne $placement{$vmid} } @unit;
            my $obj0 = $ev->{objective};
            my ($t, $obj) = $best_target->(\@unit, no_soft => 1);
            if (!$t) {
                $fault->(type => 'rule', rule => join(',', @$hit), vmids => [ map { $_ + 0 } @unit ],
                    message => "Soft VM/Host rule violated: no node meets the rule for " . join(', ', @unit));
                next;
            }
            $record->(\@unit, $t, priority => 2, kind => 'rule', reason => 'Fix soft VM/Host affinity rule violation',
                gain => $obj - $obj0, rule => join(',', @$hit));
        }
    }

    # ---- 3. balancing ----
    my $balancing = 0;
    if ($threshold >= 2 && !$hold) {
        my %seen_unit;
        my @candidates;
        for my $vmid (sort { $a <=> $b } keys %placement) {
            my @unit = grep { defined($placement{$_}) } @{ $units->{$vmid} // [ $vmid ] };
            next if $seen_unit{ $unit[0] }++;
            push @candidates, \@unit;
        }
        # A unit balanced earlier in this pass may be balanced again: its
        # recommendation gets the new target (still one migration, no new
        # cost), or goes away when the unit is best back where it was (its
        # cost is saved). Greedy order otherwise leaves a second migration
        # of the same guest for the next pass.
        my %bal;    # vmid => its balancing recommendation
        my %origin; # vmid => node at the start of the pass
        my $steps = 0;
        while ($balancing < $settings->{max_moves} && $steps++ < 4 * $settings->{max_moves}) {
            # within the tolerance only clear wins (priority 2) count, and none
            # when every VM is happy
            my $tolerated = $ev->{imbalance} <= ($TOLERANCE{$threshold} // 0);
            last if $tolerated && !grep { $ev->{scores}->{$_} < $HAPPY } keys %placement;
            my $limit = $tolerated ? min($threshold, 2) : $threshold;
            my ($best, $best_net, $best_t);
            for my $unit (@candidates) {
                my $again = !grep { !$bal{$_} } @$unit;
                next if grep { $movable{$_} || ($in_pass{$_} && !$again) || $no_data{$_} } @$unit;
                next if !$again && grep { $now - ($moved->{$_} // 0) < $settings->{cooldown} } @$unit;
                next if grep { $placement{$_} ne $placement{ $unit->[0] } } @$unit;
                my $cost = move_cost($snap, $settings, $unit);
                for my $t (@all_nodes) {
                    my $back = $again && $origin{ $unit->[0] } eq $t;
                    next if !$back && grep { $now - ($dismissed->{ "$_:" . ($origin{$_} // $placement{$_}) . ":$t" } // 0) < $DISMISS_TTL } @$unit;
                    my ($ok) = $valid->($unit, $t);
                    next if !$ok;
                    next if grep { @{ $violates_soft->($_, $t) } } @$unit;
                    my $net = PVE::WDCBalancer::Score::objective_after($snap, $ev, \%placement, $unit, $t, $settings)
                        - $ev->{objective} - ($back ? -$cost : $again ? 0 : $cost) - ($back ? 0 : $bounce->($unit, $t));
                    ($best, $best_net, $best_t) = ($unit, $net, $t) if !defined($best_net) || $net > $best_net;
                }
            }
            last if !$best;
            my $prio = priority_for_gain($best_net);
            last if !defined($prio) || $prio > $limit;
            my $reason = balance_reason($snap, $ev, \%placement, $best, $best_t, $settings);
            if (!$bal{ $best->[0] }) {
                $origin{$_} = $placement{$_} for @$best;
                my $first = @recs;
                $record->($best, $best_t, priority => $prio, kind => 'balance', reason => $reason, gain => $best_net);
                $bal{ $recs[$_]->{vmid} } = $recs[$_] for $first .. $#recs;
                $balancing++;
                next;
            }
            my %unit = map { $_ => 1 } @$best;
            if ($origin{ $best->[0] } eq $best_t) {
                @recs = grep { !$unit{$_->{vmid}} } @recs;
                for my $vmid (@$best) {
                    $placement{$vmid} = $best_t;
                    delete $bal{$vmid};
                    delete $rec_of{$vmid};
                    delete $in_pass{$vmid};
                    delete $origin{$vmid};
                }
                $balancing--;
            } else {
                for my $vmid (@$best) {
                    my $r = $bal{$vmid};
                    $r->{to} = $best_t;
                    $r->{id} = "$vmid:$r->{from}:$best_t";
                    $r->{gain} = sprintf('%.1f', $r->{gain} + $best_net) + 0;
                    $r->{priority} = priority_for_gain($r->{gain}) // 5;
                    $r->{reason} = $reason;
                    $placement{$vmid} = $best_t;
                }
                # it was planned on the state after all the others: it goes last
                @recs = ((grep { !$unit{$_->{vmid}} } @recs), (grep { $unit{$_->{vmid}} } @recs));
            }
            $ev = PVE::WDCBalancer::Score::evaluate($snap, \%placement, $settings);
        }
    }

    # without quorum nothing may move (pmxcfs is read-only anyway)
    if ($quorum_lost) {
        @recs = ();
        $ev = $current;
    }

    # ---- report ----
    my %guests;
    for my $vmid (sort { $a <=> $b } keys %{$snap->{guests}}) {
        my $g = $snap->{guests}->{$vmid};
        my $d = defined($placement{$vmid}) ? PVE::WDCBalancer::Score::demand($snap, $vmid, $settings) : undef;
        my ($ok, $why) = defined($movable{$vmid}) ? (!$movable{$vmid}, $movable{$vmid})
            : PVE::WDCBalancer::Constraints::movable($snap, $cfg, $vmid);
        $guests{$vmid} = {
            vmid => $vmid + 0,
            name => $g->{name} // '',
            type => $g->{type},
            node => $g->{node},
            status => $g->{status},
            ha => $g->{ha} ? 1 : 0,
            automation => PVE::WDCBalancer::Config::automation_for($cfg, $vmid),
            movable => $ok ? 1 : 0,
            $ok ? () : (reason => $why),
            defined($current->{scores}->{$vmid}) ? (score => sprintf('%.0f', $current->{scores}->{$vmid}) + 0) : (),
            defined($ev->{scores}->{$vmid}) ? (expected => sprintf('%.0f', $ev->{scores}->{$vmid}) + 0) : (),
            $d ? (cpu_demand => sprintf('%.2f', $d->{cpu}) + 0, mem_demand => int($d->{mem})) : (),
        };
    }
    my %nodes;
    for my $node (@all_nodes) {
        my $n = $snap->{nodes}->{$node};
        my $u = $current->{utils}->{$node};
        my $e = $ev->{utils}->{$node};
        $nodes{$node} = {
            node => $node,
            online => $n->{online} ? 1 : 0,
            maintenance => $n->{maintenance} ? 1 : 0,
            maxcpu => $n->{maxcpu} + 0,
            maxmem => $n->{maxmem} + 0,
            guests => scalar(@{$current->{loads}->{$node}->{guests}}),
            cpu => sprintf('%.3f', $u->{cpu}) + 0,
            mem => sprintf('%.3f', $u->{mem}) + 0,
            net => sprintf('%.3f', $u->{net}) + 0,
            expected_cpu => sprintf('%.3f', $e->{cpu}) + 0,
            expected_mem => sprintf('%.3f', $e->{mem}) + 0,
        };
    }

    return {
        recommendations => \@recs,
        faults => \@faults,
        guests => \%guests,
        nodes => \%nodes,
        cluster => {
            score => sprintf('%.0f', $current->{cluster}) + 0,
            expected => sprintf('%.0f', $ev->{cluster}) + 0,
            imbalance => sprintf('%.3f', $current->{imbalance}) + 0,
            expected_imbalance => sprintf('%.3f', $ev->{imbalance}) + 0,
            buckets => $current->{buckets},
            running => scalar(keys %placement),
            movable => scalar(grep { !$movable{$_} } keys %movable),
            threshold => $threshold + 0,
            automation => $settings->{automation},
            $hold ? (hold => $hold) : (),
            quorate => $quorum_lost ? 0 : 1,
        },
    };
}

# Where could a guest run, and why not elsewhere? One row per node, for the
# GUI's "placement" view and initial placement.
sub explain {
    my ($snap, $cfg, $vmid) = @_;
    my $settings = PVE::WDCBalancer::Config::settings($cfg);
    my $g = $snap->{guests}->{$vmid} // die "guest $vmid not found\n";
    my %placement;
    for my $id (keys %{$snap->{guests}}) {
        my $x = $snap->{guests}->{$id};
        $placement{$id} = $x->{node} if ($x->{status} // '') eq 'running' && $snap->{nodes}->{$x->{node} // ''};
    }
    # a stopped guest is evaluated as if it ran on its node
    $placement{$vmid} //= $g->{node} if $snap->{nodes}->{$g->{node} // ''};
    my $ev = PVE::WDCBalancer::Score::evaluate($snap, \%placement, $settings);
    my ($movable, $why) = PVE::WDCBalancer::Constraints::movable($snap, $cfg, $vmid);
    $movable = 1 if !$movable && $why eq 'not running';
    my @rows;
    for my $node (sort keys %{$snap->{nodes}}) {
        my %row = (node => $node);
        if ($node eq ($placement{$vmid} // '')) {
            $row{current} = 1;
            $row{ok} = 1;
            $row{score} = sprintf('%.0f', $ev->{scores}->{$vmid} // 100) + 0;
        } else {
            my ($ok, $reason) = $movable ? PVE::WDCBalancer::Constraints::can_run($snap, $cfg, $vmid, $node) : (0, $why);
            if ($ok && !PVE::WDCBalancer::Constraints::fits($snap, $settings, $ev->{loads}->{$node}, $vmid, $node)) {
                ($ok, $reason) = (0, "not enough memory on $node");
            }
            $row{ok} = $ok ? 1 : 0;
            $row{reason} = $reason if !$ok;
            if ($ok && defined($placement{$vmid})) {
                my $d = PVE::WDCBalancer::Score::demand($snap, $vmid, $settings);
                my $l = $ev->{loads}->{$node};
                my $u = PVE::WDCBalancer::Score::utilization($snap, $node,
                    { cpu => $l->{cpu} + $d->{cpu}, mem => $l->{mem} + $d->{mem}, net => $l->{net} + $d->{net} }, $settings);
                $row{score} = sprintf('%.0f', PVE::WDCBalancer::Score::vm_score($snap, $vmid, $u, $settings)) + 0;
                $row{gain} = sprintf('%.1f', PVE::WDCBalancer::Score::objective_after($snap, $ev, \%placement,
                    [ $vmid ], $node, $settings) - $ev->{objective}) + 0;
            }
        }
        my $u = $ev->{utils}->{$node};
        $row{cpu} = sprintf('%.3f', $u->{cpu}) + 0;
        $row{mem} = sprintf('%.3f', $u->{mem}) + 0;
        push @rows, \%row;
    }
    return \@rows;
}

# Initial placement of stopped guests (Power On (balanced)), like DRS at
# power-on. A stopped guest has no usage yet, so its expected demand is a
# share of its configured cores ($INITIAL_CPU) and all of its memory.
# Guests are placed one after the other, each counting for the next.
# Returns [ { vmid, from, to, score, reason?, ranking => [ { node, ok, score, reason } ] } ].
our $INITIAL_CPU = 0.25;

sub place {
    my ($snap, $cfg, $vmids) = @_;
    my $settings = PVE::WDCBalancer::Config::settings($cfg);
    my @all_nodes = sort keys %{$snap->{nodes}};
    my $rules = PVE::WDCBalancer::Config::enabled_rules($cfg);
    my $units = together_units($cfg);

    my %placement;
    for my $id (keys %{$snap->{guests}}) {
        my $x = $snap->{guests}->{$id};
        $placement{$id} = $x->{node} if ($x->{status} // '') eq 'running' && $snap->{nodes}->{$x->{node} // ''};
    }

    my @res;
    for my $vmid (@$vmids) {
        my $g = $snap->{guests}->{$vmid};
        if (!$g) {
            push @res, { vmid => $vmid + 0, reason => 'unknown guest' };
            next;
        }
        if (($g->{status} // '') eq 'running') {
            push @res, { vmid => $vmid + 0, from => $g->{node}, reason => 'already running' };
            next;
        }
        # expected demand while running
        $snap->{guests}->{$vmid} = { %$g, cpu => ($g->{maxcpu} || 1) * $INITIAL_CPU, mem => $g->{maxmem},
            memhost => $g->{maxmem}, netin => 0, netout => 0, psi_cpu => 0, psi_mem => 0 };
        delete $snap->{_demand};
        my $ev = PVE::WDCBalancer::Score::evaluate($snap, \%placement, $settings);

        # a stopped guest can only change node if it could be moved at all
        my %g2 = (%{$snap->{guests}->{$vmid}}, status => 'running');
        local $snap->{guests}->{$vmid} = \%g2;
        my ($movable, $why) = PVE::WDCBalancer::Constraints::movable($snap, $cfg, $vmid);

        my @rank;
        for my $node (@all_nodes) {
            my %row = (node => $node);
            my ($ok, $reason) = (1);
            if ($node ne $g->{node} && !$movable) {
                ($ok, $reason) = (0, $why);
            } else {
                ($ok, $reason) = PVE::WDCBalancer::Constraints::can_run($snap, $cfg, $vmid, $node);
            }
            if ($ok && !PVE::WDCBalancer::Constraints::fits($snap, $settings, $ev->{loads}->{$node}, $vmid, $node)) {
                ($ok, $reason) = (0, "not enough memory on $node");
            }
            if ($ok) {
                for my $r (grep { $_->{type} eq 'separate' } @$rules) {
                    next if !grep { $_ == $vmid } @{$r->{vms}};
                    my ($other) = grep { $_ != $vmid && ($placement{$_} // '') eq $node } @{$r->{vms}};
                    ($ok, $reason) = (0, "rule '$r->{name}' keeps it apart from $other") if $other;
                }
            }
            if ($ok) {
                my @partners = grep { $_ != $vmid && defined($placement{$_}) } @{ $units->{$vmid} // [] };
                my ($away) = grep { $placement{$_} ne $node } @partners;
                ($ok, $reason) = (0, "a keep-together rule ties it to $away on $placement{$away}") if $away;
            }
            $row{ok} = $ok ? 1 : 0;
            if ($ok) {
                my $soft = 0;
                for my $r (grep { $_->{type} eq 'vm-host' && $_->{mode} =~ /^should/ } @$rules) {
                    next if !grep { $_ == $vmid } @{ PVE::WDCBalancer::Config::rule_vms($cfg, $r) };
                    my $in = grep { $_ eq $node } @{ PVE::WDCBalancer::Config::rule_hosts($cfg, $r) };
                    $soft++ if $r->{mode} eq 'should' ? !$in : $in;
                }
                $row{soft} = $soft;
                my %p = (%placement, $vmid => $node);
                my $after = PVE::WDCBalancer::Score::evaluate($snap, \%p, $settings);
                $row{score} = sprintf('%.0f', $after->{scores}->{$vmid}) + 0;
                $row{objective} = $after->{objective};
            } else {
                $row{reason} = $reason;
            }
            push @rank, \%row;
        }
        my ($best) = sort { $a->{soft} <=> $b->{soft} || $b->{objective} <=> $a->{objective}
            || ($a->{node} eq $g->{node} ? -1 : $b->{node} eq $g->{node} ? 1 : $a->{node} cmp $b->{node}) }
            grep { $_->{ok} } @rank;
        delete $_->{objective} for @rank;
        if (!$best) {
            push @res, { vmid => $vmid + 0, from => $g->{node}, reason => 'no node can run it', ranking => \@rank };
            $snap->{guests}->{$vmid} = $g;
            next;
        }
        $placement{$vmid} = $best->{node};
        push @res, { vmid => $vmid + 0, name => $g->{name} // '', type => $g->{type}, ha => $g->{ha} ? 1 : 0,
            from => $g->{node}, to => $best->{node}, score => $best->{score}, ranking => \@rank };
    }
    delete $snap->{_demand};
    return \@res;
}

# vSphere-style reason for a balancing move
sub balance_reason {
    my ($snap, $ev, $placement, $unit, $target, $settings) = @_;
    my $u = $ev->{utils}->{ $placement->{ $unit->[0] } };
    my $obj_scores = 0;
    for my $vmid (@$unit) {
        my $tu = $ev->{utils}->{$target};
        my $after = PVE::WDCBalancer::Score::vm_score($snap, $vmid, $tu, $settings);
        $obj_scores = max($obj_scores, $after - $ev->{scores}->{$vmid});
    }
    return 'Improve VM DRS score' if $obj_scores >= 5;
    return 'Balance network load' if $settings->{network_aware} && $u->{net} > max($u->{cpu}, $u->{mem});
    return $u->{cpu} >= $u->{mem} ? 'Balance average CPU load' : 'Balance average memory load';
}

1;
