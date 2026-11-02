use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
use POSIX ();

use StubPVE;
use SnapFixture qw(GiB);
use PVE::WDCBalancer::State;
use PVE::WDCBalancer::Config;
use PVE::WDCBalancer::Collect;

# pmxcfs replaced by a temp directory, the cluster lock by a plain call
my $dir = tempdir(CLEANUP => 1);
$PVE::WDCBalancer::Config::DIR = $dir;
$PVE::WDCBalancer::Config::FILE = "$dir/config.json";
my $node = 'n1';
{
    no warnings qw(redefine once);
    *PVE::Cluster::cfs_lock_domain = sub { my ($d, $t, $code) = @_; my $r = eval { $code->() }; return $r; };
    *PVE::Tools::file_get_contents = sub { open(my $fh, '<', $_[0]) or die "$_[0]: $!"; local $/; return scalar(<$fh>); };
    *PVE::Tools::file_set_contents = sub { open(my $fh, '>', $_[0]) or die "$_[0]: $!"; print $fh $_[1]; close($fh); };
    *PVE::INotify::nodename = sub { return $node; };
}

my $snap;
{
    no warnings qw(redefine once);
    *PVE::WDCBalancer::Collect::snapshot = sub { return $snap; };
}

sub fresh_snap {
    my $s = SnapFixture->new;
    $s->node($_, cpus => 16, mem => 128) for qw(n1 n2 n3);
    $s->guest(100 + $_, 'n1', cpu => 3, mem => 4) for 1 .. 6;
    return $s->snap;
}

# ---------------- a pass ----------------
$snap = fresh_snap();
my $st = PVE::WDCBalancer::State::run_pass(trigger => 'manual: root@pam');
ok(@{$st->{result}->{recommendations}} >= 1, 'pass stored with recommendations');
is($st->{node}, 'n1', 'node recorded');
my $read = PVE::WDCBalancer::State::read_state();
is($read->{result}->{cluster}->{score}, $st->{result}->{cluster}->{score}, 'state.json written');
my $h = PVE::WDCBalancer::State::history();
is($h->[-1]->{type}, 'pass', 'history: pass');
is($h->[-1]->{trigger}, 'manual: root@pam', 'history: trigger');

# ---------------- dismiss ----------------
my $id = $st->{result}->{recommendations}->[0]->{id};
my $rec = PVE::WDCBalancer::State::dismiss($id, 'root@pam');
is($rec->{id}, $id, 'dismissed');
ok(!grep({ $_->{id} eq $id } @{ PVE::WDCBalancer::State::read_state()->{result}->{recommendations} }), 'removed from the list');
is(PVE::WDCBalancer::State::history()->[-1]->{type}, 'dismiss', 'history: dismiss');
ok(!eval { PVE::WDCBalancer::State::dismiss('999:a:b', 'root@pam'); 1 }, 'unknown recommendation refused');
$st = PVE::WDCBalancer::State::run_pass();
ok(!grep({ $_->{id} eq $id } @{$st->{result}->{recommendations}}), 'next pass keeps it dismissed');
ok($st->{dismissed}->{$id}, 'dismissal carried over');

# ---------------- CRS conflict and data warnings ----------------
$snap = fresh_snap();
$snap->{crs}->{auto_rebalance} = 1;
$snap->{warnings} = ['guest 101: no usage samples yet'];
$st = PVE::WDCBalancer::State::run_pass();
is($st->{result}->{faults}->[0]->{type}, 'crs', 'CRS auto-rebalance is a fault');
is($st->{result}->{cluster}->{crs_conflict}, 1, 'and flagged in the summary');
ok(grep({ $_->{type} eq 'data' } @{$st->{result}->{faults}}), 'data warnings are faults');

