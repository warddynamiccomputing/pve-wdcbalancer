use strict;
use warnings;

use Test::More;

use StubPVE;
use PVE::WDCBalancer::Operations;
use PVE::WDCBalancer::Config;
use PVE::WDCBalancer::State;
use PVE::WDCBalancer::Apply;

no warnings qw(redefine once);

my $cfg = PVE::WDCBalancer::Config::empty();
*PVE::WDCBalancer::Config::update = sub { my ($code) = @_; return $code->($cfg); };
*PVE::WDCBalancer::Config::load = sub { return $cfg; };
*PVE::WDCBalancer::State::locked = sub { return $_[0]->(); };
my @history;
*PVE::WDCBalancer::State::add_history = sub { push @history, @_; };
*PVE::WDCBalancer::State::read_state = sub { return { result => { guests => { 103 => { reason => 'scsi0 is on local storage' } } } } };
*PVE::Cluster::get_members = sub { return { n1 => { online => 1 }, n2 => { online => 1 } } };
*PVE::Cluster::cfs_update = sub {};
$PVE::WDCBalancer::Operations::POLL = 0;

my @cmds;
*PVE::WDCBalancer::Operations::cmd = sub { push @cmds, join(' ', @_); return 1; };

# guests on n1: 101 HA (HA moves it when its maintenance is on), 102 movable,
# 103 on local storage, 104 stopped
my %g = (
    101 => { vmid => 101, node => 'n1', status => 'running', ha => 1, type => 'qemu' },
    102 => { vmid => 102, node => 'n1', status => 'running', ha => 0, type => 'qemu' },
    103 => { vmid => 103, node => 'n1', status => 'running', ha => 0, type => 'qemu' },
    104 => { vmid => 104, node => 'n1', status => 'stopped', ha => 0, type => 'qemu' },
);
*PVE::WDCBalancer::Operations::guests_on = sub {
    my ($node) = @_;
    return [ map { $g{$_} } grep { $g{$_}->{node} eq $node } sort keys %g ];
};
my $passes = 0;
*PVE::WDCBalancer::State::run_pass = sub {
    $passes++;
    my @recs = map { { id => "$_->{vmid}:n1:n2", vmid => $_->{vmid}, from => 'n1', to => 'n2', kind => 'maintenance',
        ha => $_->{ha}, type => 'qemu' } } grep { $_->{status} eq 'running' } @{ PVE::WDCBalancer::Operations::guests_on('n1') };
    return { result => { recommendations => \@recs } };
};
my @applied;
*PVE::WDCBalancer::State::apply = sub {
    my ($recs) = @_;
    for my $r (@$recs) {
        push @applied, $r->{vmid};
        $g{$r->{vmid}}->{node} = $r->{to} if $r->{vmid} != 103;
    }
    die "1 of " . scalar(@$recs) . " move(s) failed\n" if grep { $_->{vmid} == 103 } @$recs;
    return [];
};
*PVE::WDCBalancer::Collect::snapshot = sub { return { nodes => { n1 => {}, n2 => {} }, guests => {} } };
*PVE::WDCBalancer::Engine::place = sub {
    my ($snap, $c, $ids) = @_;
    ok($snap->{nodes}->{n1}->{maintenance}, 'stopped guests are never placed on the node itself');
    return [ map { { vmid => $_, type => 'qemu', from => 'n1', to => 'n2' } } @$ids ];
};

# HA guest 101 leaves once HA node maintenance is on
my $ha_on = 0;
my $orig_cmd = \&PVE::WDCBalancer::Operations::cmd;
*PVE::WDCBalancer::Operations::cmd = sub {
    $orig_cmd->(@_);
    $g{101}->{node} = 'n2' if "@_" =~ /node-maintenance enable n1/;
};

my @log;
ok(!eval { PVE::WDCBalancer::Operations::enter_maintenance('n1', user => 'root@pam', move_stopped => 1, log => sub { push @log, $_[0] }); 1 },
    'entering fails when a running guest stays');
