use strict;
use warnings;

use Test::More;

use StubPVE;
use PVE::WDCBalancer::Collect;
use PVE::WDCBalancer::Config;

my $parse = PVE::WDCBalancer::Collect->can('parse_guest_config');

# ---------------- qemu config ----------------
{
    my $c = $parse->('qemu', <<'EOF');
boot: order=scsi0
cores: 4
cpu: host,flags=+aes
ide2: local:iso/debian.iso,media=cdrom,size=600M
memory: 8192
name: web01
net0: virtio=BC:24:11:00:00:01,bridge=vmbr0,firewall=1
net1: virtio=BC:24:11:00:00:02,bridge=vnet10
scsi0: san1:vm-101-disk-0,iothread=1,size=32G
scsi1: /dev/disk/by-id/ata-SOMETHING,size=100G
efidisk0: san1:vm-101-disk-1,efitype=4m,size=4M
unused0: local-lvm:vm-101-disk-9
hostpci0: 0000:3b:00.0,pcie=1
usb0: spice
usb1: host=1234:5678
lock: backup

[snap1]
scsi7: other:vm-101-disk-7
EOF
    my %d = map { $_->{key} => $_ } @{$c->{disks}};
    is($d{scsi0}->{storage}, 'san1', 'disk storage');
    is($d{efidisk0}->{storage}, 'san1', 'efi disk');
    ok(!$d{scsi1}->{storage}, 'host device has no storage');
    is($d{ide2}->{storage}, 'local', 'ISO on local storage counts');
    ok($d{ide2}->{cdrom}, '... as a CD-ROM');
    ok(!$d{unused0}, 'unused disks are not attached');
    ok(!$d{scsi7}, 'snapshot sections are ignored');
    is_deeply($c->{devices}, ['hostpci0', 'usb1'], 'passthrough devices (SPICE USB is fine)');
    is_deeply($c->{bridges}, ['vmbr0', 'vnet10'], 'bridges');
    is($c->{cpu_type}, 'host', 'cpu type');
    is($c->{lock}, 'backup', 'lock');
    is($c->{name}, 'web01', 'name');

    my $e = $parse->('qemu', "ide2: none,media=cdrom\nide0: cdrom,media=cdrom\ncpu: cputype=x86-64-v3\n");
    my %e = map { $_->{key} => $_ } @{$e->{disks}};
    ok($e{ide2}->{cdrom} && !$e{ide2}->{storage}, 'empty CD drive');
    ok(!$e{ide0}->{storage} && !$e{ide0}->{cdrom}, 'host CD drive blocks migration');
    is($e->{cpu_type}, 'x86-64-v3', 'cputype= prefix');
}

# ---------------- lxc config ----------------
{
    my $c = $parse->('lxc', <<'EOF');
hostname: ct01
rootfs: san1:vm-200-disk-0,size=8G
mp0: san1:vm-200-disk-1,mp=/data,size=10G
mp1: /srv/host,mp=/host
net0: name=eth0,bridge=vmbr1,ip=dhcp
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF
    my %d = map { $_->{key} => $_ } @{$c->{disks}};
    is($d{rootfs}->{storage}, 'san1', 'rootfs');
    is($d{mp0}->{storage}, 'san1', 'volume mount point');
    ok(!$d{mp1}->{storage}, 'bind mount has no storage');
    is_deeply($c->{bridges}, ['vmbr1'], 'container bridge');
    is_deeply($c->{devices}, ['lxc.mount.entry'], 'raw lxc mounts block migration');
    is($c->{name}, 'ct01', 'hostname as name');
}

# ---------------- HA rules ----------------
{
    my $rules = PVE::WDCBalancer::Collect->can('parse_ha_rules')->(<<'EOF');
node-affinity: pin-db
	nodes n1:2,n2
	resources vm:101,ct:200
	strict 1

resource-affinity: apart
	affinity negative
	resources vm:101,vm:102

node-affinity: off
	disable 1
	nodes n3
	resources vm:103
EOF
    is(scalar(@$rules), 2, 'disabled rules dropped');
    is_deeply($rules->[0], { type => 'node-affinity', id => 'pin-db', resources => [101, 200], nodes => { n1 => 2, n2 => 0 }, strict => 1 },
        'node-affinity rule');
    is($rules->[1]->{affinity}, 'negative', 'resource-affinity rule');
}

# ---------------- RRD averages ----------------
{
    my $now = 10_000;
    my $rows = [
        { time => $now - 600, cpu => 0.9, mem => 100 },
        { time => $now - 240, cpu => 0.2, mem => 10 },
        { time => $now - 180, cpu => 0.4, mem => undef },
        { time => $now - 120, cpu => 0.6, mem => 30 },
    ];
    my $avg = PVE::WDCBalancer::Collect->can('rrd_average')->($rows, 300, $now);
    is(sprintf('%.2f', $avg->{cpu}), '0.40', 'average over the window only');
    is($avg->{mem}, 20, 'missing samples skipped');
    is($avg->{_samples}, 3, 'sample count');
    is(PVE::WDCBalancer::Collect->can('rrd_average')->([], 300, $now)->{_samples}, 0, 'no data');
}

# ---------------- settings ----------------
{
    my $C = 'PVE::WDCBalancer::Config';
    is($C->can('settings')->({ settings => { threshold => 4, junk => 1 } })->{threshold}, 4, 'setting read');
    ok(!exists($C->can('settings')->({ settings => { junk => 1 } })->{junk}), 'unknown settings dropped');
    is($C->can('settings')->({})->{interval}, 300, 'defaults: 5-minute passes like DRS');
    is($C->can('check_setting')->('network_aware', '1'), 1, 'boolean');
    ok(!eval { $C->can('check_setting')->('headroom', 'lots'); 1 }, 'number required');
    is($C->can('automation_for')->({ settings => {}, overrides => { 101 => { automation => 'disabled' } } }, 101), 'disabled', 'override');
    is($C->can('automation_for')->({ settings => {}, overrides => {} }, 102), 'manual', 'cluster default');
}

done_testing();