# ---------------- timer and lease ----------------
$snap = fresh_snap();
PVE::WDCBalancer::State::write_json('lease.json', { node => 'n2', time => time() });
my $t = PVE::WDCBalancer::State::timer_run();
is($t->{leader}, 'n2', 'another node holds a fresh lease');
is($t->{ran}, 0, 'so this node does nothing');
PVE::WDCBalancer::State::write_json('lease.json', { node => 'n2', time => time() - 600 });
$t = PVE::WDCBalancer::State::timer_run();
is($t->{leader}, 'n1', 'a stale lease is taken over');
is($t->{ran}, 0, 'no pass before the interval is up');
my $s = PVE::WDCBalancer::State::read_state();
$s->{time} = time() - 400;
PVE::WDCBalancer::State::write_json('state.json', $s);
$t = PVE::WDCBalancer::State::timer_run();
is($t->{ran}, 1, 'pass when the interval is up');
is(PVE::WDCBalancer::State::history()->[-1]->{trigger}, 'timer', 'timer pass in the history');

# ---------------- limits ----------------
{
    local $PVE::WDCBalancer::State::HISTORY_MAX = 5;
    PVE::WDCBalancer::State::run_pass() for 1 .. 7;
    is(scalar(@{ PVE::WDCBalancer::State::history() }), 5, 'history is capped');
}
{
    local $PVE::WDCBalancer::State::MAX_STATE = 100;
    $st = PVE::WDCBalancer::State::run_pass();
    is_deeply(PVE::WDCBalancer::State::read_state()->{result}->{guests}, {}, 'oversized state drops guest details');
    ok(PVE::WDCBalancer::State::read_state()->{result}->{truncated}, 'and says so');
}

# ---------------- config round trip ----------------
PVE::WDCBalancer::Config::update(sub {
    my ($cfg) = @_;
    $cfg->{settings}->{threshold} = 4;
    $cfg->{vm_groups}->{web} = { members => [101, 102] };
});
is(PVE::WDCBalancer::Config::settings(PVE::WDCBalancer::Config::load())->{threshold}, 4, 'config saved and loaded');
ok(!eval { PVE::WDCBalancer::Config::update(sub { $_[0]->{rules}->{bad} = { type => 'together', vms => [101] }; }); 1 },
    'an invalid config is not saved');
like($@, qr/needs at least two VMs/, 'with the reason');
ok(!PVE::WDCBalancer::Config::load()->{rules}->{bad}, 'and nothing was written');

# ---------------- concurrent writers (passes keep what others wrote) ----------------
{
    no warnings qw(redefine once);
    local *PVE::Cluster::get_members = sub { return {} };
    $snap = fresh_snap();
    my $s0 = PVE::WDCBalancer::State::run_pass();
    my ($r0) = @{$s0->{result}->{recommendations}};
    ok($r0, 'a recommendation to race with');

    # an apply task (another node) started before the pass and runs on
    PVE::WDCBalancer::State::update_state(sub {
        $_[0]->{applying} = { node => 'n2', pid => 1, time => time(), beat => time(), count => 1 };
    });
    # while the pass collects, a move finishes and a recommendation is dismissed
    local *PVE::WDCBalancer::Collect::snapshot = sub {
        PVE::WDCBalancer::State::update_state(sub {
            $_[0]->{moved}->{ $r0->{vmid} } = time();
            $_[0]->{dismissed}->{'999:n1:n2'} = time();
        });
        return fresh_snap();
    };
    PVE::WDCBalancer::State::run_pass();
    my $now = PVE::WDCBalancer::State::read_state();
    is($now->{applying}->{node}, 'n2', 'a pass keeps the running apply task');
    ok(PVE::WDCBalancer::State::apply_running($now), 'and it still counts as running');
    ok($now->{moved}->{ $r0->{vmid} }, 'a pass keeps a move finished while it ran');
    ok($now->{dismissed}->{'999:n1:n2'}, 'and a dismissal made while it ran');
    ok(!grep({ $_->{vmid} == $r0->{vmid} } @{$now->{result}->{recommendations}}),
        'the guest that just moved has no stale recommendation');
}

