use strict;
use warnings;

use Test::More;
use Storable qw(dclone);

use StubPVE;
use SnapFixture qw(GiB);
use RandomCluster qw(random_cluster);
use PVE::WDCBalancer::Config;
use PVE::WDCBalancer::Constraints;
use PVE::WDCBalancer::Engine;
use PVE::WDCBalancer::Score;

# Properties of a pass over random clusters. Every recommendation, in
# order, must be a move the constraints allow from where the guest is at
# that point; balancing moves must improve the objective and keep soft
# rules; a pass that stopped on its own is a fixed point (passing again on
# its result recommends no balancing and moves nothing back).
#
# WDCB_SEEDS=n runs more clusters; a failure names its seed.

my $E = 'PVE::WDCBalancer::Engine';
my $C = 'PVE::WDCBalancer::Config';
my $N = $ENV{WDCB_SEEDS} // 300;

sub placement_of {
    my ($snap) = @_;
    return { map { $_ => $snap->{guests}->{$_}->{node} }
        grep { $snap->{guests}->{$_}->{status} eq 'running' && $snap->{nodes}->{ $snap->{guests}->{$_}->{node} } }
        keys %{$snap->{guests}} };
}

my ($clusters, $with_recs, $recs_checked, $fixpoints) = (0, 0, 0, 0);
my @fail;
for my $seed (1 .. $N) {
    my ($snap, $cfg) = random_cluster($seed);
    my $settings = $C->can('settings')->($cfg);
    my $res = eval { $E->can('pass')->(dclone($snap), $cfg) };
    if (!$res) {
        push @fail, "seed $seed: pass died: $@";
        next;
    }
    $clusters++;
    my $again = $E->can('pass')->(dclone($snap), $cfg);
    push @fail, "seed $seed: not deterministic"
        if join(';', map { $_->{id} } @{$res->{recommendations}}) ne join(';', map { $_->{id} } @{$again->{recommendations}});

    my $recs = $res->{recommendations};
    $with_recs++ if @$recs;
    my %p = %{ placement_of($snap) };
    my %moved;
    my @rules = @{ $C->can('enabled_rules')->($cfg) };
    my $ev = PVE::WDCBalancer::Score::evaluate(dclone($snap), \%p, $settings);
    my %received;
    for my $r (@$recs) {
        $recs_checked++;
        my $what = "seed $seed: $r->{id} ($r->{kind})";
        my $g = $snap->{guests}->{ $r->{vmid} };
        my ($ok, $why) = PVE::WDCBalancer::Constraints::movable($snap, $cfg, $r->{vmid});
        push @fail, "$what: guest not movable ($why)" if !$ok;
        push @fail, "$what: guest is on $p{$r->{vmid}}, not $r->{from}" if ($p{$r->{vmid}} // '') ne $r->{from};
        push @fail, "$what: guest moved twice in one pass" if $moved{$r->{vmid}}++;
        ($ok, $why) = PVE::WDCBalancer::Constraints::can_run($snap, $cfg, $r->{vmid}, $r->{to});
        push @fail, "$what: target not allowed ($why)" if !$ok;
        push @fail, "$what: guest without usage data moved for balancing" if $r->{kind} eq 'balance' && !$g->{samples};
        push @fail, "$what: recommended during a hold" if $r->{kind} ne 'maintenance' && $r->{priority} > 1 && $res->{cluster}->{hold};
        push @fail, "$what: priority $r->{priority} above threshold $settings->{threshold}"
            if $r->{kind} eq 'balance' && $r->{priority} > $settings->{threshold};
        for my $rule (grep { $_->{type} eq 'separate' } @rules) {
            next if !grep { $_ == $r->{vmid} } @{$rule->{vms}};
            my @there = grep { $_ != $r->{vmid} && ($p{$_} // '') eq $r->{to} } @{$rule->{vms}};
            push @fail, "$what: breaks separate rule '$rule->{name}' (with @there)" if @there;
        }
        if ($r->{kind} eq 'balance') {
            for my $rule (grep { $_->{type} eq 'vm-host' && $_->{mode} =~ /^should/ } @rules) {
                next if !grep { $_ == $r->{vmid} } @{ $C->can('rule_vms')->($cfg, $rule) };
                my $in = grep { $_ eq $r->{to} } @{ $C->can('rule_hosts')->($cfg, $rule) };
                push @fail, "$what: balancing breaks soft rule '$rule->{name}'" if $rule->{mode} eq 'should' ? !$in : $in;
            }
        }
        $p{$r->{vmid}} = $r->{to};
        $received{$r->{to}} = 1;
    }
    $ev = PVE::WDCBalancer::Score::evaluate(dclone($snap), \%p, $settings);
    # balancing, all in all, improves the objective over the mandatory moves alone
    if (grep { $_->{kind} eq 'balance' } @$recs) {
        my %m = %{ placement_of($snap) };
        $m{$_->{vmid}} = $_->{to} for grep { $_->{kind} ne 'balance' } @$recs;
        my $mand = PVE::WDCBalancer::Score::evaluate(dclone($snap), \%m, $settings)->{objective};
        push @fail, sprintf("seed %d: balancing lowers the objective (%.2f -> %.2f)", $seed, $mand, $ev->{objective})
            if $ev->{objective} < $mand - 1e-6;
    }
    for my $n (sort keys %received) {
        my $limit = $snap->{nodes}->{$n}->{maxmem} * (1 - $settings->{headroom} / 100);
        push @fail, sprintf("seed %d: %s over its memory limit after the moves (%.1f > %.1f GiB)", $seed, $n,
            $ev->{loads}->{$n}->{foot} / GiB(1), $limit / GiB(1)) if $ev->{loads}->{$n}->{foot} > $limit + 1;
    }
    for my $rule (grep { $_->{type} eq 'separate' } @rules) {
        my %on;
        for my $v (grep { defined($p{$_}) && $moved{$_} } @{$rule->{vms}}) {
            push @fail, "seed $seed: separate rule '$rule->{name}': moved $v shares $p{$v}" if $on{ $p{$v} };
            $on{ $p{$v} } = 1;
        }
    }

    # fixed point: apply the moves and pass again (no cooldown, no dismissals)
    my $balancing = grep { $_->{kind} eq 'balance' } @$recs;
    next if $balancing >= $settings->{max_moves} || $res->{cluster}->{hold};
    my $next = dclone($snap);
    $next->{guests}->{$_}->{node} = $p{$_} for keys %moved;
    my $res2 = $E->can('pass')->($next, $cfg);
    $fixpoints++;
    my %first = map { $_->{vmid} => $_->{from} } @$recs;
    # mandatory moves don't aim for balance: a guest they moved may be balanced
    # later, and one they could only place now changes the load
    my $units = $E->can('together_units')->($cfg);
    my %mandatory = map { $_ => 1 } map { @{ $units->{$_->{vmid}} // [ $_->{vmid} ] } } grep { $_->{kind} ne 'balance' } @$recs;
    # ... so the checks hold when the second pass only balances guests the first
    # pass balanced or left alone
    my $settled = !grep { $_->{kind} ne 'balance' || $mandatory{$_->{vmid}} } @{$res2->{recommendations}};
    my %balanced = map { $_->{vmid} => 1 } grep { $_->{kind} eq 'balance' } @$recs;
    for my $r (@{$res2->{recommendations}}) {
        # greedy passes may find a little more (one move per guest and pass),
        # never much more
        push @fail, "seed $seed: second pass recommends balancing again ($r->{id}, priority $r->{priority})"
            if $settled && $r->{priority} < 5;
        push @fail, "seed $seed: second pass moves $r->{vmid} back to $r->{to}"
            if $settled && $balanced{$r->{vmid}} && $first{$r->{vmid}} eq $r->{to};
    }
}

ok($clusters == $N, "$clusters random clusters passed without error");
ok($with_recs > $N / 4, "$with_recs of them had recommendations, $recs_checked checked");
ok($fixpoints > $N / 2, "$fixpoints fixed-point checks");
is(scalar(@fail), 0, 'every property holds') or diag(join("\n", @fail[0 .. ($#fail < 30 ? $#fail : 29)]));

done_testing();
