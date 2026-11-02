package PVE::WDCBalancer::State;

# The last pass and the event history, on pmxcfs so every node (and the
# GUI through any node) shows the same recommendations.
#
#   state.json   - last pass: time, node, duration, result (Engine::pass),
#                  dismissed recommendations, last move per guest
#   history.json - capped list of events (passes, dismissals, faults)
#   lease.json   - which node runs the timer passes
#
# One node runs the passes: the lease holder. A lease not renewed for
# $LEASE seconds (its node is down or the timer stopped) is taken over.

use strict;
use warnings;

use JSON::PP;
use Time::HiRes;

use PVE::Cluster;
use PVE::INotify;
use PVE::Tools;

use PVE::WDCBalancer::Collect;
use PVE::WDCBalancer::Config;
use PVE::WDCBalancer::Engine;

our $LEASE = 180;
our $HISTORY_MAX = 500;
# pmxcfs files must stay small; above this the per-guest details are dropped
our $MAX_STATE = 900 * 1024;

my $json = JSON::PP->new->canonical;

sub file { return "$PVE::WDCBalancer::Config::DIR/$_[0]"; }

sub read_json {
    my ($name) = @_;
    my $f = file($name);
    return undef if ! -f $f;
    my $raw = eval { PVE::Tools::file_get_contents($f) } // return undef;
    return eval { $json->decode($raw) };
}

sub write_json {
    my ($name, $data) = @_;
    mkdir($PVE::WDCBalancer::Config::DIR) if ! -d $PVE::WDCBalancer::Config::DIR;
    PVE::Tools::file_set_contents(file($name), $json->encode($data));
}

sub locked {
    my ($code) = @_;
    my $res = PVE::Cluster::cfs_lock_domain('wdcbalancer', 30, $code);
    die $@ if $@;
    return $res;
}

sub read_state { return read_json('state.json') // {}; }

sub history { return read_json('history.json') // []; }

sub add_history {
    my (@events) = @_;
    my $h = history();
    push @$h, @events;
    splice(@$h, 0, @$h - $HISTORY_MAX) if @$h > $HISTORY_MAX;
    write_json('history.json', $h);
}

sub take_lease {
    my $node = PVE::INotify::nodename();
    my $now = time();
    return locked(sub {
        my $l = read_json('lease.json') // {};
        return $l->{node} if $l->{node} && $l->{node} ne $node && $now - ($l->{time} // 0) < $LEASE;
        write_json('lease.json', { node => $node, time => $now });
        return $node;
    });
}

# Faults that come from the cluster rather than the rules.
sub cluster_faults {
    my ($snap) = @_;
    my @f;
    push @f, { type => 'crs', message => "Proxmox CRS automatic rebalancing (ha-auto-rebalance) is on:"
        . " two balancers would compete, so no moves are made until it is turned off" }
        if $snap->{crs}->{auto_rebalance};
    push @f, map { { type => 'data', message => $_ } } @{$snap->{warnings} // []};
    return \@f;
}

# One pass now. Returns the stored state.
sub run_pass {
    my (%opts) = @_;
    my $t0 = Time::HiRes::time();
    my $cfg = PVE::WDCBalancer::Config::load();
    my $settings = PVE::WDCBalancer::Config::settings($cfg);
    my $prev = read_state();
    my $now = time();

    my %dismissed = map { $_ => $prev->{dismissed}->{$_} }
        grep { $now - $prev->{dismissed}->{$_} < $PVE::WDCBalancer::Engine::DISMISS_TTL } keys %{$prev->{dismissed} // {}};

    my $snap = PVE::WDCBalancer::Collect::snapshot(window => $settings->{interval}, config => $cfg);
    my $res = PVE::WDCBalancer::Engine::pass($snap, $cfg, now => $now, moved => $prev->{moved} // {},
        dismissed => \%dismissed);
    unshift @{$res->{faults}}, @{ cluster_faults($snap) };
    $res->{cluster}->{crs_conflict} = $snap->{crs}->{auto_rebalance} ? 1 : 0;

    my $state = {
        time => $now,
        node => PVE::INotify::nodename(),
        duration => sprintf('%.2f', Time::HiRes::time() - $t0) + 0,
        trigger => $opts{trigger} // 'timer',
        result => $res,
        dismissed => \%dismissed,
        moved => $prev->{moved} // {},
    };
    locked(sub {
        my $enc = $json->encode($state);
        if (length($enc) > $MAX_STATE) {
            $state->{result}->{guests} = {};
            $state->{result}->{truncated} = 1;
        }
        write_json('state.json', $state);
        add_history({ time => $now, type => 'pass', node => $state->{node}, trigger => $state->{trigger},
            score => $res->{cluster}->{score}, recommendations => scalar(@{$res->{recommendations}}),
            faults => scalar(@{$res->{faults}}) });
        return 1;
    });
    return $state;
}

# The systemd timer, every minute on every node: the lease holder runs a
# pass when the interval is up.
sub timer_run {
    my $node = PVE::INotify::nodename();
    my $leader = take_lease();
    return { node => $node, leader => $leader, ran => 0 } if $leader ne $node;
    my $cfg = PVE::WDCBalancer::Config::load();
    my $interval = PVE::WDCBalancer::Config::settings($cfg)->{interval};
    my $state = read_state();
    return { node => $node, leader => $leader, ran => 0, next => ($state->{time} // 0) + $interval }
        if time() - ($state->{time} // 0) < $interval - 30; # timer jitter
    run_pass(trigger => 'timer');
    return { node => $node, leader => $leader, ran => 1 };
}

sub dismiss {
    my ($id, $user) = @_;
    return locked(sub {
        my $state = read_state();
        my @recs = @{$state->{result}->{recommendations} // []};
        my ($rec) = grep { $_->{id} eq $id } @recs;
        die "no recommendation '$id' (run a pass to refresh the list)\n" if !$rec;
        $state->{dismissed}->{$id} = time();
        $state->{result}->{recommendations} = [ grep { $_->{id} ne $id } @recs ];
        write_json('state.json', $state);
        add_history({ time => time(), type => 'dismiss', user => $user, id => $id, vmid => $rec->{vmid},
            from => $rec->{from}, to => $rec->{to} });
        return $rec;
    });
}

1;
