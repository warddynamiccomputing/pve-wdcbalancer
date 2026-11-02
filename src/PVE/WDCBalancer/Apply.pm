package PVE::WDCBalancer::Apply;

# Carries out recommendations: live migration for VMs, restart migration for
# containers, and 'ha-manager crm-command migrate' for HA guests (so HA
# doesn't move them back). Runs inside a task (wdcbapply), started from the
# API (Apply) or by the timer (automation).
#
# Moves run in parallel up to max_concurrent per node (source and target
# both count). Each move is checked again just before it starts: the guest
# must still be on its source node, running and unlocked, and the target
# online. A move is done when the guest's config is on the target node.
#
# The pure part, plan(), decides the order and is tested on its own.

use strict;
use warnings;

use JSON::PP;
use File::Temp;
use POSIX ();
use Time::HiRes;

use PVE::Cluster;
use PVE::INotify;
use PVE::Tools;

use PVE::WDCBalancer::Config;

our $POLL = 3;
our $TIMEOUT = 4 * 3600;

my $json = JSON::PP->new->canonical->allow_nonref;

# Which recommendations automation may apply on its own: cluster level
# 'full' (or a per-VM 'full' override), the VM not overridden to anything
# else, containers only with containers=restart.
sub automatic {
    my ($cfg, $recs) = @_;
    my $s = PVE::WDCBalancer::Config::settings($cfg);
    return [ grep {
        PVE::WDCBalancer::Config::automation_for($cfg, $_->{vmid}) eq 'full'
            && (!$_->{restart} || $s->{containers} eq 'restart')
    } @$recs ];
}

