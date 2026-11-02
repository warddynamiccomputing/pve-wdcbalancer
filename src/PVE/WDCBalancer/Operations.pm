package PVE::WDCBalancer::Operations;

# Maintenance mode and Power On (balanced), each run as a task.
#
# Maintenance mode (vSphere: Enter Maintenance Mode):
#   - the node is marked in the config, so no pass places anything there
#     and every pass recommends moving its running guests (priority 1);
#   - HA guests: the HA manager's own node maintenance is turned on, so HA
#     moves them and doesn't bring them back;
#   - the other running guests are moved now (an explicit request, whatever
#     the automation level), round after round until nothing more can move;
#   - optionally the stopped guests are moved too (offline: on shared
#     storage only the config moves);
#   - what is left (local disks, passthrough, ...) is reported.
# Exit maintenance mode: the mark (and HA node maintenance, if we turned it
# on) is removed; later passes rebalance onto the node.
#
# Power On (balanced) (vSphere: power on with DRS initial placement): each
# stopped guest is started on the best node (Engine::place), moved there
# offline first if needed. HA guests are started through HA, whose CRS
# places them.

use strict;
use warnings;

use JSON::PP;

use PVE::Cluster;
use PVE::INotify;
use PVE::Tools;

use PVE::WDCBalancer::Apply;
use PVE::WDCBalancer::Collect;
use PVE::WDCBalancer::Config;
use PVE::WDCBalancer::Engine;
use PVE::WDCBalancer::State;

our $ROUNDS = 5;
our $HA_WAIT = 3600;
our $POLL = 5;

my $json = JSON::PP->new->allow_nonref;

sub cmd {
    my (@cmd) = @_;
    my $err = '';
    PVE::Tools::run_command(\@cmd, outfunc => sub {}, errfunc => sub { $err .= "$_[0]\n" }, timeout => 600);
    return 1;
}

