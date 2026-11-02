use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);

use StubPVE;
use SnapFixture qw(GiB);
use PVE::WDCBalancer::Apply;
use PVE::WDCBalancer::HARules;
use PVE::WDCBalancer::Notify;
use PVE::WDCBalancer::State;
use PVE::WDCBalancer::Config;
use PVE::WDCBalancer::Collect;

my $A = 'PVE::WDCBalancer::Apply';

sub rec {
    my ($vmid, $from, $to, %o) = @_;
    return { id => "$vmid:$from:$to", vmid => $vmid, from => $from, to => $to, type => $o{type} // 'qemu',
        ha => $o{ha} // 0, restart => ($o{type} // '') eq 'lxc' ? 1 : 0, reason => 'test', priority => $o{priority} // 3 };
}

# ---------------- what automation may apply ----------------
{
    my $cfg = { settings => { automation => 'full' }, overrides => { 102 => { automation => 'manual' }, 103 => { automation => 'disabled' } } };
    my @recs = (rec(101, 'a', 'b'), rec(102, 'a', 'b'), rec(103, 'a', 'b'), rec(104, 'a', 'b', type => 'lxc'));
    is_deeply([ map { $_->{vmid} } @{ $A->can('automatic')->($cfg, \@recs) } ], [101], 'full: overrides and containers held back');
    $cfg->{settings}->{containers} = 'restart';
    is_deeply([ map { $_->{vmid} } @{ $A->can('automatic')->($cfg, \@recs) } ], [101, 104], 'containers with containers=restart');
    $cfg->{settings}->{automation} = 'manual';
    $cfg->{overrides}->{105} = { automation => 'full' };
    is_deeply([ map { $_->{vmid} } @{ $A->can('automatic')->($cfg, [ @recs, rec(105, 'a', 'c') ]) } ], [105],
        'manual cluster: only VMs overridden to full');
    $cfg->{settings}->{automation} = 'partial';
    is_deeply($A->can('automatic')->($cfg, [ rec(101, 'a', 'b') ]), [], 'partial: no automatic balancing');
}

# ---------------- concurrency ----------------
{
    my @p = (rec(1, 'a', 'b'), rec(2, 'a', 'c'), rec(3, 'a', 'd'), rec(4, 'c', 'd'), rec(5, 'e', 'f'));
    my $b = $A->can('next_batch')->(\@p, [], 2);
    is_deeply([ map { $_->{vmid} } @$b ], [1, 2, 4, 5], 'two per node: a busy with 1 and 2, then c and d');
    $b = $A->can('next_batch')->(\@p, [ rec(9, 'a', 'x') ], 1);
    is_deeply([ map { $_->{vmid} } @$b ], [4, 5], 'running moves count');
    $b = $A->can('next_batch')->([ rec(1, 'a', 'b'), rec(1, 'b', 'c') ], [], 2);
    is(scalar(@$b), 1, 'one move per guest at a time');
}

# ---------------- commands ----------------
is_deeply($A->can('command')->(rec(101, 'a', 'b')),
    [ 'pvesh', 'create', '/nodes/a/qemu/101/migrate', '--target', 'b', '--online', '1', '--output-format', 'json' ], 'VM: online migration');
is_deeply($A->can('command')->(rec(200, 'a', 'b', type => 'lxc')),
    [ 'pvesh', 'create', '/nodes/a/lxc/200/migrate', '--target', 'b', '--restart', '1', '--output-format', 'json' ], 'container: restart migration');
is_deeply($A->can('command')->(rec(101, 'a', 'b', ha => 1)), [ 'ha-manager', 'crm-command', 'migrate', 'vm:101', 'b' ], 'HA VM');
is_deeply($A->can('command')->(rec(200, 'a', 'b', ha => 1, type => 'lxc')), [ 'ha-manager', 'crm-command', 'migrate', 'ct:200', 'b' ], 'HA container');

# ---------------- run (moves faked) ----------------
SKIP: {
    skip 'no fork', 8 if $^O eq 'MSWin32';
    no warnings qw(redefine once);
    my %at = (101 => 'a', 102 => 'a', 103 => 'a', 104 => 'a');
    my %lock = (103 => 'backup');
    local *PVE::WDCBalancer::Apply::guest_location = sub { return $at{$_[0]}; };
    local *PVE::WDCBalancer::Apply::guest_lock = sub { return $lock{$_[0]}; };
    local *PVE::WDCBalancer::Apply::online_nodes = sub { return { a => 1, b => 1 } };
    local *PVE::WDCBalancer::Apply::task_status = sub { return { status => 'stopped', exitstatus => 'migration aborted' } };
    # the "migration": 'true' succeeds, and the guest arrives; 'false' fails
    local *PVE::WDCBalancer::Apply::command = sub {
        my ($r) = @_;
        if ($r->{vmid} == 101) { $at{101} = 'b'; return ['true']; }
        return ['false'] if $r->{vmid} == 102;
        return ['sh', '-c', 'echo \'"UPID:a:1:"\'']; # 104: pvesh returns the task, which fails later
    };
    local $PVE::WDCBalancer::Apply::POLL = 0.05;
    my @log;
    my $res = $A->can('run')->([ rec(101, 'a', 'b'), rec(102, 'a', 'b'), rec(103, 'a', 'b'), rec(104, 'a', 'b'), rec(105, 'x', 'b') ],
        limit => 4, log => sub { push @log, $_[0] });
    my %r = map { $_->{vmid} => $_ } @$res;
    is($r{101}->{result}, 'ok', 'moved guest: ok');
    is($r{102}->{result}, 'failed', 'failed command: failed');
    like($r{103}->{message}, qr/skipped: guest is locked \(backup\)/, 'locked guest skipped');
    like($r{104}->{message}, qr/migration task: migration aborted/, 'task failure reported');
    like($r{105}->{message}, qr/skipped: guest is gone/, 'vanished guest skipped');
    ok(!exists($r{101}->{pid}) && !exists($r{101}->{out}), 'no internals in results');
    ok((grep { /^OK +qemu 101: a -> b/ } @log), 'task log line for a move');
    is(scalar(@$res), 5, 'every recommendation has a result');
}

# ---------------- HA rule mirroring ----------------
{
    my $H = 'PVE::WDCBalancer::HARules';
    my $sids = $H->can('parse_ha_resources')->("vm: 101\n\tstate started\nct: 200\nvm: 102\n");
    is_deeply($sids, { 101 => 'vm:101', 200 => 'ct:200', 102 => 'vm:102' }, 'HA resources parsed');
    my $cfg = {
        settings => {},
        vm_groups => { db => { members => [101, 103] }, none => { members => [104] } },
        host_groups => { h => { members => ['n2', 'n1'] } },
        rules => {
            pin => { type => 'vm-host', vm_group => 'db', host_group => 'h', mode => 'must' },
            soft => { type => 'vm-host', vm_group => 'db', host_group => 'h', mode => 'should-not' },
            nonha => { type => 'vm-host', vm_group => 'none', host_group => 'h', mode => 'must' },
            apart => { type => 'separate', vms => [101, 102, 103] },
            pair => { type => 'together', vms => [101, 104] },
            off => { type => 'separate', vms => [101, 102], enabled => 0 },
        },
    };
    my $want = $H->can('desired')->($cfg, $sids);
    is_deeply([ sort keys %$want ], [qw(wdcb-apart wdcb-pin wdcb-soft)], 'only rules with HA guests (two for VM-VM), enabled');
    is_deeply($want->{'wdcb-pin'}, { type => 'node-affinity', resources => 'vm:101', nodes => 'n1,n2', affinity => 'positive', strict => 1 }, 'must');
    is_deeply($want->{'wdcb-soft'}, { type => 'node-affinity', resources => 'vm:101', nodes => 'n1,n2', affinity => 'negative', strict => 0 }, 'should not');
    is_deeply($want->{'wdcb-apart'}, { type => 'resource-affinity', resources => 'vm:101,vm:102', affinity => 'negative' }, 'separate');

    my $have = $H->can('parse_rules')->(<<"EOF");
node-affinity: wdcb-pin
	nodes n2,n1
	resources vm:101
	strict 1
	comment $PVE::WDCBalancer::HARules::MARK

node-affinity: wdcb-soft
	nodes n1,n2
	resources vm:101
	affinity positive
	comment $PVE::WDCBalancer::HARules::MARK

resource-affinity: wdcb-old
	affinity positive
	resources vm:101,vm:102
	comment $PVE::WDCBalancer::HARules::MARK

resource-affinity: wdcb-apart
	affinity negative
	resources vm:101,vm:102
	comment made by hand

node-affinity: mine
	nodes n1
	resources vm:101
EOF
    my $ops = $H->can('plan')->($want, $have);
    my @s = map { "$_->[0] $_->[1]" } @$ops;
    is_deeply(\@s, ['conflict wdcb-apart', 'update wdcb-soft', 'delete wdcb-old'],
        'unchanged rule kept, changed one updated, stale one deleted, hand-made ones untouched')
        or diag explain \@s;
    is($H->can('rule_id')->('x' x 80), 'wdcb-' . ('x' x 58), 'rule IDs are bounded');
}

# ---------------- new faults ----------------
{
    my $n = PVE::WDCBalancer::Notify->can('new_faults')->(
        [ { type => 'rule', message => 'a' } ],
        [ { type => 'rule', message => 'a' }, { type => 'rule', message => 'b' }, { type => 'data', message => 'c' } ]);
    is_deeply([ map { $_->{message} } @$n ], ['b'], 'only new faults, data warnings excluded');
}

# ---------------- apply and the timer (state on a temp dir) ----------------
SKIP: {
    skip 'no fork', 11 if $^O eq 'MSWin32';
    my $dir = tempdir(CLEANUP => 1);
    $PVE::WDCBalancer::Config::DIR = $dir;
    $PVE::WDCBalancer::Config::FILE = "$dir/config.json";
    no warnings qw(redefine once);
    local *PVE::Cluster::cfs_lock_domain = sub { my ($d, $t, $code) = @_; my $r = eval { $code->() }; return $r; };
    local *PVE::Tools::file_get_contents = sub { open(my $fh, '<', $_[0]) or die "$_[0]: $!"; local $/; return scalar(<$fh>); };
    local *PVE::Tools::file_set_contents = sub { open(my $fh, '>', $_[0]) or die "$_[0]: $!"; print $fh $_[1]; close($fh); };
    local *PVE::INotify::nodename = sub { 'n1' };
    my $s = SnapFixture->new;
    $s->node($_, cpus => 16, mem => 128) for qw(n1 n2 n3);
    $s->guest(100 + $_, 'n1', cpu => 3, mem => 4) for 1 .. 6;
    my $snap = $s->snap;
    local *PVE::WDCBalancer::Collect::snapshot = sub { return $snap; };
    local *PVE::WDCBalancer::HARules::sync = sub { return { changes => [], errors => [] } };
    my @sent;
    local *PVE::WDCBalancer::Notify::send = sub { push @sent, [ @_ ] };
    my @ran;
    local *PVE::WDCBalancer::Apply::run = sub {
        my ($recs) = @_;
        push @ran, map { $_->{vmid} } @$recs;
        return [ map { { %$_, result => $_->{vmid} == 102 ? 'failed' : 'ok', finished => time(), duration => 1 } } @$recs ];
    };
    my @workers;
    local *PVE::RPCEnvironment::get = sub { return bless {}, 'FakeRPC' };
    local *FakeRPC::fork_worker = sub { my ($self, $type, $id, $user, $code) = @_; push @workers, $type; eval { $code->() }; return 'UPID:x'; };

    # manual automation: the timer only recommends
    my $t = PVE::WDCBalancer::State::timer_run();
    is($t->{ran}, 1, 'timer pass');
    is($t->{applied}, 0, 'manual: nothing applied');
    is_deeply(\@ran, [], 'no moves');

    # full automation
    PVE::WDCBalancer::Config::update(sub { $_[0]->{settings}->{automation} = 'full' });
    my $st = PVE::WDCBalancer::State::read_state();
    $st->{time} = 0;
    PVE::WDCBalancer::State::write_json('state.json', $st);
    $t = PVE::WDCBalancer::State::timer_run();
    ok($t->{applied} > 0, 'full: recommendations applied');
    is_deeply(\@workers, ['wdcbapply'], 'in a wdcbapply task');
    $st = PVE::WDCBalancer::State::read_state();
    ok($st->{moved}->{$ran[0]}, 'moved guest starts its cooldown') if $ran[0] != 102;
    ok(!$st->{applying}, 'apply marker cleared');
    my @moves = grep { $_->{type} eq 'move' } @{ PVE::WDCBalancer::State::history() };
    is(scalar(@moves), scalar(@ran), 'every move in the history');
    ok(@sent && $sent[-1]->[1] =~ /guest\(s\) moved/, 'automatic moves are notified');

    # CRS conflict: no automatic moves
    @ran = ();
    $snap->{crs}->{auto_rebalance} = 1;
    $st->{time} = 0;
    PVE::WDCBalancer::State::write_json('state.json', $st);
    $t = PVE::WDCBalancer::State::timer_run();
    is($t->{applied}, 0, 'no automatic moves while CRS auto-rebalance is on');
    ok((grep { $_->[1] =~ /new fault/ } @sent), 'the CRS conflict is notified as a new fault');
}

done_testing();