like($@, qr/1 running guest\(s\) remain on n1/, 'and says how many');
ok($cfg->{maintenance}->{n1}, 'the node is in maintenance mode anyway');
is($cfg->{maintenance}->{n1}->{ha}, 1, 'HA node maintenance recorded');
ok((grep { $_ eq 'ha-manager crm-command node-maintenance enable n1' } @cmds), 'HA node maintenance turned on');
ok(!grep({ $_ == 101 } @applied), 'HA guests are not moved by us');
is($g{102}->{node}, 'n2', 'the movable guest was moved');
is((grep { $_ == 103 } @applied), 1, 'the blocked guest was tried once');
is($g{104}->{node}, 'n2', 'the stopped guest was moved too');
ok((grep { /103 \(scsi0 is on local storage\)/ } @log), 'the blocked guest is reported with its reason');
ok((grep { $_->{type} eq 'maintenance' && $_->{action} eq 'enter' } @history), 'history: enter');

@cmds = ();
PVE::WDCBalancer::Operations::exit_maintenance('n1', user => 'root@pam');
ok(!$cfg->{maintenance}->{n1}, 'exit: mark removed');
is_deeply(\@cmds, ['ha-manager crm-command node-maintenance disable n1'], 'exit: HA node maintenance turned off');
ok(!eval { PVE::WDCBalancer::Operations::exit_maintenance('n1'); 1 }, 'exit twice is refused');
ok(!eval { PVE::WDCBalancer::Operations::enter_maintenance('nx'); 1 }, 'unknown node refused');

# ---------------- Power On (balanced) ----------------
my @moves;
*PVE::WDCBalancer::Apply::run = sub {
    my ($recs) = @_;
    push @moves, map { "$_->{vmid}:$_->{from}>$_->{to}" . ($_->{offline} ? ' offline' : '') } @$recs;
    return [ map { { %$_, result => 'ok' } } @$recs ];
};
*PVE::WDCBalancer::Operations::placement = sub {
    return [
        { vmid => 201, type => 'qemu', from => 'n1', to => 'n2', score => 100,
            ranking => [ { node => 'n1', ok => 1, score => 90 }, { node => 'n2', ok => 1, score => 100 }, { node => 'n3', ok => 0, reason => 'offline' } ] },
        { vmid => 202, type => 'lxc', from => 'n1', to => 'n1', score => 100, ranking => [] },
        { vmid => 203, type => 'qemu', ha => 1, from => 'n1', to => 'n2', score => 100, ranking => [] },
        { vmid => 204, reason => 'already running' },
    ];
};
@cmds = ();
PVE::WDCBalancer::Operations::power_on([201, 202, 203, 204], user => 'root@pam', log => sub {});
is_deeply(\@moves, ['201:n1>n2 offline'], 'moved offline to its best node first');
is_deeply(\@cmds, [
    'pvesh create /nodes/n2/qemu/201/status/start',
    'pvesh create /nodes/n1/lxc/202/status/start',
    'ha-manager set vm:203 --state started',
], 'started there; HA guests started through HA; running guests left alone');
ok((grep { $_->{type} eq 'poweron' && $_->{vmid} == 201 && $_->{result} eq 'ok' } @history), 'history: power on');

*PVE::WDCBalancer::Operations::placement = sub {
    return [ { vmid => 201, type => 'qemu', from => 'n1', to => 'n2', score => 100,
        ranking => [ { node => 'n1', ok => 1, score => 90 }, { node => 'n3', ok => 0, reason => 'n3 is offline' } ] } ];
};
@moves = (); @cmds = ();
PVE::WDCBalancer::Operations::power_on([201], target => 'n1', log => sub {});
is_deeply([ \@moves, \@cmds ], [ [], ['pvesh create /nodes/n1/qemu/201/status/start'] ], 'a chosen node is used');
ok(!eval { PVE::WDCBalancer::Operations::power_on([201], target => 'n3', log => sub {}); 1 }, 'a node it may not run on is refused');
like($@, qr/can't run on n3: n3 is offline/, 'with the reason');

done_testing();