sub guests_on {
    my ($node) = @_;
    PVE::Cluster::cfs_update();
    my $snap = PVE::WDCBalancer::Collect::snapshot(config => PVE::WDCBalancer::Config::load());
    return [ map { $snap->{guests}->{$_} } grep { ($snap->{guests}->{$_}->{node} // '') eq $node }
        sort { $a <=> $b } keys %{$snap->{guests}} ];
}

# ---------------- maintenance mode ----------------

sub enter_maintenance {
    my ($node, %o) = @_;
    my $user = $o{user} // 'root@pam';
    my $log = $o{log} // sub { print "$_[0]\n" };

    my $members = PVE::Cluster::get_members() // {};
    die "node '$node' is not a cluster member\n" if %$members && !$members->{$node};

    my @ha = grep { $_->{ha} } @{ guests_on($node) };
    PVE::WDCBalancer::Config::update(sub {
        my ($cfg) = @_;
        $cfg->{maintenance}->{$node} = { since => time(), user => $user, move_stopped => $o{move_stopped} ? 1 : 0,
            ha => @ha ? 1 : 0 };
    });
    PVE::WDCBalancer::State::locked(sub {
        PVE::WDCBalancer::State::add_history({ time => time(), type => 'maintenance', node => $node, user => $user,
            action => 'enter' });
        return 1;
    });
    $log->("$node: maintenance mode on; no guests will be placed there");

    if (@ha) {
        $log->("$node: HA node maintenance on for " . scalar(@ha) . " HA guest(s)");
        cmd('ha-manager', 'crm-command', 'node-maintenance', 'enable', $node);
    }

    # move the running guests, round after round
    my %tried;
    for my $round (1 .. $ROUNDS) {
        my $state = PVE::WDCBalancer::State::run_pass(trigger => "maintenance $node: $user");
        my @recs = grep { $_->{kind} eq 'maintenance' && $_->{from} eq $node && !$_->{ha} && !$tried{"$_->{vmid}:$_->{to}"} }
            @{$state->{result}->{recommendations}};
        last if !@recs;
        $log->("round $round: moving " . scalar(@recs) . " guest(s)");
        eval { PVE::WDCBalancer::State::apply(\@recs, trigger => "maintenance: $user") };
        if ($@ && $@ =~ /another apply task is running/) {
            $log->("  waiting for the running apply task");
            sleep($POLL * 6);
            next;
        }
        $log->("  $@") if $@;
        $tried{"$_->{vmid}:$_->{to}"} = 1 for @recs;
    }

    # HA guests are moved by the HA manager
    if (@ha) {
        my $deadline = time() + $HA_WAIT;
        while (time() < $deadline) {
            my @left = grep { $_->{ha} && $_->{status} eq 'running' } @{ guests_on($node) };
            last if !@left;
            $log->("waiting for HA to move " . join(', ', map { $_->{vmid} } @left));
            sleep($POLL * 6);
        }
    }

    if ($o{move_stopped}) {
        my @stopped = grep { $_->{status} ne 'running' && !$_->{template} && !$_->{ha} } @{ guests_on($node) };
        if (@stopped) {
            my $cfg = PVE::WDCBalancer::Config::load();
            my $snap = PVE::WDCBalancer::Collect::snapshot(config => $cfg);
            # place them as if powered on, but never on this node
            $snap->{nodes}->{$node}->{maintenance} = 1;
            my $plan = PVE::WDCBalancer::Engine::place($snap, $cfg, [ map { $_->{vmid} } @stopped ]);
            my @moves = map { +{ id => "$_->{vmid}:$_->{from}:$_->{to}", vmid => $_->{vmid}, type => $_->{type},
                from => $_->{from}, to => $_->{to}, offline => 1, reason => "Host $node is entering maintenance mode",
                priority => 1, kind => 'maintenance' } }
                grep { $_->{to} && $_->{to} ne $node } @$plan;
            $log->("moving " . scalar(@moves) . " stopped guest(s)") if @moves;
            eval { PVE::WDCBalancer::State::apply(\@moves, trigger => "maintenance: $user") } if @moves;
            $log->("  $@") if $@;
        }
    }

    my $left = maintenance_status($node);
    if ($left->{running}) {
        $log->("$node: in maintenance mode, but " . scalar(@{$left->{blocked}}) . " running guest(s) can't be moved:");
        $log->("  $_->{vmid} ($_->{reason})") for @{$left->{blocked}};
        die "maintenance mode on, $left->{running} running guest(s) remain on $node\n";
    }
    $log->("$node: in maintenance mode, no running guests left" .
        ($left->{stopped} ? " ($left->{stopped} stopped guest(s) remain)" : ''));
    return $left;
}

sub exit_maintenance {
    my ($node, %o) = @_;
    my $user = $o{user} // 'root@pam';
    my $was = PVE::WDCBalancer::Config::update(sub {
        my ($cfg) = @_;
        return delete($cfg->{maintenance}->{$node}) // die "node '$node' is not in maintenance mode\n";
    });
    cmd('ha-manager', 'crm-command', 'node-maintenance', 'disable', $node) if $was->{ha};
    PVE::WDCBalancer::State::locked(sub {
        PVE::WDCBalancer::State::add_history({ time => time(), type => 'maintenance', node => $node, user => $user,
            action => 'exit' });
        return 1;
    });
    return $was;
}

# What keeps a node from being empty, from the last pass.
sub maintenance_status {
    my ($node) = @_;
    my $cfg = PVE::WDCBalancer::Config::load();
    my $m = $cfg->{maintenance}->{$node};
    my $guests = guests_on($node);
    my @running = grep { $_->{status} eq 'running' } @$guests;
    my @blocked;
    for my $g (@running) {
        my $res = PVE::WDCBalancer::State::read_state()->{result}->{guests}->{$g->{vmid}} // {};
        push @blocked, { vmid => $g->{vmid}, name => $g->{name}, reason => $res->{reason} // ($g->{ha} ? 'HA guest, moved by HA' : 'not moved yet') };
    }
    return {
        node => $node,
        maintenance => $m ? 1 : 0,
        $m ? (since => $m->{since}, user => $m->{user}, ha => $m->{ha} ? 1 : 0) : (),
        running => scalar(@running),
        stopped => scalar(grep { $_->{status} ne 'running' && !$_->{template} } @$guests),
        blocked => \@blocked,
        state => !$m ? 'online' : @running ? 'entering maintenance' : 'in maintenance',
    };
}

# ---------------- Power On (balanced) ----------------

# Placement for stopped guests, without doing anything.
sub placement {
    my ($vmids) = @_;
    my $cfg = PVE::WDCBalancer::Config::load();
    my $snap = PVE::WDCBalancer::Collect::snapshot(config => $cfg);
    return PVE::WDCBalancer::Engine::place($snap, $cfg, $vmids);
}

sub power_on {
    my ($vmids, %o) = @_;
    my $user = $o{user} // 'root@pam';
    my $log = $o{log} // sub { print "$_[0]\n" };
    my $plan = placement($vmids);
    if (defined($o{target})) {
        die "a target node can only be given for one guest\n" if @$plan != 1;
        my ($row) = grep { $_->{node} eq $o{target} } @{$plan->[0]->{ranking} // []};
        die "guest $plan->[0]->{vmid} can't run on $o{target}: " . ($row ? $row->{reason} : 'unknown node') . "\n"
            if !$row || !$row->{ok};
        $plan->[0]->{to} = $o{target};
        $plan->[0]->{score} = $row->{score};
    }
    my @failed;
    for my $p (@$plan) {
        my $vmid = $p->{vmid};
        if (!$p->{to}) {
            $log->("$vmid: not started: $p->{reason}");
            push @failed, $vmid if $p->{reason} ne 'already running';
            next;
        }
        my $kind = $p->{type} eq 'lxc' ? 'lxc' : 'qemu';
        my $sid = ($kind eq 'lxc' ? 'ct' : 'vm') . ":$vmid";
        my $ok = eval {
            if ($p->{ha}) {
                $log->("$vmid: HA guest, requesting start (the HA manager places it)");
                cmd('ha-manager', 'set', $sid, '--state', 'started');
                return 1;
            }
            if ($p->{to} ne $p->{from}) {
                $log->("$vmid: moving to $p->{to} (expected VM score $p->{score}%)");
                my $res = PVE::WDCBalancer::Apply::run([ { id => "$vmid:$p->{from}:$p->{to}", vmid => $vmid, type => $p->{type},
                    from => $p->{from}, to => $p->{to}, offline => 1, reason => 'Power On (balanced)' } ], log => $log);
                die "move failed: $res->[0]->{message}\n" if $res->[0]->{result} ne 'ok';
            }
            $log->("$vmid: starting on $p->{to}");
            cmd('pvesh', 'create', "/nodes/$p->{to}/$kind/$vmid/status/start");
            return 1;
        };
        if (!$ok) {
            my $err = $@ // 'unknown error';
            chomp($err);
            $log->("$vmid: FAILED: $err");
            push @failed, $vmid;
        }
        PVE::WDCBalancer::State::locked(sub {
            PVE::WDCBalancer::State::add_history({ time => time(), type => 'poweron', user => $user, vmid => $vmid,
                from => $p->{from}, to => $p->{to}, result => $ok ? 'ok' : 'failed' });
            return 1;
        });
    }
    die "power on failed for " . join(', ', @failed) . "\n" if @failed;
    return $plan;
}

1;