# ---------------- stale apply markers ----------------
{
    no warnings qw(redefine once);
    my %members = (n1 => { online => 1 }, n2 => { online => 1 });
    local *PVE::Cluster::get_members = sub { return \%members };
    my $run = sub { PVE::WDCBalancer::State::apply_running({ applying => { time => time() - 100, @_ } }) };
    ok($run->(node => 'n2', pid => 1, beat => time()), 'apply task on another node with a fresh heartbeat: running');
    ok(!$run->(node => 'n2', pid => 1, beat => time() - 700), 'heartbeat stopped: not running');
    $members{n2}->{online} = 0;
    ok(!$run->(node => 'n2', pid => 1, beat => time()), 'its node is offline: not running');
    ok($run->(node => 'n1', pid => $$, beat => time()), 'this node, process alive: running');
    my $dead = fork() // die;
    POSIX::_exit(0) if !$dead;
    waitpid($dead, 0);
    ok(!$run->(node => 'n1', pid => $dead, beat => time()), 'this node, process gone: not running');
    ok(!$run->(node => 'n2', pid => 1, time => time() - 5 * 3600, beat => time()), 'older than the apply timeout: not running');
}

# ---------------- circuit breaker ----------------
{
    no warnings qw(redefine once);
    local *PVE::Cluster::get_members = sub { return {} };
    my @sent;
    local *PVE::WDCBalancer::Notify::send = sub { push @sent, [ @_ ] };
    my @result;
    local *PVE::WDCBalancer::Apply::run = sub {
        return [ map { { %$_, finished => time(), duration => 1, %{ shift @result } } } @{$_[0]} ];
    };
    my $rec = sub { return { id => "$_[0]:n1:n2", vmid => $_[0], type => 'qemu', from => 'n1', to => 'n2', reason => 'test' } };
    my $B = sub { PVE::WDCBalancer::State::read_state()->{breaker} };

    my $s = {};
    PVE::WDCBalancer::State::breaker_update($s, [ map { { result => 'failed', message => 'skipped: guest is gone' } } 1 .. 9 ], time());
    ok(!$s->{breaker}, 'skipped moves never trip the breaker');
    PVE::WDCBalancer::State::breaker_update($s, [ { result => 'failed' }, { result => 'failed' }, { result => 'ok' } ], time());
    is($s->{failures}->{streak}, 0, 'a good move ends the streak');
    my $why = PVE::WDCBalancer::State::breaker_update($s, [ map { { result => 'failed' } } 1 .. 3 ], time());
    like($why, qr/3 moves in a row failed/, 'three failures in a row trip it');
    $s = { failures => { streak => 0, times => [ (time() - 7200) x 9 ] } };
    ok(!PVE::WDCBalancer::State::breaker_update($s, [ { result => 'failed' }, { result => 'ok' } ], time()), 'old failures age out');
    $s = { failures => { streak => 0, times => [ (time() - 600) x 4 ] } };
    like(PVE::WDCBalancer::State::breaker_update($s, [ { result => 'failed' }, { result => 'ok' } ], time()),
        qr/5 moves failed within an hour/, 'five failures within an hour trip it');

    PVE::WDCBalancer::State::update_state(sub { delete $_[0]->{applying}; delete $_[0]->{breaker}; $_[0]->{failures} = {}; });
    for my $i (1 .. 3) {
        @result = ({ result => 'failed', message => 'migration task: ERROR' });
        eval { PVE::WDCBalancer::State::apply([ $rec->(100 + $i) ], trigger => 'automation') };
        like($@, qr/move\(s\) failed/, "failed move $i fails the task");
    }
    like($B->()->{reason}, qr/3 moves in a row failed/, 'automation paused after three failed moves');
    ok((grep { $_->[0] eq 'error' && $_->[1] =~ /automation paused/ } @sent), 'and notified');
    ok((grep { $_->{type} eq 'breaker' } @{ PVE::WDCBalancer::State::read_state()->{result}->{faults} }), 'and a fault');
    ok(!eval { PVE::WDCBalancer::State::apply([ $rec->(110) ], trigger => 'automation'); 1 }, 'automation refused while paused');
    like($@, qr/paused by the circuit breaker/, 'with the reason');
    @result = ({ result => 'ok' });
    ok(eval { PVE::WDCBalancer::State::apply([ $rec->(110) ], trigger => 'root@pam'); 1 }, 'a user may still apply');
    $snap = fresh_snap();
    my $p = PVE::WDCBalancer::State::run_pass();
    ok((grep { $_->{type} eq 'breaker' } @{$p->{result}->{faults}}), 'passes keep showing the fault');
    is(PVE::WDCBalancer::State::breaker_reset('root@pam'), 1, 'resume');
    ok(!$B->(), 'automation resumed');
    ok(!grep({ $_->{type} eq 'breaker' } @{ PVE::WDCBalancer::State::read_state()->{result}->{faults} }), 'fault cleared');
    is(PVE::WDCBalancer::State::history()->[-1]->{type}, 'resume', 'resume in the history');
    is(PVE::WDCBalancer::State::breaker_reset('root@pam'), 0, 'resume when not paused: nothing to do');
}

