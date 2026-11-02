use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);

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

done_testing();
