package PVE::WDCBalancer::Config;

# Cluster-wide balancer configuration on pmxcfs, so every node reads the same
# settings, groups and rules.
#
# {
#   "version": 1,
#   "settings":    { see $SETTINGS },
#   "vm_groups":   { "<name>": { "members": [ <vmid>, ... ], "comment": "..." } },
#   "host_groups": { "<name>": { "members": [ "<node>", ... ], "comment": "..." } },
#   "rules":       { "<name>": { "type": "together" | "separate" | "vm-host",
#                                "vms": [ <vmid>, ... ],          # together, separate
#                                "vm_group": "...", "host_group": "...",
#                                "mode": "must" | "should" | "must-not" | "should-not",  # vm-host
#                                "enabled": 1, "comment": "..." } },
#   "overrides":   { "<vmid>": { "automation": "disabled" | "manual" | "partial" | "full" } },
#   "maintenance": { "<node>": { "since": <epoch>, "user": "..." } }
# }
#
# validate() is pure; load/save/update need pmxcfs.

use strict;
use warnings;

use JSON::PP;

use PVE::Cluster;
use PVE::Tools;

our $DIR = '/etc/pve/wdcbalancer';
our $FILE = "$DIR/config.json";

# name => [ default, check, description ]. The descriptions are shown by the
# API schema and the GUI.
our $SETTINGS = {
    automation => [ 'manual', { enum => [qw(manual partial full)] },
        'Automation level: manual (recommendations only), partial (automatic initial placement), full (automatic balancing).' ],
    threshold => [ 3, { min => 1, max => 5 },
        'Migration threshold 1 (conservative: mandatory moves only) to 5 (aggressive).' ],
    interval => [ 300, { min => 60, max => 86400 }, 'Seconds between balancing passes.' ],
    memory_metric => [ 'active', { enum => [qw(active consumed)] },
        'Memory demand: active (guest-reported used memory) or consumed (host memory of the guest process).' ],
    network_aware => [ 0, { bool => 1 }, 'Avoid moving guests to nodes whose network is saturated.' ],
    net_capacity => [ 1250, { min => 10, max => 1000000 }, 'Network capacity per node in MB/s, for network-aware balancing.' ],
    net_threshold => [ 80, { min => 10, max => 100 }, 'Network utilization (%) above which a node is saturated.' ],
    max_moves => [ 8, { min => 1, max => 256 }, 'Maximum migrations recommended per pass.' ],
    max_concurrent => [ 2, { min => 1, max => 16 }, 'Maximum concurrent migrations per node.' ],
    cooldown => [ 1800, { min => 0, max => 86400 }, 'Seconds a moved guest stays put (except for mandatory moves).' ],
    headroom => [ 10, { min => 0, max => 50 }, 'Memory (%) kept free on every node when placing guests.' ],
    migration_speed => [ 1000, { min => 10, max => 100000 }, 'Expected live-migration speed in MB/s (cost of a move).' ],
    containers => [ 'manual', { enum => [qw(manual restart)] },
        'Containers: manual (recommendations only, a move restarts them) or restart (may be moved with a restart).' ],
    notify => [ 1, { bool => 1 }, 'Send notifications (Datacenter > Notifications) for new faults and for moves.' ],
};

our @RULE_TYPES = qw(together separate vm-host);
our @RULE_MODES = qw(must should must-not should-not);
our @AUTOMATION = qw(disabled manual partial full);

my $NAME_RE = qr/^[A-Za-z][A-Za-z0-9_.-]{0,63}$/;
my $NODE_RE = qr/^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$/;

sub empty {
    return { version => 1, settings => {}, vm_groups => {}, host_groups => {}, rules => {}, overrides => {}, maintenance => {} };
}

sub defaults {
    return { map { $_ => $SETTINGS->{$_}->[0] } keys %$SETTINGS };
}

