use strict;
use warnings;

use Test::More;

use StubPVE;
use SnapFixture qw(GiB);
use PVE::WDCBalancer::Engine;
use PVE::WDCBalancer::Apply;

my $place = PVE::WDCBalancer::Engine->can('place');

sub cfg {
    my (%o) = @_;
    return { version => 1, settings => $o{settings} // {}, vm_groups => $o{vm_groups} // {},
        host_groups => $o{host_groups} // {}, rules => $o{rules} // {}, overrides => {}, maintenance => {} };
}

sub cluster {
    my $s = SnapFixture->new;
    $s->node($_, cpus => 16, mem => 128) for qw(n1 n2 n3);
    return $s;
}

# ---------------- initial placement ----------------
{
    my $s = cluster();
    $s->guest(100 + $_, 'n1', cpu => 3, mem => 8) for 1 .. 4;  # n1 busy
    $s->guest(201, 'n1', status => 'stopped', vcpus => 4, maxmem => 16, mem => 0, cpu => 0);
    my $p = $place->($s->snap, cfg(), [201]);
    isnt($p->[0]->{to}, 'n1', 'a stopped guest is placed off the busy node');
    is($p->[0]->{from}, 'n1', 'from its current node');
    is(scalar(@{$p->[0]->{ranking}}), 3, 'a ranking row per node');

    # several guests at once spread out
    my $s2 = cluster();
    $s2->guest(200 + $_, 'n1', status => 'stopped', vcpus => 16, maxmem => 32, mem => 0, cpu => 0) for 1 .. 3;
    my $p2 = $place->($s2->snap, cfg(), [201, 202, 203]);
    my %to = map { $_->{to} => 1 } @$p2;
    is(scalar(keys %to), 3, 'guests placed one after the other spread over the nodes');

    # running guests are left alone
    my $p3 = $place->($s->snap, cfg(), [101]);
    is($p3->[0]->{reason}, 'already running', 'running guest not placed');
}

# ---------------- placement honours constraints and rules ----------------
{
    my $s = cluster();
    $s->guest(201, 'n1', status => 'stopped', storage => 'local', maxmem => 8, mem => 0, cpu => 0);
    $s->guest(101, 'n1', cpu => 12, mem => 8);
    my $p = $place->($s->snap, cfg(), [201]);
    is($p->[0]->{to}, 'n1', 'a guest on local storage starts where its disk is');
    like((grep { $_->{node} eq 'n2' } @{$p->[0]->{ranking}})[0]->{reason}, qr/local storage/, 'and the others say why');

    my $s2 = cluster();
    $s2->guest(101, 'n2', cpu => 1);
    $s2->guest(201, 'n1', status => 'stopped', maxmem => 8, mem => 0, cpu => 0);
    my $c = cfg(rules => { apart => { type => 'separate', vms => [101, 201] } });
    my $p2 = $place->($s2->snap, $c, [201]);
    isnt($p2->[0]->{to}, 'n2', 'anti-affinity with a running guest');

    $c = cfg(rules => { pair => { type => 'together', vms => [101, 201] } });
    is($place->($s2->snap, $c, [201])->[0]->{to}, 'n2', 'affinity: placed with its running partner');

    $c = cfg(vm_groups => { g => { members => [201] } }, host_groups => { h => { members => ['n3'] } },
        rules => { m => { type => 'vm-host', vm_group => 'g', host_group => 'h', mode => 'must' } });
    is($place->($s2->snap, $c, [201])->[0]->{to}, 'n3', 'must run on');

    $c->{rules}->{m}->{mode} = 'should';
    is($place->($s2->snap, $c, [201])->[0]->{to}, 'n3', 'should run on is preferred');

    my $s3 = SnapFixture->new;
    $s3->node('n1', cpus => 16, mem => 32);
    $s3->node('n2', cpus => 16, mem => 32, maintenance => 1);
    $s3->guest(201, 'n1', status => 'stopped', maxmem => 64, mem => 0, cpu => 0);
    my $p3 = $place->($s3->snap, cfg(), [201]);
    ok(!$p3->[0]->{to}, 'no node with memory for it: not placed');
    like((grep { $_->{node} eq 'n2' } @{$p3->[0]->{ranking}})[0]->{reason}, qr/maintenance/, 'maintenance node refused');
}

# ---------------- maintenance moves in a pass ----------------
{
    my $s = SnapFixture->new;
    $s->node('n1', cpus => 32, maintenance => 1);
    $s->node($_, cpus => 32) for qw(n2 n3);
    $s->guest(101, 'n1', cpu => 2, ha => 1);
    $s->guest(102, 'n1', cpu => 2);
    my $r = PVE::WDCBalancer::Engine::pass($s->snap, cfg(settings => { threshold => 1 }));
    my %rec = map { $_->{vmid} => $_ } @{$r->{recommendations}};
    is($rec{102}->{kind}, 'maintenance', 'maintenance recommendation');
    is($rec{101}->{ha}, 1, 'HA guests are marked (the HA manager moves them)');
}

# ---------------- offline moves ----------------
is_deeply(PVE::WDCBalancer::Apply->can('command')->({ vmid => 201, type => 'qemu', from => 'a', to => 'b', offline => 1 }),
    [ 'pvesh', 'create', '/nodes/a/qemu/201/migrate', '--target', 'b', '--output-format', 'json' ], 'stopped VM: offline migration');
is_deeply(PVE::WDCBalancer::Apply->can('command')->({ vmid => 300, type => 'lxc', from => 'a', to => 'b', offline => 1 }),
    [ 'pvesh', 'create', '/nodes/a/lxc/300/migrate', '--target', 'b', '--output-format', 'json' ], 'stopped container: offline migration');

done_testing();