# ---------------- settling after node changes ----------------
{
    no warnings qw(redefine once);
    local *PVE::Cluster::get_members = sub { return {} };
    PVE::WDCBalancer::State::update_state(sub { delete @{$_[0]}{qw(members members_changed moved dismissed)} });
    $snap = fresh_snap();
    my $p = PVE::WDCBalancer::State::run_pass();
    ok(@{$p->{result}->{recommendations}}, 'first pass balances (nothing known to have changed)');
    $snap = fresh_snap();
    $snap->{nodes}->{n3}->{online} = 0;
    $p = PVE::WDCBalancer::State::run_pass();
    like($p->{result}->{cluster}->{hold} // '', qr/online nodes changed; waiting 10 more minute/, 'a node went offline: hold');
    is_deeply($p->{result}->{recommendations}, [], 'no balancing while it settles');
    PVE::WDCBalancer::State::update_state(sub { $_[0]->{members_changed} = time() - 601 });
    $snap = fresh_snap();
    $snap->{nodes}->{n3}->{online} = 0;
    $p = PVE::WDCBalancer::State::run_pass();
    ok(!$p->{result}->{cluster}->{hold}, 'settled after ten minutes');
}

# ---------------- history size ----------------
{
    local $PVE::WDCBalancer::State::MAX_HISTORY = 4096;
    PVE::WDCBalancer::State::locked(sub {
        PVE::WDCBalancer::State::add_history({ time => time(), type => 'move', message => 'x' x 5000, list => [ 1 .. 100 ] }) for 1 .. 20;
        return 1;
    });
    my $h = PVE::WDCBalancer::State::history();
    ok(length(JSON::PP->new->canonical->encode($h)) <= 4096, 'history stays under its byte limit');
    ok(length($h->[-1]->{message}) <= $PVE::WDCBalancer::State::MAX_TEXT + 3, 'long texts are cut');
    is(scalar(@{$h->[-1]->{list}}), 50, 'long lists are shortened');
}

# ---------------- config schema ----------------
{
    my $C = 'PVE::WDCBalancer::Config';
    is($C->can('migrate')->({ settings => {} })->{version}, 1, 'a config without version is schema 1');
    ok(!eval { $C->can('migrate')->({ version => 99 }); 1 }, 'a newer schema is refused');
    like($@, qr/newer pve-wdcbalancer \(schema 99/, 'with the reason');
    ok(!eval { $C->can('migrate')->({ version => 1, rules => [] }); 1 }, 'malformed sections are refused');
    {
        local $PVE::WDCBalancer::Config::SCHEMA = 2;
        local $PVE::WDCBalancer::Config::UPGRADE{1} = sub { $_[0]->{settings}->{upgraded} = 1 };
        my $up = $C->can('migrate')->({ version => 1, settings => {} });
        is($up->{version}, 2, 'upgrades run in order');
        ok($up->{settings}->{upgraded}, 'and change the config');
    }
    # a node that can't read the config doesn't take the lease
    open(my $fh, '>', $PVE::WDCBalancer::Config::FILE) or die;
    print $fh '{"version": 99}';
    close($fh);
    PVE::WDCBalancer::State::write_json('lease.json', { node => 'n2', time => time() - 600 });
    ok(!eval { PVE::WDCBalancer::State::timer_run(); 1 }, 'timer refuses a newer config');
    is(PVE::WDCBalancer::State::read_json('lease.json')->{node}, 'n2', 'and leaves the lease to the upgraded nodes');
    unlink($PVE::WDCBalancer::Config::FILE);
}

done_testing();
