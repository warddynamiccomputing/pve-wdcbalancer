use strict;
use warnings;

use Test::More;
use Storable qw(dclone);

use StubPVE;
use SnapFixture qw(GiB);
use PVE::WDCBalancer::Engine;

# Many passes in a row, every recommendation applied (full automation),
# five minutes apart, with noisy load. The balancer must settle and stay
# settled: no guest bouncing between nodes, few moves while only the noise
# changes, and a quick recovery when the load really shifts.

my $E = 'PVE::WDCBalancer::Engine';
my $STEP = 300;

sub run_sim {
    my (%o) = @_;
    srand($o{seed});
    my $s = SnapFixture->new;
    $s->node($_, cpus => 32, mem => 256) for qw(n1 n2 n3 n4 n5);
    my %base;
    for my $i (1 .. 40) {
        my $vmid = 100 + $i;
        $base{$vmid} = 0.5 + rand(5.5);
        # everything starts on two nodes
        $s->guest($vmid, $i % 2 ? 'n1' : 'n2', vcpus => 8, cpu => $base{$vmid}, mem => 4 + int(rand(12)));
    }
    my $snap = $s->snap;
    my $cfg = { version => 1, settings => { threshold => $o{threshold}, cooldown => 1800 }, vm_groups => {},
        host_groups => {}, rules => {}, overrides => {}, maintenance => {} };
    my (%moved, %left, @log, @scores);
    my $now = 1_000_000;
    for my $pass (1 .. $o{passes}) {
        $now += $STEP;
        $o{shift}->(\%base, $pass) if $o{shift};
        for my $vmid (sort keys %base) {
            $snap->{guests}->{$vmid}->{cpu} = $base{$vmid} * (1 + $o{noise} * (2 * rand() - 1));
        }
        my $res = $E->can('pass')->(dclone($snap), $cfg, now => $now, moved => \%moved, left => \%left);
        push @scores, $res->{cluster}->{score};
        for my $r (@{$res->{recommendations}}) {
            $snap->{guests}->{$r->{vmid}}->{node} = $r->{to};
            $moved{$r->{vmid}} = $now;
            $left{$r->{vmid}} = { node => $r->{from}, time => $now };
            push @log, { pass => $pass, time => $now, vmid => $r->{vmid}, from => $r->{from}, to => $r->{to} };
        }
    }
    return (\@log, \@scores, \%base);
}

# guests that went A -> B -> A within $window seconds
sub bounces {
    my ($log, $window) = @_;
    my (%last, @b);
    for my $m (@$log) {
        my $l = $last{$m->{vmid}};
        push @b, "$m->{vmid} $l->{from}->$l->{to}->$m->{to} (passes $l->{pass}, $m->{pass})"
            if $l && $m->{to} eq $l->{from} && $m->{time} - $l->{time} < $window;
        $last{$m->{vmid}} = $m;
    }
    return \@b;
}

for my $threshold (2, 3, 4, 5) {
    for my $seed (1 .. 3) {
        my $tag = "threshold $threshold, seed $seed";
        # load shift at pass 100: five guests on one node get three times busier
        my @hot;
        my ($log, $scores, $base) = run_sim(seed => $seed, threshold => $threshold, passes => 160, noise => 0.15,
            shift => sub {
                my ($base, $pass) = @_;
                return if $pass != 100;
                @hot = (101, 103, 105, 107, 109);
                $base->{$_} *= 3 for @hot;
            });
        my @settle = grep { $_->{pass} <= 24 } @$log;
        my @steady = grep { $_->{pass} > 24 && $_->{pass} < 100 } @$log;
        my @after = grep { $_->{pass} >= 100 } @$log;
        ok(@settle >= 5, "$tag: the initial imbalance is balanced (" . scalar(@settle) . " moves)");
        ok($scores->[23] >= 90, "$tag: cluster score $scores->[23] after two hours");
        # noise alone: next to nothing (75 passes, 40 guests); threshold 5
        # (aggressive) acts on small gains, up to about one move every two passes
        ok(@steady <= ($threshold >= 5 ? 40 : 6), "$tag: " . scalar(@steady) . " moves in 75 passes of noise only");
        my $bounced = bounces($log, 4 * 3600);
        is_deeply($bounced, [], "$tag: no guest bounces back within four hours");
        # recovery: good scores again when the cluster can carry the load,
        # better than at the shift when it can't
        my $demand = 0;
        $demand += $_ for values %$base;
        if ($demand <= 0.95 * 5 * 32) {
            ok($scores->[107] >= 85, "$tag: recovered from the load shift within 40 minutes (score $scores->[107])");
        } else {
            ok($scores->[107] >= $scores->[99], "$tag: overloaded after the shift, no worse within 40 minutes ($scores->[99] -> $scores->[107])");
        }
        ok(@after >= 1, "$tag: the load shift is acted on");
    }
}

done_testing();
