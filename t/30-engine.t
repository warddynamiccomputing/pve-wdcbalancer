use strict;
use warnings;

use Test::More;

use StubPVE;
use SnapFixture qw(GiB);
use PVE::WDCBalancer::Engine;

my $E = 'PVE::WDCBalancer::Engine';

sub cfg {
    my (%o) = @_;
    return { version => 1, settings => $o{settings} // {}, vm_groups => $o{vm_groups} // {},
        host_groups => $o{host_groups} // {}, rules => $o{rules} // {}, overrides => $o{overrides} // {}, maintenance => {} };
}

sub moves {
    my ($res) = @_;
    return [ map { "$_->{vmid}:$_->{from}>$_->{to}" } @{$res->{recommendations}} ];
}

sub three_nodes {
    my $s = SnapFixture->new;
    $s->node($_, cpus => 16, mem => 128) for qw(n1 n2 n3);
    return $s;
}

# ---------------- balanced cluster: nothing to do ----------------
{
    my $s = three_nodes();
    $s->guest(100 + $_, "n" . (1 + $_ % 3), cpu => 2, mem => 8) for 0 .. 8;
    my $r = $E->can('pass')->($s->snap, cfg());
    is_deeply(moves($r), [], 'balanced cluster: no recommendations');
    is($r->{cluster}->{score}, 100, 'every VM happy');
    is($r->{cluster}->{buckets}->{'80-100'}, 9, 'all in the top bucket');
}

# ---------------- CPU contention on one node ----------------
{
    my $s = three_nodes();
    $s->guest(100 + $_, 'n1', cpu => 3, mem => 4, vcpus => 4) for 1 .. 6; # 18 cores on 16
    $s->guest(201, 'n2', cpu => 1, mem => 4);
    my $r = $E->can('pass')->($s->snap, cfg());
    my @m = @{ moves($r) };
    ok(@m >= 2, 'overloaded node: guests moved off') or diag explain \@m;
    ok(!grep({ !/:n1>/ } @m), 'only from the overloaded node');
    ok($r->{cluster}->{score} < 100, 'contention lowers the cluster score');
    is($r->{cluster}->{expected}, 100, 'expected score after the moves is 100');
    is($r->{recommendations}->[0]->{kind}, 'balance', 'balancing move');
    like($r->{recommendations}->[0]->{reason}, qr/DRS score|CPU/, 'vSphere-style reason');
    ok($r->{recommendations}->[0]->{priority} <= 3, 'within the default threshold');
    ok(!$r->{nodes}->{n1}->{expected_cpu} || $r->{nodes}->{n1}->{expected_cpu} <= 0.8, 'n1 below contention afterwards');
}

# ---------------- threshold ----------------
{
    my $s = three_nodes();
    $s->guest(100 + $_, 'n1', cpu => 1.5, mem => 4) for 1 .. 6; # 9 of 16 cores: no contention, imbalanced
    my $mild = $E->can('pass')->($s->snap, cfg(settings => { threshold => 2 }));
    my $aggr = $E->can('pass')->($s->snap, cfg(settings => { threshold => 5 }));
    my $one = $E->can('pass')->($s->snap, cfg(settings => { threshold => 1 }));
    is_deeply(moves($one), [], 'threshold 1: only mandatory moves');
    ok(@{moves($aggr)} > @{moves($mild)}, 'threshold 5 balances more than threshold 2');
    ok(!grep({ $_->{priority} > 2 } @{$mild->{recommendations}}), 'threshold 2: priorities 1-2 only');
    ok($aggr->{cluster}->{expected_imbalance} < $aggr->{cluster}->{imbalance}, 'aggressive pass reduces imbalance');
}

# ---------------- max moves and cooldown ----------------
{
    my $s = three_nodes();
    $s->guest(100 + $_, 'n1', cpu => 2, mem => 4) for 1 .. 12;
    my $r = $E->can('pass')->($s->snap, cfg(settings => { threshold => 5, max_moves => 2 }));
    is(scalar(@{moves($r)}), 2, 'max_moves limits balancing moves');
    my $now = 1_000_000;
    my %moved = map { (100 + $_) => $now - 60 } 1 .. 12;
    $r = $E->can('pass')->($s->snap, cfg(settings => { threshold => 5 }), now => $now, moved => \%moved);
    is_deeply(moves($r), [], 'guests moved within the cooldown stay put');
    $r = $E->can('pass')->($s->snap, cfg(settings => { threshold => 5 }), now => $now + 7200, moved => \%moved);
    ok(@{moves($r)}, 'after the cooldown they may move again');
}

# ---------------- dismissed ----------------
{
    my $s = three_nodes();
    $s->guest(100 + $_, 'n1', cpu => 3, mem => 4) for 1 .. 6;
    my $first = $E->can('pass')->($s->snap, cfg());
    my $id = $first->{recommendations}->[0]->{id};
    my $r = $E->can('pass')->($s->snap, cfg(), now => 5000, dismissed => { $id => 4000 });
    ok(!grep({ $_->{id} eq $id } @{$r->{recommendations}}), 'a dismissed move is not recommended again');
}

# ---------------- heterogeneous nodes ----------------
{
    my $s = SnapFixture->new;
    $s->node('big1', cpus => 96, mem => 768);
    $s->node('big2', cpus => 96, mem => 768);
    $s->node('small', cpus => 8, mem => 768);
    $s->guest(100 + $_, 'big1', cpu => 6, mem => 16, vcpus => 8) for 1 .. 20; # 120 cores on 96
    my $r = $E->can('pass')->($s->snap, cfg());
    my %to;
    $to{ $_->{to} }++ for @{$r->{recommendations}};
    ok(($to{big2} // 0) > ($to{small} // 0), 'most guests go to the big node');
    ok(($r->{nodes}->{small}->{expected_cpu} // 0) <= 0.8, 'the 8-core node is not overloaded');
}

# ---------------- what can't move ----------------
{
    my $s = three_nodes();
    $s->guest(101, 'n1', cpu => 6, storage => 'local');
    $s->guest(102, 'n1', cpu => 6, devices => ['hostpci0']);
    $s->guest(103, 'n1', cpu => 6, lock => 'backup');
    $s->guest(104, 'n1', cpu => 6);
    my $r = $E->can('pass')->($s->snap, cfg(overrides => { 104 => { automation => 'disabled' } }));
    is_deeply(moves($r), [], 'nothing movable: no recommendations');
    like($r->{guests}->{101}->{reason}, qr/local storage/, 'local disk');
    like($r->{guests}->{102}->{reason}, qr/passed through/, 'passthrough');
    like($r->{guests}->{103}->{reason}, qr/locked/, 'locked');
    like($r->{guests}->{104}->{reason}, qr/disabled/, 'override disabled');
    is($r->{cluster}->{movable}, 0, 'movable count');
}

# ---------------- target checks ----------------
{
    my $s = SnapFixture->new;
    $s->node('n1', cpus => 16);
    $s->node('n2', cpus => 16, bridges => ['vmbr1']);
    $s->node('n3', cpus => 16, storages => ['local']);
    $s->node('n4', cpus => 16, cpu_flags => 'fpu sse sse2 avx512f');
    $s->node('n5', cpus => 16, online => 0);
    $s->guest(100 + $_, 'n1', cpu => 3, cpu_type => 'host') for 1 .. 6;
    my $r = $E->can('pass')->($s->snap, cfg());
    is_deeply(moves($r), [], 'no valid target: missing bridge, storage, other CPU, offline');
    my $x = $E->can('explain')->($s->snap, cfg(), 101);
    my %why = map { $_->{node} => $_->{reason} // '' } @$x;
    like($why{n2}, qr/bridge 'vmbr0'/, 'explain: bridge');
    like($why{n3}, qr/storage 'shared'/, 'explain: storage');
    like($why{n4}, qr/CPU type 'host'/, 'explain: CPU');
    like($why{n5}, qr/offline/, 'explain: offline');
    ok((grep { $_->{current} } @$x) == 1, 'explain: current node marked');
}

# ---------------- memory fit and headroom ----------------
{
    my $s = SnapFixture->new;
    $s->node('n1', cpus => 16, mem => 64);
    $s->node('n2', cpus => 16, mem => 64, overhead_mem => 40);
    $s->guest(101, 'n1', cpu => 10, mem => 20);
    $s->guest(102, 'n1', cpu => 10, mem => 20);
    my $r = $E->can('pass')->($s->snap, cfg());
    is_deeply(moves($r), [], 'no move into a node without memory for it (headroom kept)');
}

# ---------------- memory demand metric ----------------
{
    my $s = three_nodes();
    $s->guest(100 + $_, 'n1', cpu => 0.2, mem => 10, memhost => 30) for 1 .. 4; # 120 GiB consumed on 128
    my $active = $E->can('pass')->($s->snap, cfg());
    my $consumed = $E->can('pass')->($s->snap, cfg(settings => { memory_metric => 'consumed' }));
    is_deeply(moves($active), [], 'active memory: no memory contention');
    ok(@{moves($consumed)}, 'consumed memory: contention, moves recommended');
}

# ---------------- containers and HA guests ----------------
{
    my $s = three_nodes();
    $s->guest(101, 'n1', cpu => 9, type => 'lxc', disks => [ { key => 'rootfs', storage => 'shared' } ]);
    $s->guest(102, 'n1', cpu => 9, ha => 1);
    my $r = $E->can('pass')->($s->snap, cfg());
    my %rec = map { $_->{vmid} => $_ } @{$r->{recommendations}};
    ok(%rec, 'something recommended');
    is($rec{101}->{restart}, 1, 'container moves are flagged as restarts') if $rec{101};
    is($rec{102}->{ha}, 1, 'HA guests are flagged') if $rec{102};
}

# ---------------- stopped guests and templates ----------------
{
    my $s = three_nodes();
    $s->guest(101, 'n1', cpu => 20, status => 'stopped');
    my $r = $E->can('pass')->($s->snap, cfg());
    is_deeply(moves($r), [], 'stopped guests are not balanced');
    is($r->{cluster}->{running}, 0, 'and not counted');
}

# ---------------- no ping-pong ----------------
{
    my $s = three_nodes();
    $s->guest(100 + $_, 'n1', cpu => 3, mem => 8) for 1 .. 6;
    my $snap = $s->snap;
    my $r = $E->can('pass')->($snap, cfg());
    # apply the recommendations and run again
    my $s2 = three_nodes();
    my %at = map { $_->{vmid} => $_->{to} } @{$r->{recommendations}};
    $s2->guest(100 + $_, $at{100 + $_} // 'n1', cpu => 3, mem => 8) for 1 .. 6;
    my $again = $E->can('pass')->($s2->snap, cfg());
    is_deeply(moves($again), [], 'after applying, the next pass recommends nothing');
}

# ---------------- cost-benefit ----------------
{
    my $s = three_nodes();
    $s->guest(101, 'n1', cpu => 1, mem => 4);
    $s->guest(102, 'n1', cpu => 1, mem => 4);
    my $cheap = $E->can('pass')->($s->snap, cfg(settings => { threshold => 5 }));
    my $slow = $E->can('pass')->($s->snap, cfg(settings => { threshold => 5, migration_speed => 10 }));
    ok(@{moves($slow)} < @{moves($cheap)} || !@{moves($cheap)}, 'a slow migration network makes small gains not worth it');
}

is($E->can('priority_for_gain')->(60), 2, 'priority 2 for big gains');
is($E->can('priority_for_gain')->(1), undef, 'no recommendation for tiny gains');

# ---------------- holds: quorum, settling, missing data ----------------
{
    my $contended = sub {
        my $s = three_nodes();
        $s->guest(100 + $_, 'n1', cpu => 3, mem => 4, @_) for 1 .. 6;
        $s->guest(110, 'n2', cpu => 1, mem => 4);
        return $s->snap;
    };
    my $base = $E->can('pass')->($contended->(), cfg());
    ok(@{$base->{recommendations}} >= 1, 'contended cluster: balancing moves');
    ok(!$base->{cluster}->{hold}, 'no hold');
    is($base->{cluster}->{quorate}, 1, 'quorate when the snapshot does not say otherwise');
    ok($base->{recommendations}->[0]->{mem} > 0, 'recommendations carry the memory the move needs');

    my $snap = $contended->();
    $snap->{quorate} = 0;
    $snap->{nodes}->{n2}->{maintenance} = 1;
    my $r = $E->can('pass')->($snap, cfg());
    is_deeply(moves($r), [], 'no quorum: nothing at all, not even maintenance moves');
    ok((grep { $_->{type} eq 'quorum' } @{$r->{faults}}), 'a quorum fault');
    is($r->{cluster}->{expected}, $r->{cluster}->{score}, 'and no expected change');

    $snap = $contended->();
    $snap->{nodes}->{n2}->{maintenance} = 1;
    $r = $E->can('pass')->($snap, cfg(), settling => 300);
    is_deeply([ map { $_->{kind} } @{$r->{recommendations}} ], ['maintenance'], 'settling: only mandatory moves');
    like($r->{cluster}->{hold}, qr/waiting 5 more minute/, 'with the time left');
    ok((grep { $_->{type} eq 'hold' } @{$r->{faults}}), 'and a hold fault');

    $snap = $contended->();
    $snap->{nodes}->{n3}->{samples} = 0;
    $r = $E->can('pass')->($snap, cfg());
    is_deeply(moves($r), [], 'a node without recent data: no balancing');
    like($r->{cluster}->{hold}, qr/no recent usage data for node\(s\) n3/, 'and why');
    $snap->{nodes}->{n3}->{online} = 0;
    $r = $E->can('pass')->($snap, cfg());
    ok(!$r->{cluster}->{hold}, 'an offline node without data is no reason to hold');

    $snap = $contended->();
    $snap->{guests}->{$_}->{samples} = 0 for 101, 102;
    $r = $E->can('pass')->($snap, cfg());
    like($r->{cluster}->{hold}, qr/2 of 7 running guests have no recent usage data/, 'too many guests without data: hold');

    $snap = $contended->();
    $snap->{guests}->{101}->{samples} = 0;
    $r = $E->can('pass')->($snap, cfg());
    ok(!$r->{cluster}->{hold}, 'one guest without data: no hold');
    ok(@{$r->{recommendations}}, 'the others are balanced');
    ok(!grep({ $_->{vmid} == 101 } @{$r->{recommendations}}), 'but the guest without data is not moved');
}

# ---------------- move costs: fixed part, bouncing back, tolerated imbalance ----------------
{
    my $s = three_nodes();
    $s->guest(100 + $_, 'n1', cpu => 3, mem => 4) for 1 .. 6;
    my $now = 1_000_000;
    my $r = $E->can('pass')->($s->snap, cfg(), now => $now);
    my ($first) = @{$r->{recommendations}};
    ok($first, 'a balancing move');
    ok($E->can('move_cost')->($s->snap, {}, [ $first->{vmid} ]) >= $PVE::WDCBalancer::Engine::MOVE_COST,
        'every migration costs at least the fixed part');
    my $left = { $first->{vmid} => { node => $first->{to}, time => $now - 600 } };
    my $r2 = $E->can('pass')->($s->snap, cfg(), now => $now, left => $left);
    my ($same) = grep { $_->{vmid} == $first->{vmid} && $_->{to} eq $first->{to} } @{$r2->{recommendations}};
    ok(!$same || $same->{gain} <= $first->{gain} - $PVE::WDCBalancer::Engine::BOUNCE_COST + 0.1,
        'moving a guest back where it just came from costs more');
    $left->{ $first->{vmid} }->{time} = $now - $PVE::WDCBalancer::Engine::BOUNCE_WINDOW;
    my $r3 = $E->can('pass')->($s->snap, cfg(), now => $now, left => $left);
    is_deeply(moves($r3), moves($r), 'not after the bounce window');

    # every VM happy, imbalance within the threshold's tolerance: nothing to do
    $s = three_nodes();
    $s->guest(101, 'n1', cpu => 2, mem => 8);
    $s->guest(102, 'n1', cpu => 1, mem => 8);
    $s->guest(103, 'n2', cpu => 2, mem => 8);
    $s->guest(104, 'n3', cpu => 1, mem => 8);
    my $calm = $E->can('pass')->($s->snap, cfg(settings => { threshold => 5 }));
    ok($calm->{cluster}->{imbalance} <= $PVE::WDCBalancer::Engine::TOLERANCE{5}, 'slightly uneven, within tolerance');
    is_deeply(moves($calm), [], 'every VM happy within tolerance: no moves, even at threshold 5');
}

done_testing();
