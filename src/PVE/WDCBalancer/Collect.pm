package PVE::WDCBalancer::Collect;

# Builds the cluster snapshot the engine works on. Runs on any node: RRD
# files for every guest and node are on every node (rrdcached), guest
# configs are on pmxcfs, and per-node facts (CPU flags, bridges) come from
# the API, which proxies to the node.
#
# snapshot = {
#   time,
#   nodes    => { node => { online, maintenance, maxcpu, maxmem, cpu, mem,
#                           overhead_cpu, overhead_mem, netin, netout,
#                           psi_cpu, psi_mem, cpu_model, cpu_flags, bridges } },
#   guests   => { vmid => { vmid, name, type, node, status, template, lock, ha,
#                           maxcpu, cpu (cores), maxmem, mem, memhost, netin,
#                           netout, psi_cpu, psi_mem, disks, devices, bridges,
#                           cpu_type, samples } },
#   storages => { id => { shared, nodes => { node => 1 } } },
#   vnets    => { name => 1 },
#   ha_rules => [ { id, type, resources, nodes, strict, affinity } ],
#   crs      => { ha, auto_rebalance },
#   warnings => [ ... ],
# }
#
# Averages are over the last $window seconds of 1-minute RRD samples.

use strict;
use warnings;

use JSON::PP;
use List::Util qw(max sum0);

use POSIX ();

use PVE::Cluster;
use PVE::INotify;
use PVE::RRD;
use PVE::Tools;

use PVE::WDCBalancer::Config;

my $json = JSON::PP->new->allow_nonref;

# node facts that rarely change (CPU model and flags, bridges) are cached
our $FACTS_TTL = 900;

# Several 'pvesh get' calls at once (each one takes a second or two to
# start). { key => [ path, args... ] } -> { key => decoded result }; a call
# that fails or times out is missing from the result.
sub pvesh_parallel {
    my ($reqs) = @_;
    my %fh;
    for my $key (sort keys %$reqs) {
        my $pid = open(my $fh, '-|');
        next if !defined($pid);
        if (!$pid) {
            open(STDERR, '>', '/dev/null');
            exec('timeout', '60', 'pvesh', 'get', @{$reqs->{$key}}, '--output-format', 'json') or POSIX::_exit(1);
        }
        $fh{$key} = $fh;
    }
    my %res;
    for my $key (sort keys %fh) {
        my $out = do { local $/; readline($fh{$key}) };
        close($fh{$key});
        next if $? || !defined($out) || $out !~ /\S/;
        my $d = eval { $json->decode($out) };
        $res{$key} = $d if defined($d);
    }
    return \%res;
}

