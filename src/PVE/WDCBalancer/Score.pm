package PVE::WDCBalancer::Score;

# Demand model and scores. Pure: works on a cluster snapshot (see
# PVE::WDCBalancer::Collect) and a placement { vmid => node }.
#
# Demand:
#   CPU    = cores used, raised by the guest's CPU pressure (PSI "some"):
#            time spent waiting for a CPU is demand the guest didn't get,
#            the counterpart of vSphere's CPU ready time.
#   memory = 'active': guest-reported used memory plus a quarter of the rest
#            of what the host holds for it (vSphere's default idle
#            consumed-memory share); 'consumed': host memory of the guest.
#            Raised by memory pressure (PSI "full").
#   net    = bytes/s in + out.
# Node load = the node's own overhead (usage not explained by its guests)
# plus the demand of the guests placed on it.
#
# VM score (0-100, like vSphere 7's VM DRS score): how much of its demand a
# guest would get where it is placed, from the CPU, memory and (with
# network-aware balancing) network contention of that node. The cluster
# score is the average VM score.

use strict;
use warnings;

use List::Util qw(min max sum0);

sub guest_demand {
    my ($g, $settings) = @_;
    my $cpu = ($g->{cpu} // 0) * (1 + ($g->{psi_cpu} // 0) / 100);
    my $mem;
    if (($settings->{memory_metric} // 'active') eq 'consumed') {
        $mem = $g->{memhost} // $g->{mem} // 0;
    } else {
        my $used = $g->{mem} // 0;
        my $host = $g->{memhost} // $used;
        $mem = $used + 0.25 * max(0, $host - $used);
    }
    $mem *= 1 + ($g->{psi_mem} // 0) / 100;
    my $net = ($g->{netin} // 0) + ($g->{netout} // 0);
    return { cpu => $cpu, mem => $mem, net => $net };
}

# Memory a guest needs on a target node to be live-migrated there.
sub guest_footprint {
    my ($g) = @_;
    return max($g->{memhost} // 0, $g->{mem} // 0);
}

# A node's load: overhead plus guests. $placement covers running guests only.
sub node_loads {
    my ($snap, $placement, $settings) = @_;
    my %load = map { $_ => { cpu => $snap->{nodes}->{$_}->{overhead_cpu} // 0,
        mem => $snap->{nodes}->{$_}->{overhead_mem} // 0, net => 0, foot => $snap->{nodes}->{$_}->{overhead_mem} // 0,
        guests => [] } } keys %{$snap->{nodes}};
    for my $vmid (keys %$placement) {
        my $node = $placement->{$vmid};
        my $l = $load{$node} // next;
        my $d = demand($snap, $vmid, $settings);
        $l->{cpu} += $d->{cpu};
        $l->{mem} += $d->{mem};
        $l->{net} += $d->{net};
        $l->{foot} += guest_footprint($snap->{guests}->{$vmid});
        push @{$l->{guests}}, $vmid;
    }
    return \%load;
}

# cached per snapshot + settings key
sub demand {
    my ($snap, $vmid, $settings) = @_;
    my $key = ($settings->{memory_metric} // 'active');
    return $snap->{_demand}->{$key}->{$vmid} //= guest_demand($snap->{guests}->{$vmid}, $settings);
}

sub utilization {
    my ($snap, $node, $load, $settings) = @_;
    my $n = $snap->{nodes}->{$node};
    my $cap_net = ($settings->{net_capacity} // 1250) * 1_000_000;
    return {
        cpu => $n->{maxcpu} ? $load->{cpu} / $n->{maxcpu} : 1,
        mem => $n->{maxmem} ? $load->{mem} / $n->{maxmem} : 1,
        net => $load->{net} / $cap_net,
    };
}

# efficiency (share of demand served) at a utilization
sub eff_cpu {
    my ($u) = @_;
    return 1 if $u <= 0.8;
    return 1 - 0.5 * ($u - 0.8) if $u <= 1;
    return 0.9 / $u;
}

sub eff_mem {
    my ($u) = @_;
    return 1 if $u <= 0.9;
    return 1 - 3 * ($u - 0.9) if $u <= 1;
    return 0.7 / $u;
}

sub eff_net {
    my ($u, $threshold) = @_;
    my $t = ($threshold // 80) / 100;
    return 1 if $u <= $t;
    return 1 - 0.5 * ($u - $t) / max(0.01, 1 - $t) if $u <= 1;
    return 0.5 / $u;
}

sub vm_score {
    my ($snap, $vmid, $util, $settings) = @_;
    my $d = demand($snap, $vmid, $settings);
    # a guest that hardly uses CPU barely notices CPU contention
    my $w_cpu = $d->{cpu} >= 0.1 ? 1 : $d->{cpu} / 0.1;
    my $cpu = 1 - (1 - eff_cpu($util->{cpu})) * $w_cpu;
    my $mem = eff_mem($util->{mem});
    my $net = 1;
    if ($settings->{network_aware}) {
        my $w_net = $d->{net} >= 1_000_000 ? 1 : $d->{net} / 1_000_000;
        $net = 1 - (1 - eff_net($util->{net}, $settings->{net_threshold})) * $w_net;
    }
    return 100 * min($cpu, $mem, $net);
}

sub bucket {
    my ($score) = @_;
    my $b = int($score / 20);
    $b = 4 if $b > 4;
    return ('0-20', '20-40', '40-60', '60-80', '80-100')[$b];
}

sub stddev {
    my (@v) = @_;
    return 0 if @v < 2;
    my $mean = sum0(@v) / @v;
    return sqrt(sum0(map { ($_ - $mean) ** 2 } @v) / @v);
}

# Nodes that count for balancing: online and not in maintenance.
sub active_nodes {
    my ($snap) = @_;
    return [ sort grep { my $n = $snap->{nodes}->{$_}; $n->{online} && !$n->{maintenance} } keys %{$snap->{nodes}} ];
}

sub imbalance {
    my ($snap, $utils) = @_;
    my @nodes = @{ active_nodes($snap) };
    my $cpu = stddev(map { $utils->{$_}->{cpu} } @nodes);
    my $mem = stddev(map { $utils->{$_}->{mem} } @nodes);
    return sqrt(($cpu ** 2 + $mem ** 2) / 2);
}

# Load spread: half the sum over active nodes of the squared deviations of
# CPU and memory utilization from the cluster mean. Moving load delta from a
# node at utilization a to one at b lowers it by about delta*(a-b) - delta^2,
# whatever the size of the cluster.
sub spread {
    my ($snap, $utils) = @_;
    my @nodes = @{ active_nodes($snap) };
    return 0 if @nodes < 2;
    my $ss = 0;
    for my $k (qw(cpu mem)) {
        my $mean = sum0(map { $utils->{$_}->{$k} } @nodes) / @nodes;
        $ss += sum0(map { ($utils->{$_}->{$k} - $mean) ** 2 } @nodes);
    }
    return $ss / 2;
}

# The objective is in VM-score points: the sum of all VM scores minus the
# load spread weighted so that evening out a tenth of a node's capacity
# between a busy and an idle node is worth about 10 points.
our $SPREAD_WEIGHT = 200;

# Full evaluation of a placement.
sub evaluate {
    my ($snap, $placement, $settings) = @_;
    my $loads = node_loads($snap, $placement, $settings);
    my %utils = map { $_ => utilization($snap, $_, $loads->{$_}, $settings) } keys %$loads;
    my %scores;
    for my $vmid (keys %$placement) {
        $scores{$vmid} = vm_score($snap, $vmid, $utils{$placement->{$vmid}}, $settings);
    }
    my @s = values %scores;
    my $cluster = @s ? sum0(@s) / @s : 100;
    my $imb = imbalance($snap, \%utils);
    my %buckets = map { $_ => 0 } ('0-20', '20-40', '40-60', '60-80', '80-100');
    $buckets{bucket($_)}++ for @s;
    return {
        loads => $loads,
        utils => \%utils,
        scores => \%scores,
        cluster => $cluster,
        imbalance => $imb,
        sum => sum0(@s),
        objective => sum0(@s) - $SPREAD_WEIGHT * spread($snap, \%utils),
        buckets => \%buckets,
    };
}

# Objective after moving @$vmids to $target, computed incrementally from an
# evaluation: only the source and target nodes' guests change score.
sub objective_after {
    my ($snap, $ev, $placement, $vmids, $target, $settings) = @_;
    my %touched;
    my %delta; # node => { cpu, mem, net }
    for my $vmid (@$vmids) {
        my $src = $placement->{$vmid};
        next if $src eq $target;
        my $d = demand($snap, $vmid, $settings);
        for my $k (qw(cpu mem net)) {
            $delta{$src}->{$k} -= $d->{$k};
            $delta{$target}->{$k} += $d->{$k};
        }
        $touched{$src} = $touched{$target} = 1;
    }
    return $ev->{objective} if !%touched;

    my %utils = %{$ev->{utils}};
    for my $node (keys %touched) {
        my $l = $ev->{loads}->{$node};
        my %nl = map { $_ => $l->{$_} + ($delta{$node}->{$_} // 0) } qw(cpu mem net);
        $utils{$node} = utilization($snap, $node, \%nl, $settings);
    }

    my %moving = map { $_ => 1 } @$vmids;
    my $sum = $ev->{sum};
    for my $node (keys %touched) {
        for my $vmid (@{$ev->{loads}->{$node}->{guests}}) {
            next if $moving{$vmid};
            $sum += vm_score($snap, $vmid, $utils{$node}, $settings) - $ev->{scores}->{$vmid};
        }
    }
    for my $vmid (@$vmids) {
        $sum += vm_score($snap, $vmid, $utils{$target}, $settings) - $ev->{scores}->{$vmid};
    }
    return $sum - $SPREAD_WEIGHT * spread($snap, \%utils);
}

1;