# settings with defaults filled in
sub settings {
    my ($cfg) = @_;
    my $s = defaults();
    for my $k (keys %{$cfg->{settings} // {}}) {
        $s->{$k} = $cfg->{settings}->{$k} if exists($SETTINGS->{$k});
    }
    return $s;
}

sub check_setting {
    my ($name, $value) = @_;
    my $def = $SETTINGS->{$name} // die "unknown setting '$name'\n";
    my $c = $def->[1];
    die "setting '$name' has no value\n" if !defined($value);
    if ($c->{enum}) {
        die "setting '$name' must be one of: @{$c->{enum}}\n" if !grep { $_ eq $value } @{$c->{enum}};
        return $value;
    }
    if ($c->{bool}) {
        die "setting '$name' must be 0 or 1\n" if $value !~ /^[01]$/;
        return $value + 0;
    }
    die "setting '$name' must be a number\n" if $value !~ /^\d+(?:\.\d+)?$/;
    die "setting '$name' must be between $c->{min} and $c->{max}\n" if $value < $c->{min} || $value > $c->{max};
    return $value + 0;
}

sub vmid_ok { return defined($_[0]) && $_[0] =~ /^[1-9]\d{2,8}$/; }

# Returns a list of problems (empty if the config is valid). Conflicts
# between enabled rules are problems too: like vSphere, a conflicting rule
# can't be saved enabled.
sub validate {
    my ($cfg) = @_;
    my @err;

    for my $k (sort keys %{$cfg->{settings} // {}}) {
        eval { check_setting($k, $cfg->{settings}->{$k}) };
        push @err, $@ =~ s/\n$//r if $@;
    }

    for my $kind (qw(vm_groups host_groups)) {
        for my $name (sort keys %{$cfg->{$kind} // {}}) {
            push @err, "invalid group name '$name'" if $name !~ $NAME_RE;
            my $m = $cfg->{$kind}->{$name}->{members};
            if (ref($m) ne 'ARRAY' || !@$m) {
                push @err, "group '$name' has no members";
                next;
            }
            for my $x (@$m) {
                push @err, "group '$name': invalid " . ($kind eq 'vm_groups' ? "VM ID" : "node name") . " '$x'"
                    if $kind eq 'vm_groups' ? !vmid_ok($x) : ($x // '') !~ $NODE_RE;
            }
        }
    }
    for my $name (sort keys %{$cfg->{vm_groups} // {}}) {
        push @err, "'$name' is both a VM group and a host group" if $cfg->{host_groups}->{$name};
    }

    for my $name (sort keys %{$cfg->{rules} // {}}) {
        my $r = $cfg->{rules}->{$name};
        push @err, "invalid rule name '$name'" if $name !~ $NAME_RE;
        my $type = $r->{type} // '';
        if (!grep { $_ eq $type } @RULE_TYPES) {
            push @err, "rule '$name': unknown type '$type'";
            next;
        }
        if ($type eq 'vm-host') {
            push @err, "rule '$name': unknown VM group '" . ($r->{vm_group} // '') . "'"
                if !$cfg->{vm_groups}->{$r->{vm_group} // ''};
            push @err, "rule '$name': unknown host group '" . ($r->{host_group} // '') . "'"
                if !$cfg->{host_groups}->{$r->{host_group} // ''};
            push @err, "rule '$name': mode must be one of: @RULE_MODES"
                if !grep { $_ eq ($r->{mode} // '') } @RULE_MODES;
        } else {
            my $vms = $r->{vms};
            if (ref($vms) ne 'ARRAY' || @$vms < 2) {
                push @err, "rule '$name': needs at least two VMs";
            } elsif (my @bad = grep { !vmid_ok($_) } @$vms) {
                push @err, "rule '$name': invalid VM ID '$bad[0]'";
            }
        }
    }

    for my $vmid (sort keys %{$cfg->{overrides} // {}}) {
        push @err, "override: invalid VM ID '$vmid'" if !vmid_ok($vmid);
        my $a = $cfg->{overrides}->{$vmid}->{automation} // '';
        push @err, "override for $vmid: automation must be one of: @AUTOMATION" if !grep { $_ eq $a } @AUTOMATION;
    }

    for my $node (sort keys %{$cfg->{maintenance} // {}}) {
        push @err, "maintenance: invalid node name '$node'" if $node !~ $NODE_RE;
    }

    push @err, @{ rule_conflicts($cfg) } if !@err;
    return \@err;
}

# ---------------- rule helpers (pure) ----------------

sub enabled_rules {
    my ($cfg) = @_;
    my $rules = $cfg->{rules} // {};
    return [ map { { %{$rules->{$_}}, name => $_ } } grep { $rules->{$_}->{enabled} // 1 } sort keys %$rules ];
}

# VMs a rule applies to
sub rule_vms {
    my ($cfg, $r) = @_;
    return [ @{$r->{vms} // []} ] if $r->{type} ne 'vm-host';
    return [ @{ $cfg->{vm_groups}->{$r->{vm_group}}->{members} // [] } ];
}

sub rule_hosts {
    my ($cfg, $r) = @_;
    return [ @{ $cfg->{host_groups}->{$r->{host_group} // ''}->{members} // [] } ];
}

# The nodes a VM must stay within, from its 'must' and 'must-not' rules,
# given the cluster's nodes. undef = unrestricted.
sub must_nodes {
    my ($cfg, $vmid, $all_nodes) = @_;
    my $allowed;
    for my $r (@{ enabled_rules($cfg) }) {
        next if $r->{type} ne 'vm-host' || ($r->{mode} ne 'must' && $r->{mode} ne 'must-not');
        next if !grep { $_ == $vmid } @{ rule_vms($cfg, $r) };
        my %h = map { $_ => 1 } @{ rule_hosts($cfg, $r) };
        my @set = $r->{mode} eq 'must' ? grep { $h{$_} } @$all_nodes : grep { !$h{$_} } @$all_nodes;
        my %s = map { $_ => 1 } @set;
        $allowed = defined($allowed) ? { map { $_ => 1 } grep { $s{$_} } keys %$allowed } : \%s;
    }
    return $allowed;
}

# Conflicts between enabled rules, independent of where guests run now.
# Nodes are the union of the host groups (a conflict there is a conflict
# on any cluster).
sub rule_conflicts {
    my ($cfg) = @_;
    my @err;
    my $rules = enabled_rules($cfg);
    my %nodes = map { $_ => 1 } map { @{$_->{members} // []} } values %{$cfg->{host_groups} // {}};
    my @nodes = sort keys %nodes;
    push @nodes, '(other nodes)'; # a node in no host group

    # 1. keep-together and separate sharing two VMs
    my @tog = grep { $_->{type} eq 'together' } @$rules;
    my @sep = grep { $_->{type} eq 'separate' } @$rules;
    for my $t (@tog) {
        my %in = map { $_ => 1 } @{$t->{vms}};
        for my $s (@sep) {
            my @both = grep { $in{$_} } @{$s->{vms}};
            push @err, "rules '$t->{name}' and '$s->{name}' conflict: VMs @both must be kept together and kept apart"
                if @both >= 2;
        }
    }

    # 2. 'must' and 'must-not' rules leaving a VM nowhere to run
    my %vms = map { $_ => 1 } map { @{ rule_vms($cfg, $_) } } grep { $_->{type} eq 'vm-host' } @$rules;
    for my $vmid (sort { $a <=> $b } keys %vms) {
        my $allowed = must_nodes($cfg, $vmid, \@nodes);
        if (defined($allowed) && !%$allowed) {
            my @names = map { $_->{name} } grep {
                $_->{type} eq 'vm-host' && $_->{mode} =~ /^must/ && grep { $_ == $vmid } @{ rule_vms($cfg, $_) }
            } @$rules;
            push @err, "rules @names conflict: VM $vmid is left with no node it may run on";
        }
    }

    # 3. keep-together VMs whose 'must' rules have no node in common
    for my $t (@tog) {
        my $common;
        for my $vmid (@{$t->{vms}}) {
            my $allowed = must_nodes($cfg, $vmid, \@nodes) // next;
            $common = defined($common) ? { map { $_ => 1 } grep { $allowed->{$_} } keys %$common } : { %$allowed };
        }
        push @err, "rule '$t->{name}' conflicts with VM/Host 'must' rules: its VMs have no node in common"
            if defined($common) && !%$common;
    }

    # 4. separate rule with more VMs than nodes they may use
    for my $s (@sep) {
        my %usable;
        for my $vmid (@{$s->{vms}}) {
            my $allowed = must_nodes($cfg, $vmid, \@nodes);
            %usable = (%usable, %{ $allowed // { map { $_ => 1 } @nodes, '(any)' } });
        }
        next if $usable{'(any)'} || $usable{'(other nodes)'};
        my $n = scalar(keys %usable);
        push @err, "rule '$s->{name}' can't be met: " . scalar(@{$s->{vms}}) . " VMs to keep apart on $n node(s)"
            if @{$s->{vms}} > $n;
    }
    return \@err;
}

sub automation_for {
    my ($cfg, $vmid) = @_;
    my $o = $cfg->{overrides}->{$vmid};
    return $o->{automation} if $o && $o->{automation};
    return settings($cfg)->{automation};
}

# ---------------- pmxcfs ----------------

sub load {
    return empty() if ! -f $FILE;
    my $raw = PVE::Tools::file_get_contents($FILE);
    my $cfg = eval { JSON::PP->new->decode($raw) };
    die "unable to parse $FILE - $@" if $@;
    $cfg->{$_} //= {} for qw(settings vm_groups host_groups rules overrides maintenance);
    return $cfg;
}

sub save {
    my ($cfg) = @_;
    my $err = validate($cfg);
    die join("\n", @$err) . "\n" if @$err;
    mkdir($DIR) if ! -d $DIR;
    PVE::Tools::file_set_contents($FILE, JSON::PP->new->canonical->pretty->encode($cfg));
}

# Read-modify-write under the cluster-wide 'wdcbalancer' lock. $code may
# change the config in place; the result is validated before it is written.
sub update {
    my ($code) = @_;
    my $res = PVE::Cluster::cfs_lock_domain('wdcbalancer', 30, sub {
        my $cfg = load();
        my $r = $code->($cfg);
        save($cfg);
        return $r;
    });
    die $@ if $@;
    return $res;
}

1;
