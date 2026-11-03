package PVE::WDCBalancer::State;

# The last pass and the event history, on pmxcfs so every node (and the
# GUI through any node) shows the same recommendations.
#
#   state.json   - last pass: time, node, duration, result (Engine::pass),
#                  dismissed recommendations, last move per guest (when, and
#                  from where), the
#                  running apply task, the automation circuit breaker and
#                  when the set of online nodes last changed
#   history.json - capped list of events (passes, dismissals, faults)
#   lease.json   - which node runs the timer passes
#
# One node runs the passes: the lease holder. A lease not renewed for
# $LEASE seconds (its node is down or the timer stopped) is taken over.
#
# state.json is only changed with update_state(), a read-modify-write under
# the cluster lock: a pass, an apply task and a dismissal may run at the
# same time on different nodes and must not undo each other's changes.

use strict;
use warnings;

use JSON::PP;
use List::Util qw(max min);
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
# and the oldest history events
our $MAX_HISTORY = 512 * 1024;
our $MAX_TEXT = 1000;
# an apply task writes a heartbeat this often; one silent for $APPLY_STALE
# seconds (its node died or the task hung) no longer counts as running
our $BEAT = 60;
our $APPLY_STALE = 600;
# balancing waits this long after the set of online nodes changed (HA
# recovery, a node joining)
our $SETTLE = 600;
# circuit breaker: automation pauses after this many failed moves in a row,
# or this many within an hour
our $BREAKER_STREAK = 3;
our $BREAKER_HOUR = 5;

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

# Read-modify-write of state.json under the cluster lock; $code changes the
# state in place.
sub update_state {
    my ($code) = @_;
    return locked(sub {
        my $s = read_state();
        my $r = $code->($s);
        write_json('state.json', $s);
        return $r;
    });
}

