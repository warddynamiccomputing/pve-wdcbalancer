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
use PVE::RPCEnvironment;
use PVE::Tools;

use PVE::WDCBalancer::Apply;
use PVE::WDCBalancer::Collect;
use PVE::WDCBalancer::Config;
use PVE::WDCBalancer::Engine;
use PVE::WDCBalancer::HARules;
use PVE::WDCBalancer::Notify;

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
# pass when the interval is up, keeps the mirrored HA rules in step, reports
# new faults and, with full automation, applies the recommendations.
sub timer_run {
    my $node = PVE::INotify::nodename();
    my $leader = take_lease();
    return { node => $node, leader => $leader, ran => 0 } if $leader ne $node;
    my $cfg = PVE::WDCBalancer::Config::load();
    my $settings = PVE::WDCBalancer::Config::settings($cfg);
    my $prev = read_state();
    return { node => $node, leader => $leader, ran => 0, next => ($prev->{time} // 0) + $settings->{interval} }
        if time() - ($prev->{time} // 0) < $settings->{interval} - 30; # timer jitter
    return { node => $node, leader => $leader, ran => 0, applying => 1 } if apply_running($prev);

    my $state = run_pass(trigger => 'timer');
    my $res = $state->{result};

    my $ha = eval { PVE::WDCBalancer::HARules::sync($cfg) } // { errors => [ "HA rule sync failed: $@" ] };
    if (@{$ha->{changes} // []} || @{$ha->{errors} // []}) {
        locked(sub {
            add_history({ time => time(), type => 'ha-rules', node => $node, changes => $ha->{changes}, errors => $ha->{errors} });
            my $s = read_state();
            push @{$s->{result}->{faults}}, map { { type => 'ha-rules', message => $_ } } @{$ha->{errors} // []};
            write_json('state.json', $s);
            return 1;
        });
        push @{$res->{faults}}, map { { type => 'ha-rules', message => $_ } } @{$ha->{errors} // []};
    }

    if ($settings->{notify}) {
        my $new = PVE::WDCBalancer::Notify::new_faults($prev->{result}->{faults}, $res->{faults});
        PVE::WDCBalancer::Notify::send('warning', 'pve-wdcbalancer: ' . scalar(@$new) . ' new fault(s)',
            [ map { "- $_->{message}" } @$new ]) if @$new;
    }

    my $auto = PVE::WDCBalancer::Apply::automatic($cfg, $res->{recommendations});
    my $applied = 0;
    if ($settings->{automation} eq 'full' && @$auto && !$res->{cluster}->{crs_conflict}) {
        my $rpcenv = PVE::RPCEnvironment::get();
        # a failed move fails the task (and is notified), not the timer
        eval {
            $rpcenv->fork_worker('wdcbapply', undef, 'root@pam', sub {
                apply(\@$auto, trigger => 'automation');
            });
        };
        warn "wdcbalancer: apply task: $@" if $@;
        $applied = scalar(@$auto);
    }
    return { node => $node, leader => $leader, ran => 1, applied => $applied };
}

# ---------------- applying recommendations ----------------

# Is an apply task running? (state.json 'applying', set by apply())
sub apply_running {
    my ($state) = @_;
    my $a = $state->{applying} // return 0;
    return 0 if time() - ($a->{time} // 0) > $PVE::WDCBalancer::Apply::TIMEOUT + 600;
    return kill(0, $a->{pid}) ? 1 : 0 if ($a->{node} // '') eq PVE::INotify::nodename();
    return 1;
}

# Carries out recommendations (inside a task). $trigger is 'automation' or
# 'user@realm'. Moved guests start their cooldown; applied recommendations
# leave the list.
sub apply {
    my ($recs, %o) = @_;
    my $node = PVE::INotify::nodename();
    my $cfg = PVE::WDCBalancer::Config::load();
    my $settings = PVE::WDCBalancer::Config::settings($cfg);
    locked(sub {
        my $s = read_state();
        die "another apply task is running\n" if apply_running($s);
        $s->{applying} = { node => $node, pid => $$, time => time(), count => scalar(@$recs) };
        write_json('state.json', $s);
        return 1;
    });

    my $results = eval {
        PVE::WDCBalancer::Apply::run($recs, limit => $settings->{max_concurrent},
            renew => $o{trigger} eq 'automation' ? sub { eval { take_lease() } } : sub {});
    };
    my $err = $@;

    locked(sub {
        my $s = read_state();
        delete $s->{applying};
        my %done = map { $_->{id} => 1 } grep { $_->{result} eq 'ok' } @{$results // []};
        for my $r (grep { $_->{result} eq 'ok' } @{$results // []}) {
            $s->{moved}->{$r->{vmid}} = $r->{finished};
        }
        # forget old moves (only the cooldown needs them)
        delete @{$s->{moved}}{ grep { time() - $s->{moved}->{$_} > 86400 } keys %{$s->{moved} // {}} };
        $s->{result}->{recommendations} = [ grep { !$done{$_->{id}} } @{$s->{result}->{recommendations} // []} ];
        write_json('state.json', $s);
        add_history(map { {
            time => $_->{finished}, type => 'move', node => $node, trigger => $o{trigger}, vmid => $_->{vmid},
            from => $_->{from}, to => $_->{to}, result => $_->{result}, message => $_->{message},
            duration => $_->{duration}, reason => $_->{reason}, priority => $_->{priority},
        } } @{$results // []});
        return 1;
    });
    die $err if $err;

    my @ok = grep { $_->{result} eq 'ok' } @$results;
    my @failed = grep { $_->{result} ne 'ok' } @$results;
    if ($settings->{notify} && ($o{trigger} eq 'automation' ? @$results : @failed)) {
        PVE::WDCBalancer::Notify::send(@failed ? 'warning' : 'info',
            sprintf('pve-wdcbalancer: %d guest(s) moved%s', scalar(@ok), @failed ? ', ' . scalar(@failed) . ' failed' : ''),
            [ map { sprintf('- %s %s: %s -> %s, %s%s', $_->{type}, $_->{vmid}, $_->{from}, $_->{to}, $_->{result},
                $_->{message} ? " ($_->{message})" : '') } @$results ]);
    }
    die scalar(@failed) . " of " . scalar(@$results) . " move(s) failed\n" if @failed;
    return $results;
}

# Recommendations by ID from the last pass (for the API's apply).
sub pick {
    my ($ids) = @_;
    my $state = read_state();
    my @recs = @{$state->{result}->{recommendations} // []};
    return \@recs if !$ids;
    my %by = map { $_->{id} => $_ } @recs;
    my @res;
    for my $id (@$ids) {
        push @res, $by{$id} // die "no recommendation '$id' (run a pass to refresh the list)\n";
    }
    # keep the pass order: later recommendations assume earlier ones
    my %want = map { $_ => 1 } @$ids;
    return [ grep { $want{$_->{id}} } @recs ];
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
