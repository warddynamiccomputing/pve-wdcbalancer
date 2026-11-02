use strict;
use warnings;

use Test::More;

use StubPVE;
use SnapFixture qw(GiB);
use PVE::WDCBalancer::Config;
use PVE::WDCBalancer::Engine;

my $C = 'PVE::WDCBalancer::Config';
my $pass = PVE::WDCBalancer::Engine->can('pass');

sub cfg {
    my (%o) = @_;
    return { version => 1, settings => $o{settings} // {}, vm_groups => $o{vm_groups} // {},
        host_groups => $o{host_groups} // {}, rules => $o{rules} // {}, overrides => {}, maintenance => {} };
}

sub moves { return [ map { "$_->{vmid}:$_->{from}>$_->{to}" } @{$_[0]->{recommendations}} ]; }

sub cluster {
    my $s = SnapFixture->new;
    $s->node($_, cpus => 32, mem => 256) for qw(n1 n2 n3 n4);
    return $s;
}

# ---------------- validation ----------------
{
    is_deeply($C->can('validate')->(cfg()), [], 'empty config is valid');
    my $bad = cfg(settings => { threshold => 7, automation => 'auto', bogus => 1 });
    my $err = join("\n", @{ $C->can('validate')->($bad) });
    like($err, qr/threshold.*between 1 and 5/, 'threshold range');
    like($err, qr/automation.*one of/, 'automation enum');
    like($err, qr/unknown setting 'bogus'/, 'unknown setting');

    $err = join("\n", @{ $C->can('validate')->(cfg(
        vm_groups => { web => { members => [ 101, 'x' ] }, empty => { members => [] } },
        host_groups => { web => { members => ['n1'] } },
        rules => {
            r1 => { type => 'vm-host', vm_group => 'nope', host_group => 'web', mode => 'must' },
            r2 => { type => 'together', vms => [101] },
            r3 => { type => 'magic' },
            '1bad' => { type => 'separate', vms => [101, 102] },
        },
    )) });
    like($err, qr/group 'web': invalid VM ID 'x'/, 'bad VM ID in group');
    like($err, qr/group 'empty' has no members/, 'empty group');
    like($err, qr/'web' is both a VM group and a host group/, 'group name clash');
    like($err, qr/rule 'r1': unknown VM group 'nope'/, 'unknown group');
    like($err, qr/rule 'r2': needs at least two VMs/, 'VM-VM rule needs two VMs');
    like($err, qr/rule 'r3': unknown type/, 'unknown rule type');
    like($err, qr/invalid rule name '1bad'/, 'rule name');
}

# ---------------- conflicts ----------------
{
    my $base = sub {
        my (%rules) = @_;
        return cfg(
            vm_groups => { a => { members => [101] }, ab => { members => [101, 102] } },
            host_groups => { h1 => { members => ['n1'] }, h2 => { members => ['n2'] }, h12 => { members => ['n1', 'n2'] } },
            rules => \%rules,
        );
    };
    my $conf = sub { join("\n", @{ $C->can('rule_conflicts')->($base->(@_)) }) };

    like($conf->(t => { type => 'together', vms => [101, 102, 103] }, s => { type => 'separate', vms => [102, 103] }),
        qr/'t' and 's' conflict/, 'together vs separate');
    is($conf->(t => { type => 'together', vms => [101, 102] }, s => { type => 'separate', vms => [102, 103] }), '',
        'sharing one VM is fine');
    like($conf->(m1 => { type => 'vm-host', vm_group => 'a', host_group => 'h1', mode => 'must' },
        m2 => { type => 'vm-host', vm_group => 'a', host_group => 'h2', mode => 'must' }),
        qr/VM 101 is left with no node/, 'two must rules with disjoint hosts');
    like($conf->(m1 => { type => 'vm-host', vm_group => 'a', host_group => 'h1', mode => 'must' },
        m2 => { type => 'vm-host', vm_group => 'a', host_group => 'h12', mode => 'must-not' }),
        qr/VM 101 is left with no node/, 'must + must-not covering it');
    is($conf->(m1 => { type => 'vm-host', vm_group => 'a', host_group => 'h12', mode => 'must' },
        m2 => { type => 'vm-host', vm_group => 'a', host_group => 'h2', mode => 'must-not' }), '',
        'must + must-not leaving n1 is fine');
    is($conf->(m1 => { type => 'vm-host', vm_group => 'a', host_group => 'h1', mode => 'must' },
        m2 => { type => 'vm-host', vm_group => 'a', host_group => 'h2', mode => 'should' }), '',
        'should rules never conflict');
    is($conf->(m1 => { type => 'vm-host', vm_group => 'a', host_group => 'h1', mode => 'must', enabled => 0 },
        m2 => { type => 'vm-host', vm_group => 'a', host_group => 'h2', mode => 'must' }), '',
        'disabled rules are ignored');
    like($conf->(t => { type => 'together', vms => [101, 103] },
        m1 => { type => 'vm-host', vm_group => 'a', host_group => 'h1', mode => 'must' },
        m3 => { type => 'vm-host', vm_group => 'ab', host_group => 'h2', mode => 'must' }),
        qr/VM 101 is left with no node/, 'together + must conflicts reported');
    my $c = $base->();
    $c->{vm_groups}->{x} = { members => [103] };
    $c->{rules} = {
        t => { type => 'together', vms => [101, 103] },
        m1 => { type => 'vm-host', vm_group => 'a', host_group => 'h1', mode => 'must' },
        m3 => { type => 'vm-host', vm_group => 'x', host_group => 'h2', mode => 'must' },
    };
    like(join("\n", @{ $C->can('rule_conflicts')->($c) }), qr/'t' conflicts with VM\/Host 'must' rules/,
        'keep-together VMs bound to different hosts');
    like($conf->(s => { type => 'separate', vms => [101, 102, 103] },
        m => { type => 'vm-host', vm_group => 'ab', host_group => 'h1', mode => 'must' },
        m2 => { type => 'vm-host', vm_group => 'ab', host_group => 'h12', mode => 'must' }),
        qr//, 'separate rule count check runs');

    my $err = $C->can('validate')->($base->(t => { type => 'together', vms => [101, 102] }, s => { type => 'separate', vms => [101, 102] }));
    ok(@$err, 'validate refuses a conflicting config');
}

# ---------------- must rules ----------------
{
    my $s = cluster();
    $s->guest(101, 'n1', cpu => 1);
    $s->guest(102, 'n2', cpu => 1);
    my $c = cfg(
        vm_groups => { db => { members => [101, 102] } },
        host_groups => { dbhosts => { members => ['n3', 'n4'] } },
        rules => { db_on => { type => 'vm-host', vm_group => 'db', host_group => 'dbhosts', mode => 'must' } },
    );
    my $r = $pass->($s->snap, $c, now => 1);
    my %to = map { $_->{vmid} => $_->{to} } @{$r->{recommendations}};
    like($to{101} // '', qr/^n[34]$/, 'must run on: moved into the host group');
    like($to{102} // '', qr/^n[34]$/, '... both VMs');
    is($r->{recommendations}->[0]->{priority}, 1, 'rule fixes are priority 1');
    is($r->{recommendations}->[0]->{reason}, 'Fix VM/Host affinity rule violation', 'vSphere reason');
    is($r->{recommendations}->[0]->{rule}, 'db_on', 'rule named');

    $c->{settings}->{threshold} = 1;
    is(scalar(@{ $pass->($s->snap, $c)->{recommendations} }), 2, 'threshold 1 still fixes must rules');

    $c->{rules}->{db_on}->{mode} = 'must-not';
    $c->{host_groups}->{dbhosts}->{members} = ['n1', 'n2'];
    $r = $pass->($s->snap, $c);
    ok(!grep({ $_->{to} =~ /^n[12]$/ } @{$r->{recommendations}}) && @{$r->{recommendations}} == 2,
        'must not run on: moved out');

    # balancing respects must rules
    my $b = cluster();
    $b->guest(100 + $_, 'n3', cpu => 6) for 1 .. 6;
    my $c2 = cfg(vm_groups => { all => { members => [ 101 .. 106 ] } },
        host_groups => { only3 => { members => ['n3'] } },
        rules => { pin => { type => 'vm-host', vm_group => 'all', host_group => 'only3', mode => 'must' } });
    is_deeply(moves($pass->($b->snap, $c2)), [], 'balancing never breaks a must rule');
}

# ---------------- unfixable violations become faults ----------------
{
    my $s = cluster();
    $s->guest(101, 'n1', cpu => 1, storage => 'local');
    my $c = cfg(vm_groups => { a => { members => [101] } }, host_groups => { h => { members => ['n2'] } },
        rules => { r => { type => 'vm-host', vm_group => 'a', host_group => 'h', mode => 'must' } });
    my $r = $pass->($s->snap, $c);
    is_deeply(moves($r), [], 'unmovable guest: no recommendation');
    like($r->{faults}->[0]->{message}, qr/can't be moved \(scsi0 is on local storage/, 'fault says why');
    is($r->{faults}->[0]->{rule}, 'r', 'fault names the rule');
}

# ---------------- separate (anti-affinity) ----------------
{
    my $s = cluster();
    $s->guest(101, 'n1', cpu => 1, mem => 8);
    $s->guest(102, 'n1', cpu => 1, mem => 16);
    $s->guest(103, 'n1', cpu => 1, mem => 4);
    my $c = cfg(rules => { apart => { type => 'separate', vms => [101, 102, 103] } });
    my $r = $pass->($s->snap, $c);
    my %to = map { $_->{vmid} => $_->{to} } @{$r->{recommendations}};
    ok(!$to{102}, 'the largest VM stays');
    ok($to{101} && $to{103} && $to{101} ne $to{103} && $to{101} ne 'n1' && $to{103} ne 'n1', 'the others go to different nodes');
    is($r->{recommendations}->[0]->{reason}, 'Fix VM anti-affinity rule violation', 'reason');

    # balancing never puts two members together
    my $b = cluster();
    $b->guest(101, 'n1', cpu => 20);
    $b->guest(102, 'n2', cpu => 1);
    $b->guest(103, 'n3', cpu => 1);
    $b->guest(104, 'n4', cpu => 1);
    $b->guest(105, 'n1', cpu => 14);
    my $r2 = $pass->($b->snap, cfg(rules => { apart => { type => 'separate', vms => [101, 102, 103, 104, 105] } }));
    is_deeply(moves($r2), [], 'no balancing move breaks anti-affinity');
    ok(!@{$r2->{faults}} || $r2->{faults}->[0]->{message} =~ /anti-affinity/, 'violation with nowhere to go is a fault');
}

# ---------------- together (affinity) ----------------
{
    my $s = cluster();
    $s->guest(101, 'n1', cpu => 1);
    $s->guest(102, 'n1', cpu => 1);
    $s->guest(103, 'n2', cpu => 1);
    my $c = cfg(rules => { app => { type => 'together', vms => [101, 102, 103] } });
    my $r = $pass->($s->snap, $c);
    is_deeply(moves($r), ['103:n2>n1'], 'together: the stray one joins the majority');
    is($r->{recommendations}->[0]->{reason}, 'Fix VM affinity rule violation', 'reason');

    # balancing moves the group as one
    my $b = cluster();
    $b->guest(100 + $_, 'n1', cpu => 7) for 1 .. 4;  # 28 + 6 = 34 cores on 32
    $b->guest(201, 'n1', cpu => 3);
    $b->guest(202, 'n1', cpu => 3);
    my $r2 = $pass->($b->snap, cfg(rules => { pair => { type => 'together', vms => [201, 202] } }));
    my %to = map { $_->{vmid} => $_->{to} } @{$r2->{recommendations}};
    ok(!exists($to{201}) == !exists($to{202}), 'group members move together or not at all');
    is($to{201}, $to{202}, '... to the same node') if exists $to{201};
}

# ---------------- should rules ----------------
{
    my $s = cluster();
    $s->guest(101, 'n1', cpu => 1);
    my $c = cfg(vm_groups => { a => { members => [101] } }, host_groups => { h => { members => ['n4'] } },
        rules => { pref => { type => 'vm-host', vm_group => 'a', host_group => 'h', mode => 'should' } });
    my $r = $pass->($s->snap, $c);
    is_deeply(moves($r), ['101:n1>n4'], 'should run on: moved');
    is($r->{recommendations}->[0]->{priority}, 2, 'soft rule fixes are priority 2');
    $c->{settings}->{threshold} = 1;
    is_deeply(moves($pass->($s->snap, $c)), [], 'threshold 1 leaves soft rules alone');

    # balancing never moves a guest off its preferred hosts
    my $b = cluster();
    $b->guest(100 + $_, 'n4', cpu => 6) for 1 .. 6;
    my $c2 = cfg(vm_groups => { a => { members => [ 101 .. 106 ] } }, host_groups => { h => { members => ['n4'] } },
        rules => { pref => { type => 'vm-host', vm_group => 'a', host_group => 'h', mode => 'should' } });
    is_deeply(moves($pass->($b->snap, $c2)), [], 'balancing respects should rules');
}

# ---------------- maintenance ----------------
{
    my $s = SnapFixture->new;
    $s->node('n1', cpus => 32, maintenance => 1);
    $s->node($_, cpus => 32) for qw(n2 n3);
    $s->guest(101, 'n1', cpu => 2);
    $s->guest(102, 'n1', cpu => 2);
    $s->guest(103, 'n1', cpu => 2, storage => 'local');
    $s->guest(104, 'n1', cpu => 1);
    $s->guest(105, 'n1', cpu => 1);
    my $r = $pass->($s->snap, cfg(settings => { threshold => 1 }, rules => { pair => { type => 'together', vms => [104, 105] } }));
    my %to = map { $_->{vmid} => $_->{to} } @{$r->{recommendations}};
    ok($to{101} && $to{102} && $to{101} ne 'n1', 'maintenance: guests evacuated, even at threshold 1');
    ok(!$to{103}, 'the guest on local storage stays');
    like(join(' ', map { $_->{message} } @{$r->{faults}}), qr/n1 is entering maintenance mode: 103 can't be moved/,
        'and blocks maintenance (fault)');
    is($to{104}, $to{105}, 'keep-together guests are evacuated to the same node');
    ok(!grep({ $_->{to} eq 'n1' } @{ $pass->($s->snap, cfg(settings => { threshold => 5 }))->{recommendations} }),
        'nothing is moved onto a node in maintenance');
}

# ---------------- native strict HA rules ----------------
{
    my $s = cluster();
    $s->guest(100 + $_, 'n1', cpu => 6, ha => 1) for 1 .. 6;
    my $snap = $s->snap;
    $snap->{ha_rules} = [ { id => 'pin', type => 'node-affinity', resources => [ 101 .. 106 ], nodes => { n1 => 0 }, strict => 1 } ];
    is_deeply(moves($pass->($snap, cfg())), [], 'a strict HA node-affinity rule is honoured');
    $snap->{ha_rules}->[0]->{strict} = 0;
    ok(@{ moves($pass->($snap, cfg())) }, 'a non-strict one is not a hard limit');
}

# ---------------- must_nodes helper ----------------
{
    my $c = cfg(vm_groups => { a => { members => [101] } }, host_groups => { h => { members => ['n2', 'n3'] }, x => { members => ['n3'] } },
        rules => { m => { type => 'vm-host', vm_group => 'a', host_group => 'h', mode => 'must' },
                   n => { type => 'vm-host', vm_group => 'a', host_group => 'x', mode => 'must-not' } });
    is_deeply([ sort keys %{ $C->can('must_nodes')->($c, 101, [qw(n1 n2 n3)]) } ], ['n2'], 'must and must-not combine');
    is($C->can('must_nodes')->($c, 999, [qw(n1 n2)]), undef, 'unrestricted VM');
}

done_testing();