sub history { return read_json('history.json') // []; }

sub clip {
    my ($v) = @_;
    return $v if !defined($v) || ref($v) || length($v) <= $MAX_TEXT;
    return substr($v, 0, $MAX_TEXT) . '...';
}

# Appends events (call it under the lock). Long texts are cut and lists
# shortened; the oldest events go when there are too many or the file
# gets too big for pmxcfs.
sub add_history {
    my (@events) = @_;
    my $h = history();
    for my $e (@events) {
        for my $k (keys %$e) {
            if (ref($e->{$k}) eq 'ARRAY') {
                my @l = @{$e->{$k}};
                $e->{$k} = [ map { clip($_) } @l[0 .. min($#l, 49)] ];
            } else {
                $e->{$k} = clip($e->{$k});
            }
        }
    }
    push @$h, @events;
    splice(@$h, 0, @$h - $HISTORY_MAX) if @$h > $HISTORY_MAX;
    while (@$h > 1 && length($json->encode($h)) > $MAX_HISTORY) {
        splice(@$h, 0, max(1, int(@$h / 10)));
    }
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
    my ($snap, $state) = @_;
    my @f;
    push @f, { type => 'crs', message => "Proxmox CRS automatic rebalancing (ha-auto-rebalance) is on:"
        . " two balancers would compete, so no moves are made until it is turned off" }
        if $snap->{crs}->{auto_rebalance};
    push @f, map { { type => 'data', message => $_ } } @{$snap->{warnings} // []};
    push @f, breaker_fault($state->{breaker}) if $state->{breaker};
    return \@f;
}

sub breaker_fault {
    my ($b) = @_;
    return { type => 'breaker', message => "Automation is paused: $b->{reason}. Moves are still recommended;"
        . " resume automation (wdcbalancer resume) once the cause is fixed" };
}

# The online nodes as one string, to notice when they change.
sub members_key {
    my ($snap) = @_;
    return join(',', sort grep { $snap->{nodes}->{$_}->{online} } keys %{$snap->{nodes} // {}});
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

    # after a node went down or came back, let HA recovery and the load settle
    my $members = members_key($snap);
    my $changed = $prev->{members_changed} // 0;
    $changed = $now if defined($prev->{members}) && $prev->{members} ne $members;
    my $settling = $now - $changed < $SETTLE ? $SETTLE - ($now - $changed) : 0;

    my $res = PVE::WDCBalancer::Engine::pass($snap, $cfg, now => $now, moved => $prev->{moved} // {},
        left => $prev->{left} // {}, dismissed => \%dismissed, settling => $settling);
    unshift @{$res->{faults}}, @{ cluster_faults($snap, $prev) };
    $res->{cluster}->{crs_conflict} = $snap->{crs}->{auto_rebalance} ? 1 : 0;
    my $duration = sprintf('%.2f', Time::HiRes::time() - $t0) + 0;
    my $node = PVE::INotify::nodename();
    my $trigger = $opts{trigger} // 'timer';

    # the result replaces the last one; what others wrote meanwhile (an apply
    # task, a dismissal, a move) stays
    return update_state(sub {
        my ($s) = @_;
        # a guest moved while the pass ran: its recommendations are stale
        my %fresh = map { $_ => 1 } grep { $s->{moved}->{$_} >= $now - 1 && ($prev->{moved}->{$_} // 0) != $s->{moved}->{$_} }
            keys %{$s->{moved} // {}};
        my %d = (%dismissed, %{$s->{dismissed} // {}});
        delete @d{ grep { $now - $d{$_} >= $PVE::WDCBalancer::Engine::DISMISS_TTL } keys %d };
        $res->{recommendations} = [ grep { !$fresh{$_->{vmid}} && !$d{$_->{id}} } @{$res->{recommendations}} ];
        my $b = $s->{breaker};
        $res->{faults} = [ grep { $_->{type} ne 'breaker' } @{$res->{faults}} ];
        unshift @{$res->{faults}}, breaker_fault($b) if $b;
        %$s = (%$s, time => $now, node => $node, duration => $duration, trigger => $trigger, result => $res,
            dismissed => \%d, members => $members, members_changed => $changed);
        $s->{moved} //= {};
        if (length($json->encode($s)) > $MAX_STATE) {
            $s->{result}->{guests} = {};
            $s->{result}->{truncated} = 1;
        }
        add_history({ time => $now, type => 'pass', node => $node, trigger => $trigger,
            score => $res->{cluster}->{score}, recommendations => scalar(@{$res->{recommendations}}),
            faults => scalar(@{$res->{faults}}) });
        return { %$s };
    });
}

# The systemd timer, every minute on every node: the lease holder runs a
# pass when the interval is up, keeps the mirrored HA rules in step, reports
# new faults and, with full automation, applies the recommendations.
sub timer_run {
    my $node = PVE::INotify::nodename();
    # the config first: a node that can't read it (a rolling upgrade, the
    # config written by a newer version) must not hold the lease
    my $cfg = PVE::WDCBalancer::Config::load();
    my $settings = PVE::WDCBalancer::Config::settings($cfg);
    my $leader = take_lease();
    return { node => $node, leader => $leader, ran => 0 } if $leader ne $node;
    my $prev = read_state();
    return { node => $node, leader => $leader, ran => 0, next => ($prev->{time} // 0) + $settings->{interval} }
        if time() - ($prev->{time} // 0) < $settings->{interval} - 30; # timer jitter
    return { node => $node, leader => $leader, ran => 0, applying => 1 } if apply_running($prev);

    my $state = run_pass(trigger => 'timer');
    my $res = $state->{result};

    my $ha = eval { PVE::WDCBalancer::HARules::sync($cfg) } // { errors => [ "HA rule sync failed: $@" ] };
    if (@{$ha->{changes} // []} || @{$ha->{errors} // []}) {
        my @f = map { { type => 'ha-rules', message => $_ } } @{$ha->{errors} // []};
        update_state(sub {
            my ($s) = @_;
            add_history({ time => time(), type => 'ha-rules', node => $node, changes => $ha->{changes}, errors => $ha->{errors} });
            push @{$s->{result}->{faults}}, @f;
        });
        push @{$res->{faults}}, @f;
    }

    if ($settings->{notify}) {
        my $new = PVE::WDCBalancer::Notify::new_faults($prev->{result}->{faults}, $res->{faults});
        PVE::WDCBalancer::Notify::send('warning', 'pve-wdcbalancer: ' . scalar(@$new) . ' new fault(s)',
            [ map { "- $_->{message}" } @$new ]) if @$new;
    }

    my $auto = PVE::WDCBalancer::Apply::automatic($cfg, $res->{recommendations});
    my $applied = 0;
    if ($settings->{automation} eq 'full' && @$auto && !$res->{cluster}->{crs_conflict} && !$state->{breaker}) {
        my $rpcenv = PVE::RPCEnvironment::get();
        # a failed move fails the task (and is notified), not the timer
        eval {
            $rpcenv->fork_worker('wdcbapply', undef, 'root@pam', sub {
                apply(\@$auto, trigger => 'automation');
            });
        };
        if ($@) {
            warn "wdcbalancer: apply task: $@";
        } else {
            $applied = scalar(@$auto);
        }
    }
    return { node => $node, leader => $leader, ran => 1, applied => $applied };
}

# ---------------- applying recommendations ----------------

# Is an apply task running? (state.json 'applying', set by apply() and
# renewed by its heartbeat.) Not when its node is offline, its process is
# gone or its heartbeat stopped.
sub apply_running {
    my ($state) = @_;
    my $a = $state->{applying} // return 0;
    my $now = time();
    return 0 if $now - ($a->{beat} // $a->{time} // 0) > $APPLY_STALE;
    return 0 if $now - ($a->{time} // 0) > $PVE::WDCBalancer::Apply::TIMEOUT + 600;
    my $node = $a->{node} // '';
    return kill(0, $a->{pid}) ? 1 : 0 if $node eq PVE::INotify::nodename();
    my $members = eval { PVE::Cluster::get_members() } // {};
    return 0 if %$members && !($members->{$node} && $members->{$node}->{online});
    return 1;
}

# Circuit breaker: counts the failed moves (a move skipped because the
# guest changed meanwhile doesn't count) and pauses automation when too
# many fail. Returns the reason when it trips now.
sub breaker_update {
    my ($s, $results, $now) = @_;
    my $f = $s->{failures} //= { streak => 0, times => [] };
    for my $r (@$results) {
        if ($r->{result} eq 'ok') {
            $f->{streak} = 0;
        } elsif (($r->{message} // '') !~ /^skipped:/) {
            $f->{streak}++;
            push @{$f->{times}}, $now;
        }
    }
    $f->{times} = [ grep { $now - $_ < 3600 } @{$f->{times}} ];
    return undef if $s->{breaker};
    my $why = $f->{streak} >= $BREAKER_STREAK ? "$f->{streak} moves in a row failed"
        : @{$f->{times}} >= $BREAKER_HOUR ? scalar(@{$f->{times}}) . " moves failed within an hour" : undef;
    return undef if !$why;
    $s->{breaker} = { time => $now, reason => $why };
    return $why;
}

# Resumes automation after the circuit breaker paused it. Returns 1 if it
# was paused.
sub breaker_reset {
    my ($user) = @_;
    return update_state(sub {
        my ($s) = @_;
        my $b = delete $s->{breaker};
        $s->{failures} = { streak => 0, times => [] };
        $s->{result}->{faults} = [ grep { ($_->{type} // '') ne 'breaker' } @{$s->{result}->{faults} // []} ]
            if $s->{result};
        add_history({ time => time(), type => 'resume', user => $user, reason => $b->{reason} }) if $b;
        return $b ? 1 : 0;
    });
}

# Carries out recommendations (inside a task). $trigger is 'automation' or
# 'user@realm'. Moved guests start their cooldown; applied recommendations
# leave the list.
sub apply {
    my ($recs, %o) = @_;
    my $node = PVE::INotify::nodename();
    my $cfg = PVE::WDCBalancer::Config::load();
    my $settings = PVE::WDCBalancer::Config::settings($cfg);
    my $mine = sub { my $a = $_[0]->{applying} // {}; return ($a->{pid} // 0) == $$ && ($a->{node} // '') eq $node; };
    update_state(sub {
        my ($s) = @_;
        die "another apply task is running\n" if apply_running($s);
        die "automation is paused by the circuit breaker: $s->{breaker}->{reason}\n"
            if $o{trigger} eq 'automation' && $s->{breaker};
        my $t = time();
        $s->{applying} = { node => $node, pid => $$, time => $t, beat => $t, count => scalar(@$recs) };
    });

    # heartbeat (and, for automation, the timer lease) while the moves run
    my $last = time();
    my $renew = sub {
        return if time() - $last < $BEAT;
        $last = time();
        eval { update_state(sub { $_[0]->{applying}->{beat} = $last if $mine->($_[0]); }) };
        eval { take_lease() } if $o{trigger} eq 'automation';
    };
    my $results = eval {
        PVE::WDCBalancer::Apply::run($recs, limit => $settings->{max_concurrent}, renew => $renew);
    };
    my $err = $@;

    my $tripped;
    update_state(sub {
        my ($s) = @_;
        delete $s->{applying} if $mine->($s);
        my %done = map { $_->{id} => 1 } grep { $_->{result} eq 'ok' } @{$results // []};
        for my $r (grep { $_->{result} eq 'ok' } @{$results // []}) {
            $s->{moved}->{$r->{vmid}} = $r->{finished};
            # where it came from: moving it straight back costs more
            $s->{left}->{$r->{vmid}} = { node => $r->{from}, time => $r->{finished} };
        }
        # forget old moves (only the cooldown and the bounce cost need them)
        delete @{$s->{moved}}{ grep { time() - $s->{moved}->{$_} > 86400 } keys %{$s->{moved} // {}} };
        delete @{$s->{left}}{ grep { time() - $s->{left}->{$_}->{time} > 86400 } keys %{$s->{left} // {}} };
        $s->{result}->{recommendations} = [ grep { !$done{$_->{id}} } @{$s->{result}->{recommendations} // []} ];
        $tripped = breaker_update($s, $results // [], time());
        unshift @{$s->{result}->{faults}}, breaker_fault($s->{breaker}) if $tripped;
        add_history(map { {
            time => $_->{finished}, type => 'move', node => $node, trigger => $o{trigger}, vmid => $_->{vmid},
            from => $_->{from}, to => $_->{to}, result => $_->{result}, message => $_->{message},
            duration => $_->{duration}, reason => $_->{reason}, priority => $_->{priority},
        } } @{$results // []});
        add_history({ time => time(), type => 'breaker', node => $node, reason => $tripped }) if $tripped;
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
    if ($tripped && $settings->{notify}) {
        PVE::WDCBalancer::Notify::send('error', 'pve-wdcbalancer: automation paused',
            [ "Automation is paused: $tripped.", 'Moves are still recommended. Resume with: wdcbalancer resume' ]);
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
    return update_state(sub {
        my ($state) = @_;
        my @recs = @{$state->{result}->{recommendations} // []};
        my ($rec) = grep { $_->{id} eq $id } @recs;
        die "no recommendation '$id' (run a pass to refresh the list)\n" if !$rec;
        $state->{dismissed}->{$id} = time();
        $state->{result}->{recommendations} = [ grep { $_->{id} ne $id } @recs ];
        add_history({ time => time(), type => 'dismiss', user => $user, id => $id, vmid => $rec->{vmid},
            from => $rec->{from}, to => $rec->{to} });
        return $rec;
    });
}

1;
