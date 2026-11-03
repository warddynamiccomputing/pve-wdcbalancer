package RandomCluster;

# Random clusters and configs for the engine property and simulation tests.
#
#   my ($snap, $cfg) = random_cluster($seed);

use strict;
use warnings;

use Exporter 'import';
use Storable qw(dclone);

use SnapFixture;
use PVE::WDCBalancer::Config;

our @EXPORT_OK = qw(random_cluster pick);

my $C = 'PVE::WDCBalancer::Config';

sub pick { return $_[ int(rand(@_)) ]; }

sub random_cluster {
    my ($seed) = @_;
    srand($seed);
    my $s = SnapFixture->new;
    $s->{storages}->{other} = { shared => 1, nodes => {} };
    my @nodes = map { "n$_" } 1 .. 2 + int(rand(5));
    for my $n (@nodes) {
        my @st = ('local', rand() < 0.85 ? 'shared' : (), rand() < 0.5 ? 'other' : ());
        $s->node($n, cpus => pick(8, 16, 32, 96), mem => pick(32, 64, 128, 256),
            overhead_cpu => rand(2), overhead_mem => rand(4),
            cpu_flags => rand() < 0.8 ? 'fpu sse sse2' : 'fpu sse sse2 avx512',
            bridges => rand() < 0.9 ? ['vmbr0', 'vmbr1'] : ['vmbr0'],
            storages => \@st,
            online => rand() < 0.93 ? 1 : 0,
            maintenance => rand() < 0.08 ? 1 : 0,
            samples => rand() < 0.97 ? 5 : 0);
    }
    my @online = grep { $s->{nodes}->{$_}->{online} } @nodes;
    @online = ($nodes[0]) if !@online;
    $s->{nodes}->{$online[0]}->{online} = 1;
    my $vmid = 100;
    for (1 .. 3 + int(rand(28))) {
        $vmid++;
        my $n = pick(@online);
        my $vcpus = pick(1, 2, 4, 8);
        $s->guest($vmid, $n,
            vcpus => $vcpus, cpu => rand($vcpus), mem => pick(1, 2, 4, 8, 16),
            type => rand() < 0.15 ? 'lxc' : 'qemu',
            status => rand() < 0.9 ? 'running' : 'stopped',
            storage => rand() < 0.85 ? pick('shared', 'shared', 'other') : 'local',
            cpu_type => rand() < 0.15 ? 'host' : 'x86-64-v2-AES',
            bridges => [ rand() < 0.2 ? 'vmbr1' : 'vmbr0' ],
            devices => rand() < 0.05 ? ['hostpci0'] : [],
            lock => rand() < 0.05 ? 'backup' : undef,
            ha => rand() < 0.2 ? 1 : 0,
            samples => rand() < 0.95 ? 5 : 0,
            psi_cpu => rand() < 0.2 ? rand(30) : 0);
    }
    my @vms = sort { $a <=> $b } keys %{$s->{guests}};

    # rules, kept only if the config is valid (like the API would)
    my $cfg = { version => 1, settings => { threshold => 1 + int(rand(5)), max_moves => pick(2, 4, 8, 16),
        headroom => pick(0, 10, 20), cooldown => 0 }, vm_groups => {}, host_groups => {}, rules => {},
        overrides => {}, maintenance => {} };
    for my $i (1 .. int(rand(4))) {
        my $try = dclone($cfg);
        my $kind = pick('separate', 'together', 'vm-host');
        if ($kind eq 'vm-host') {
            $try->{vm_groups}->{"g$i"} = { members => [ map { pick(@vms) } 1 .. 1 + int(rand(3)) ] };
            $try->{host_groups}->{"h$i"} = { members => [ map { pick(@nodes) } 1 .. 1 + int(rand(2)) ] };
            $try->{rules}->{"r$i"} = { type => 'vm-host', vm_group => "g$i", host_group => "h$i",
                mode => pick(@PVE::WDCBalancer::Config::RULE_MODES) };
        } else {
            my %v = map { pick(@vms) => 1 } 1 .. 2 + int(rand(2));
            next if keys(%v) < 2;
            $try->{rules}->{"r$i"} = { type => $kind, vms => [ map { $_ + 0 } sort keys %v ] };
        }
        $cfg = $try if !@{ $C->can('validate')->($try) };
    }
    $cfg->{overrides}->{ pick(@vms) } = { automation => 'disabled' } if rand() < 0.2;
    return ($s->snap, $cfg);
}

1;
