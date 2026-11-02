package PVE::WDCBalancer::Constraints;

# Hard limits on where a guest may run. Pure: works on a cluster snapshot
# (see PVE::WDCBalancer::Collect).
#
# movable()  - can the guest be live-migrated at all (no target involved)
# can_run()  - may it run on this target node (rules, storage, network, CPU)
# fits()     - is there memory for it on the target, given the node's load

use strict;
use warnings;

use PVE::WDCBalancer::Config;
use PVE::WDCBalancer::Score;

# Returns (1) or (0, reason).
sub movable {
    my ($snap, $cfg, $vmid) = @_;
    my $g = $snap->{guests}->{$vmid} // return (0, 'unknown guest');
    return (0, 'template') if $g->{template};
    return (0, 'not running') if ($g->{status} // '') ne 'running';
    return (0, "locked ($g->{lock})") if $g->{lock};
    my $auto = PVE::WDCBalancer::Config::automation_for($cfg, $vmid);
    return (0, 'load balancing disabled for this guest') if $auto eq 'disabled';
    for my $d (@{$g->{disks} // []}) {
        next if $d->{cdrom} && !$d->{storage}; # empty drive or 'none'
        return (0, "$d->{key} is a host device or path") if !$d->{storage};
        my $st = $snap->{storages}->{$d->{storage}};
        return (0, "$d->{key} is on storage '$d->{storage}', which is unknown") if !$st;
        return (0, "$d->{key} is on local storage '$d->{storage}'") if !$st->{shared};
    }
    return (0, "$g->{devices}->[0] is passed through") if @{$g->{devices} // []};
    # containers can be moved, but only with a restart: recommendations say
    # so, and only the 'restart' container setting lets automation do it
    return (1);
}

# May $vmid run on $target? Ignores memory (see fits) and soft rules.
sub can_run {
    my ($snap, $cfg, $vmid, $target) = @_;
    my $g = $snap->{guests}->{$vmid};
    my $n = $snap->{nodes}->{$target} // return (0, "unknown node '$target'");
    return (0, "$target is offline") if !$n->{online};
    return (0, "$target is in maintenance mode") if $n->{maintenance};

    my $allowed = PVE::WDCBalancer::Config::must_nodes($cfg, $vmid, [ keys %{$snap->{nodes}} ]);
    return (0, "a 'must' VM/Host rule keeps it off $target") if $allowed && !$allowed->{$target};

    for my $r (@{$snap->{ha_rules} // []}) {
        next if !$r->{strict} || $r->{type} ne 'node-affinity';
        next if !grep { $_ == $vmid } @{$r->{resources}};
        my $listed = exists($r->{nodes}->{$target});
        return (0, "strict HA rule '$r->{id}' keeps it off $target")
            if ($r->{affinity} // 'positive') eq 'positive' ? !$listed : $listed;
    }

    for my $d (@{$g->{disks} // []}) {
        next if !$d->{storage};
        return (0, "storage '$d->{storage}' is not available on $target")
            if !$snap->{storages}->{$d->{storage}}->{nodes}->{$target};
    }
    for my $br (@{$g->{bridges} // []}) {
        next if $n->{bridges}->{$br} || $snap->{vnets}->{$br};
        return (0, "bridge '$br' does not exist on $target");
    }
    if (($g->{cpu_type} // '') =~ /^(?:host|max)$/) {
        my $src = $snap->{nodes}->{$g->{node}};
        return (0, "CPU type '$g->{cpu_type}' and $target has a different CPU")
            if ($src->{cpu_flags} // '') ne ($n->{cpu_flags} // '') || ($src->{cpu_model} // '') ne ($n->{cpu_model} // '');
    }
    return (1);
}

# Memory on $target for $vmid, given the node's current load (footprint of
# its guests plus overhead) and the headroom setting.
sub fits {
    my ($snap, $settings, $load, $vmid, $target) = @_;
    my $n = $snap->{nodes}->{$target};
    my $need = PVE::WDCBalancer::Score::guest_footprint($snap->{guests}->{$vmid});
    my $limit = ($n->{maxmem} // 0) * (1 - ($settings->{headroom} // 10) / 100);
    return ($load->{foot} + $need) <= $limit;
}

1;
