package SnapFixture;

# Builds cluster snapshots (the shape PVE::WDCBalancer::Collect returns)
# for the engine tests.
#
#   my $s = SnapFixture->new;
#   $s->node('n1', cpus => 32, mem => 256);              # mem in GiB
#   $s->guest(101, 'n1', cpu => 4, mem => 16, vcpus => 8); # cpu in cores used
#   my $snap = $s->snap;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(GiB);

sub GiB { return $_[0] * 1024 ** 3; }

sub new {
    my ($class) = @_;
    return bless {
        nodes => {}, guests => {},
        storages => { shared => { shared => 1, nodes => {} }, local => { shared => 0, nodes => {} } },
        vnets => {}, ha_rules => [], crs => { ha => 'basic', auto_rebalance => 0 }, warnings => [],
    }, $class;
}

sub node {
    my ($self, $name, %o) = @_;
    $self->{nodes}->{$name} = {
        online => $o{online} // 1,
        maintenance => $o{maintenance} // 0,
        maxcpu => $o{cpus} // 32,
        maxmem => GiB($o{mem} // 256),
        overhead_cpu => $o{overhead_cpu} // 0,
        overhead_mem => GiB($o{overhead_mem} // 0),
        cpu_model => $o{cpu_model} // 'Test CPU',
        cpu_flags => $o{cpu_flags} // 'fpu sse sse2',
        bridges => { map { $_ => 1 } @{ $o{bridges} // ['vmbr0'] } },
        samples => $o{samples} // 5,
    };
    for my $st (@{ $o{storages} // [qw(shared local)] }) {
        $self->{storages}->{$st}->{nodes}->{$name} = 1;
    }
    return $self;
}

sub guest {
    my ($self, $vmid, $node, %o) = @_;
    my $mem = GiB($o{mem} // 4);
    $self->{guests}->{$vmid} = {
        vmid => $vmid,
        name => $o{name} // "vm$vmid",
        type => $o{type} // 'qemu',
        node => $node,
        status => $o{status} // 'running',
        template => 0,
        lock => $o{lock},
        ha => $o{ha} // 0,
        maxcpu => $o{vcpus} // 4,
        maxmem => GiB($o{maxmem} // ($o{mem} // 4)),
        cpu => $o{cpu} // 0.5,
        mem => $mem,
        memhost => $o{memhost} ? GiB($o{memhost}) : $mem,
        netin => $o{netin} // 0,
        netout => $o{netout} // 0,
        psi_cpu => $o{psi_cpu} // 0,
        psi_mem => $o{psi_mem} // 0,
        disks => $o{disks} // [ { key => 'scsi0', storage => $o{storage} // 'shared', volid => "x:vm-$vmid-disk-0" } ],
        devices => $o{devices} // [],
        bridges => $o{bridges} // ['vmbr0'],
        cpu_type => $o{cpu_type} // 'x86-64-v2-AES',
        samples => $o{samples} // 5,
    };
    return $self;
}

sub snap {
    my ($self) = @_;
    my %copy = %$self;
    return \%copy;
}

1;