# mean of the last $window seconds of a 1-minute RRD series per field
sub rrd_average {
    my ($rows, $window, $now) = @_;
    my %sum;
    my %n;
    for my $row (@{$rows // []}) {
        next if !defined($row->{time}) || $row->{time} < $now - $window;
        for my $k (keys %$row) {
            next if $k eq 'time' || !defined($row->{$k});
            $sum{$k} += $row->{$k};
            $n{$k}++;
        }
    }
    my %avg = map { $_ => $sum{$_} / $n{$_} } keys %sum;
    $avg{_samples} = max(0, values %n);
    return \%avg;
}

sub rrd_rows {
    my ($name) = @_;
    return eval { PVE::RRD::create_rrd_data($name, 'hour', 'AVERAGE') } // [];
}

# ---------------- guest configs (pure) ----------------

my $DISK_KEY = qr/^(?:ide|sata|scsi|virtio|efidisk|tpmstate|unused)\d+$/;
my $CT_DISK_KEY = qr/^(?:rootfs|mp\d+)$/;

# Parses the current section of a qemu-server or lxc config.
sub parse_guest_config {
    my ($type, $raw) = @_;
    my %c;
    for my $line (split /\n/, $raw // '') {
        last if $line =~ /^\[/; # snapshot sections follow
        next if $line =~ /^\s*(?:#|$)/;
        my ($k, $v) = $line =~ /^([a-z][a-z0-9_.-]*):\s*(.*?)\s*$/ or next;
        $c{$k} = $v;
    }
    my (@disks, @devices, @bridges);
    for my $k (sort keys %c) {
        my $v = $c{$k};
        if (($type eq 'qemu' && $k =~ $DISK_KEY) || ($type eq 'lxc' && $k =~ $CT_DISK_KEY)) {
            next if $k =~ /^unused/; # not attached, moves with the guest config
            my ($vol) = split(/,/, $v);
            $vol =~ s/^volume=//;
            my $cdrom = $v =~ /(?:^|,)media=cdrom(?:,|$)/ ? 1 : 0;
            my ($storage) = $vol =~ /^([A-Za-z][A-Za-z0-9_.-]*):/;
            if ($cdrom && ($vol eq 'none' || $vol eq 'cdrom')) {
                push @disks, { key => $k, cdrom => 1 } if $vol eq 'none';
                push @disks, { key => $k } if $vol eq 'cdrom'; # host drive
                next;
            }
            push @disks, { key => $k, volid => $vol, $storage ? (storage => $storage) : (), $cdrom ? (cdrom => 1) : () };
        } elsif ($k =~ /^(?:hostpci|usb)\d+$/) {
            next if $k =~ /^usb/ && $v =~ /^(?:host=)?spice(?:,|$)/;
            push @devices, $k;
        } elsif ($type eq 'qemu' && $k =~ /^net\d+$/) {
            push @bridges, $1 if $v =~ /(?:^|,)bridge=([^,]+)/;
        } elsif ($type eq 'lxc' && $k =~ /^net\d+$/) {
            push @bridges, $1 if $v =~ /(?:^|,)bridge=([^,]+)/;
        } elsif ($type eq 'lxc' && $k eq 'lxc.mount.entry') {
            push @devices, $k;
        }
    }
    my $cpu_type = $c{cpu} // '';
    $cpu_type =~ s/^cputype=//;
    $cpu_type =~ s/,.*//;
    return {
        disks => \@disks,
        devices => \@devices,
        bridges => [ sort(keys %{{ map { $_ => 1 } @bridges }}) ],
        cpu_type => $cpu_type,
        lock => $c{lock},
        template => $c{template} ? 1 : 0,
        name => $c{name} // $c{hostname},
    };
}

# ---------------- snapshot ----------------

sub read_guest_configs {
    my %res;
    for my $file (glob('/etc/pve/nodes/*/qemu-server/*.conf'), glob('/etc/pve/nodes/*/lxc/*.conf')) {
        my ($node, $kind, $vmid) = $file =~ m{^/etc/pve/nodes/([^/]+)/(qemu-server|lxc)/(\d+)\.conf$} or next;
        my $type = $kind eq 'lxc' ? 'lxc' : 'qemu';
        my $raw = eval { PVE::Tools::file_get_contents($file) } // next;
        $res{$vmid} = { %{ parse_guest_config($type, $raw) }, node => $node, type => $type };
    }
    return \%res;
}

sub ha_rules {
    my $raw = eval { PVE::Tools::file_get_contents('/etc/pve/ha/rules.cfg') } // '';
    return parse_ha_rules($raw);
}

# /etc/pve/ha/rules.cfg (section config), only what the engine needs
sub parse_ha_rules {
    my ($raw) = @_;
    my (@rules, $cur);
    for my $line (split /\n/, $raw // '') {
        if ($line =~ /^([a-z-]+):\s*(\S+)\s*$/) {
            $cur = { type => $1, id => $2, resources => [], nodes => {}, strict => 0 };
            push @rules, $cur;
        } elsif ($cur && $line =~ /^\s+(\S+)\s+(.*?)\s*$/) {
            my ($k, $v) = ($1, $2);
            if ($k eq 'resources') {
                $cur->{resources} = [ map { /^(?:vm|ct):(\d+)$/ ? $1 : () } split(/,/, $v) ];
            } elsif ($k eq 'nodes') {
                for my $n (split /,/, $v) {
                    my ($name, $prio) = split(/:/, $n);
                    $cur->{nodes}->{$name} = $prio // 0;
                }
            } elsif ($k eq 'strict') {
                $cur->{strict} = $v ? 1 : 0;
            } elsif ($k eq 'affinity') {
                $cur->{affinity} = $v;
            } elsif ($k eq 'disable') {
                $cur->{disabled} = $v ? 1 : 0;
            } elsif ($k eq 'comment') {
                $cur->{comment} = $v;
            }
        }
    }
    return [ grep { !$_->{disabled} } @rules ];
}

sub crs_settings {
    my $dc = eval { PVE::Cluster::cfs_read_file('datacenter.cfg') } // {};
    my $crs = $dc->{crs} // {};
    return { ha => $crs->{ha} // 'basic', auto_rebalance => $crs->{'ha-auto-rebalance'} ? 1 : 0 };
}

# nodes in maintenance: ours (config) and the HA manager's
sub ha_maintenance {
    my $ms = eval { $json->decode(PVE::Tools::file_get_contents('/etc/pve/ha/manager_status')) } // {};
    my %m;
    for my $node (keys %{$ms->{node_status} // {}}) {
        $m{$node} = 1 if ($ms->{node_status}->{$node} // '') eq 'maintenance';
    }
    return \%m;
}

sub snapshot {
    my (%opts) = @_;
    my $window = $opts{window} // 300;
    my $now = time();
    my $cfg = $opts{config} // {};
    my @warnings;

    # one parallel batch: cluster resources, SDN vnets and the facts of
    # online nodes whose cached facts are stale
    my $facts_file = "$PVE::WDCBalancer::Config::DIR/nodefacts.json";
    my $facts = eval { $json->decode(PVE::Tools::file_get_contents($facts_file)) } // {};
    eval { PVE::Cluster::cfs_update() };
    my $members = PVE::Cluster::get_members() // {};
    my @members = grep { $members->{$_}->{online} } sort keys %$members;
    my $stale = sub { return grep { $now - ($facts->{$_}->{time} // 0) > $FACTS_TTL } @_; };

    my %reqs = (resources => ['/cluster/resources'], vnets => ['/cluster/sdn/vnets']);
    my $add_facts = sub {
        for my $node (@_) {
            $reqs{"status:$node"} = ["/nodes/$node/status"];
            $reqs{"network:$node"} = ["/nodes/$node/network", '--type', 'any_bridge'];
        }
    };
    my @refresh = $stale->(@members);
    $add_facts->(@refresh);
    my $got = pvesh_parallel(\%reqs);
    my $resources = $got->{resources} // die "cluster resources not available\n";

    # nodes the membership list didn't name (it can be empty outside the daemons)
    my %seen = map { $_ => 1 } @members;
    my @more = $stale->(grep { !$seen{$_} } map { $_->{node} }
        grep { ($_->{type} // '') eq 'node' && ($_->{status} // '') eq 'online' } @$resources);
    if (@more) {
        %reqs = ();
        $add_facts->(@more);
        $got = { %$got, %{ pvesh_parallel(\%reqs) } };
        push @refresh, @more;
    }

    for my $node (@refresh) {
        my ($st, $net) = ($got->{"status:$node"}, $got->{"network:$node"});
        next if !$st || !$net;
        $facts->{$node} = {
            time => $now,
            cpu_model => $st->{cpuinfo}->{model} // '',
            cpu_flags => join(' ', sort split(/\s+/, $st->{cpuinfo}->{flags} // '')),
            bridges => [ sort map { $_->{iface} } @$net ],
        };
    }
    eval { PVE::Tools::file_set_contents($facts_file, $json->canonical->encode($facts)) } if @refresh && -d $PVE::WDCBalancer::Config::DIR;
    my %nodes;
    my %guests;
    my %storages;

    my $ha_maint = ha_maintenance();
    for my $r (grep { ($_->{type} // '') eq 'node' } @$resources) {
        my $node = $r->{node};
        my $avg = rrd_average(rrd_rows("pve-node-9.0/$node"), $window, $now);
        my $maxcpu = $r->{maxcpu} || $avg->{maxcpu} || 0;
        # ZFS ARC is reclaimable; don't count it as used memory
        my $memused = ($avg->{memused} // $r->{mem} // 0) - ($avg->{arcsize} // 0);
        $nodes{$node} = {
            online => ($r->{status} // '') eq 'online' ? 1 : 0,
            maintenance => ($cfg->{maintenance}->{$node} || $ha_maint->{$node}) ? 1 : 0,
            maxcpu => $maxcpu,
            maxmem => $r->{maxmem} || $avg->{memtotal} || 0,
            cpu => ($avg->{cpu} // $r->{cpu} // 0) * $maxcpu,
            mem => max(0, $memused),
            netin => $avg->{netin} // 0,
            netout => $avg->{netout} // 0,
            psi_cpu => $avg->{pressurecpusome} // 0,
            psi_mem => $avg->{pressurememoryfull} // 0,
            bridges => {},
            samples => $avg->{_samples},
        };
    }

    for my $r (grep { ($_->{type} // '') eq 'storage' } @$resources) {
        my $s = $storages{$r->{storage}} //= { shared => $r->{shared} ? 1 : 0, nodes => {} };
        $s->{shared} ||= $r->{shared} ? 1 : 0;
        $s->{nodes}->{$r->{node}} = 1 if ($r->{status} // '') eq 'available';
    }

    my $configs = read_guest_configs();
    for my $r (grep { ($_->{type} // '') =~ /^(?:qemu|lxc)$/ } @$resources) {
        my $vmid = $r->{vmid};
        my $c = $configs->{$vmid} // {};
        my $type = $r->{type};
        my $g = {
            vmid => $vmid,
            name => $r->{name} // $c->{name} // '',
            type => $type,
            node => $r->{node},
            status => $r->{status} // 'unknown',
            template => $r->{template} ? 1 : ($c->{template} // 0),
            lock => $r->{lock} // $c->{lock},
            ha => defined($r->{hastate}) ? 1 : 0,
            maxcpu => $r->{maxcpu} // 0,
            maxmem => $r->{maxmem} // 0,
            disks => $c->{disks} // [],
            devices => $c->{devices} // [],
            bridges => $c->{bridges} // [],
            cpu_type => $c->{cpu_type} // '',
        };
        if ($g->{status} eq 'running') {
            my $avg = rrd_average(rrd_rows("pve-vm-9.0/$vmid"), $window, $now);
            my $maxcpu = $avg->{maxcpu} || $g->{maxcpu} || 0;
            $g->{cpu} = ($avg->{cpu} // $r->{cpu} // 0) * $maxcpu;
            $g->{mem} = $avg->{mem} // $r->{mem} // 0;
            $g->{memhost} = $avg->{memhost} // $r->{memhost} // $g->{mem};
            $g->{netin} = $avg->{netin} // 0;
            $g->{netout} = $avg->{netout} // 0;
            $g->{psi_cpu} = $avg->{pressurecpusome} // 0;
            $g->{psi_mem} = $avg->{pressurememoryfull} // 0;
            $g->{samples} = $avg->{_samples};
            push @warnings, "guest $vmid: no usage samples yet" if !$avg->{_samples};
        }
        $guests{$vmid} = $g;
    }

    # node overhead: usage its running guests don't explain
    for my $node (keys %nodes) {
        my @here = grep { $_->{node} eq $node && $_->{status} eq 'running' } values %guests;
        my $n = $nodes{$node};
        $n->{overhead_cpu} = max(0, $n->{cpu} - sum0(map { $_->{cpu} // 0 } @here));
        $n->{overhead_mem} = max(0, $n->{mem} - sum0(map { $_->{memhost} // 0 } @here));
    }

    for my $node (grep { $nodes{$_}->{online} } sort keys %nodes) {
        my $f = $facts->{$node};
        if (!$f) {
            push @warnings, "node $node: CPU and network facts not available";
            next;
        }
        my $n = $nodes{$node};
        $n->{cpu_model} = $f->{cpu_model};
        $n->{cpu_flags} = $f->{cpu_flags};
        $n->{bridges} = { map { $_ => 1 } @{$f->{bridges} // []} };
    }

    my $vnets = $got->{vnets} // [];

    return {
        time => $now,
        window => $window,
        nodes => \%nodes,
        guests => \%guests,
        storages => \%storages,
        vnets => { map { $_->{vnet} => 1 } grep { $_->{vnet} } @$vnets },
        ha_rules => ha_rules(),
        crs => crs_settings(),
        warnings => \@warnings,
    };
}

1;