# Next moves that may start now, given running moves and the per-node limit.
# Recommendations of one guest (or a keep-together unit) run in list order.
sub next_batch {
    my ($pending, $running, $limit) = @_;
    my %busy;
    for my $r (@$running) {
        $busy{$r->{from}}++;
        $busy{$r->{to}}++;
    }
    my %guest_busy = map { $_->{vmid} => 1 } @$running;
    my @start;
    for my $r (@$pending) {
        next if $guest_busy{$r->{vmid}};
        next if ($busy{$r->{from}} // 0) >= $limit || ($busy{$r->{to}} // 0) >= $limit;
        push @start, $r;
        $busy{$r->{from}}++;
        $busy{$r->{to}}++;
        $guest_busy{$r->{vmid}} = 1;
    }
    return \@start;
}

# ---------------- cluster side ----------------

sub guest_location {
    my ($vmid) = @_;
    PVE::Cluster::cfs_update();
    my $vm = PVE::Cluster::get_vmlist()->{ids}->{$vmid} // return undef;
    return $vm->{node};
}

sub guest_lock {
    my ($vmid, $node, $type) = @_;
    my $dir = $type eq 'lxc' ? 'lxc' : 'qemu-server';
    my $raw = eval { PVE::Tools::file_get_contents("/etc/pve/nodes/$node/$dir/$vmid.conf") } // '';
    for my $line (split /\n/, $raw) {
        last if $line =~ /^\[/;
        return $1 if $line =~ /^lock:\s*(\S+)/;
    }
    return undef;
}

sub ha_sid {
    my ($rec) = @_;
    return ($rec->{type} eq 'lxc' ? 'ct' : 'vm') . ":$rec->{vmid}";
}

# The command that moves a guest. Blocking for qm/pct style migrations
# (pvesh runs the task in the foreground, also on remote nodes); HA only
# queues the request.
sub command {
    my ($rec) = @_;
    return [ 'ha-manager', 'crm-command', 'migrate', ha_sid($rec), $rec->{to} ] if $rec->{ha};
    if ($rec->{type} eq 'lxc') {
        return [ 'pvesh', 'create', "/nodes/$rec->{from}/lxc/$rec->{vmid}/migrate",
            '--target', $rec->{to}, '--restart', '1', '--output-format', 'json' ];
    }
    return [ 'pvesh', 'create', "/nodes/$rec->{from}/qemu/$rec->{vmid}/migrate",
        '--target', $rec->{to}, '--online', '1', '--output-format', 'json' ];
}

# Checks just before a move starts; returns an error or undef.
sub precheck {
    my ($rec, $online) = @_;
    my $at = guest_location($rec->{vmid});
    return "guest is gone" if !defined($at);
    return "guest is on $at now, not $rec->{from}" if $at ne $rec->{from};
    return "$rec->{to} is not online" if !$online->{$rec->{to}};
    if (my $lock = guest_lock($rec->{vmid}, $rec->{from}, $rec->{type})) {
        return "guest is locked ($lock)";
    }
    return undef;
}

sub task_status {
    my ($node, $upid) = @_;
    my $out = '';
    eval {
        PVE::Tools::run_command(['pvesh', 'get', "/nodes/$node/tasks/$upid/status", '--output-format', 'json'],
            outfunc => sub { $out .= "$_[0]\n" }, errfunc => sub {}, timeout => 30);
    };
    return eval { $json->decode($out) } // {};
}

sub online_nodes {
    my $m = PVE::Cluster::get_members() // {};
    return { map { $_ => 1 } grep { $m->{$_}->{online} } keys %$m };
}

# Runs the moves; $log->(line) prints into the task log, $renew->() keeps
# the timer lease while moves run. Returns the results in completion order.
sub run {
    my ($recs, %o) = @_;
    my $log = $o{log} // sub { print "$_[0]\n" };
    my $renew = $o{renew} // sub {};
    my $limit = $o{limit} // 2;
    my @pending = @$recs;
    my (%running, @results);
    my $online = online_nodes();

    my $finish = sub {
        my ($r, $ok, $msg) = @_;
        my $res = { %$r, result => $ok ? 'ok' : 'failed', message => $msg,
            duration => sprintf('%.0f', Time::HiRes::time() - $r->{started}) + 0, finished => time() };
        delete $res->{started};
        delete @$res{qw(pid out cmd_done rc error stopped_at)};
        push @results, $res;
        $log->(sprintf("%s %s %s: %s -> %s %s%s", $ok ? 'OK    ' : 'FAILED', $r->{type}, $r->{vmid},
            $r->{from}, $r->{to}, $ok ? "in $res->{duration}s" : '', $msg ? " ($msg)" : ''));
    };

    while (@pending || %running) {
        my @start = @{ next_batch(\@pending, [ values %running ], $limit) };
        my %started = map { $_ => 1 } @start;
        @pending = grep { !$started{$_} } @pending;
        for my $r (@start) {
            if (my $err = precheck($r, $online)) {
                $finish->({ %$r, started => Time::HiRes::time() }, 0, "skipped: $err");
                next;
            }
            my $cmd = command($r);
            $log->("start  $r->{type} $r->{vmid}: $r->{from} -> $r->{to} ($r->{reason})" . ($r->{ha} ? ' via HA' : ''));
            my $out = File::Temp->new(TMPDIR => 1, TEMPLATE => 'wdcbmoveXXXXXX');
            my $pid = fork();
            if (!defined($pid)) {
                $finish->({ %$r, started => Time::HiRes::time() }, 0, "fork failed: $!");
                next;
            }
            if (!$pid) {
                open(STDOUT, '>', $out->filename);
                open(STDERR, '>&', \*STDOUT);
                exec(@$cmd) or POSIX::_exit(127);
            }
            $running{$pid} = { %$r, pid => $pid, out => $out, started => Time::HiRes::time() };
        }

        # Reap finished commands. A move is done when the guest is on the
        # target. pvesh normally waits for the migration task; if it only
        # returned the task ID, follow the task. HA moves only queue.
        for my $pid (keys %running) {
            my $r = $running{$pid};
            if (!$r->{cmd_done}) {
                my $w = waitpid($pid, POSIX::WNOHANG());
                next if $w == 0;
                $r->{cmd_done} = 1;
                $r->{rc} = $? >> 8;
                my $text = '';
                if (open(my $fh, '<', $r->{out}->filename)) {
                    local $/;
                    $text = <$fh> // '';
                }
                ($r->{upid}) = $text =~ /(UPID:[^"\s]+)/;
                ($r->{error}) = grep { /\S/ } reverse split(/\n/, $text) if $r->{rc};
            }
            my $at = guest_location($r->{vmid}) // '';
            my $age = Time::HiRes::time() - $r->{started};
            my $done = sub { delete $running{$pid}; $finish->($r, @_); };
            if ($at eq $r->{to}) {
                $done->(1);
            } elsif ($r->{rc}) {
                $done->(0, $r->{error} // "exit code $r->{rc}");
            } elsif ($age > $TIMEOUT) {
                $done->(0, 'timed out waiting for the guest to arrive');
            } elsif (!$r->{ha}) {
                my $st = $r->{upid} ? task_status($r->{from}, $r->{upid}) : { status => 'stopped', exitstatus => 'no task' };
                next if ($st->{status} // '') ne 'stopped';
                if (($st->{exitstatus} // '') ne 'OK') {
                    $done->(0, "migration task: " . ($st->{exitstatus} // 'unknown'));
                } elsif (($r->{stopped_at} //= time()) < time() - 30) {
                    $done->(0, "migration finished but the guest is on " . ($at || 'unknown'));
                }
            }
        }
        $renew->();
        Time::HiRes::sleep($POLL) if %running;
    }
    return \@results;
}

1;
