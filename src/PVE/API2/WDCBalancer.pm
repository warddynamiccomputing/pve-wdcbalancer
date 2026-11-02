package PVE::API2::WDCBalancer;

# REST API: /nodes/{node}/wdcbalancer
#
# Everything here is cluster-wide: the configuration and the last pass are
# on pmxcfs, so any node answers. Passes and placement checks run on the
# addressed node.

use strict;
use warnings;

use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;
use PVE::RESTHandler;

use PVE::WDCBalancer::Collect;
use PVE::WDCBalancer::Config;
use PVE::WDCBalancer::Engine;
use PVE::WDCBalancer::HARules;
use PVE::WDCBalancer::Operations;
use PVE::WDCBalancer::State;

use base qw(PVE::RESTHandler);

our $VERSION = '0.4.0';

my $PERM_AUDIT = ['perm', '/', ['Sys.Audit']];
my $PERM_MODIFY = ['perm', '/', ['Sys.Modify']];

my $node_opt = get_standard_option('pve-node');
my $vmid_opt = get_standard_option('pve-vmid');
my $name_opt = {
    description => "Name (letters, digits, '_', '.', '-'; starts with a letter).",
    type => 'string',
    pattern => '[A-Za-z][A-Za-z0-9_.-]{0,63}',
};
my $comment_opt = { description => 'Comment.', type => 'string', maxLength => 512, optional => 1 };

my $register = sub {
    my ($def) = @_;
    $def->{protected} //= 1; # RRD files and pmxcfs writes need root
    __PACKAGE__->register_method($def);
};

my $user = sub { return PVE::RPCEnvironment::get()->get_user(); };

my $list = sub {
    my ($v) = @_;
    return [ grep { length } split(/[\s,;]+/, $v // '') ];
};

my $result = sub { return PVE::WDCBalancer::State::read_state()->{result} // {}; };

# mirror rule changes into HA rules right away (the timer also does it each pass)
my $ha_sync = sub {
    my $r = eval { PVE::WDCBalancer::HARules::sync(PVE::WDCBalancer::Config::load()) };
    warn "wdcbalancer: HA rule sync failed: $@" if $@;
    warn "wdcbalancer: $_
" for @{$r->{errors} // []};
};

$register->({
    name => 'index',
    path => '',
    method => 'GET',
    description => "Load balancing index.",
    protected => 0,
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'array', items => { type => 'object', properties => { name => { type => 'string' } } } },
    code => sub {
        return [ map { { name => $_ } } qw(apply dismiss explain faults groups guests ha-sync history maintenance overrides placement poweron recommendations resume rules run settings status timer-run) ];
    },
});

$register->({
    name => 'status',
    path => 'status',
    method => 'GET',
    description => "Cluster balance: scores, node load, last pass.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'object' },
    code => sub {
        my $state = PVE::WDCBalancer::State::read_state();
        my $cfg = PVE::WDCBalancer::Config::load();
        my $settings = PVE::WDCBalancer::Config::settings($cfg);
        my $res = $state->{result} // {};
        my $lease = PVE::WDCBalancer::State::read_json('lease.json') // {};
        return {
            version => $VERSION,
            time => $state->{time},
            node => $state->{node},
            duration => $state->{duration},
            trigger => $state->{trigger},
            leader => $lease->{node},
            next => defined($state->{time}) ? $state->{time} + $settings->{interval} : undef,
            settings => $settings,
            cluster => $res->{cluster} // {},
            nodes => [ map { $res->{nodes}->{$_} } sort keys %{$res->{nodes} // {}} ],
            recommendations => scalar(@{$res->{recommendations} // []}),
            faults => scalar(@{$res->{faults} // []}),
            applying => PVE::WDCBalancer::State::apply_running($state) ? $state->{applying} : undef,
            breaker => $state->{breaker},
        };
    },
});

$register->({
    name => 'recommendations',
    path => 'recommendations',
    method => 'GET',
    description => "Recommendations of the last pass, in the order they would be applied.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                id => { type => 'string' },
                vmid => { type => 'integer' },
                name => { type => 'string', optional => 1 },
                type => { type => 'string' },
                from => { type => 'string' },
                to => { type => 'string' },
                priority => { type => 'integer', description => '1 (mandatory) to 5.' },
                kind => { type => 'string', description => 'maintenance, rule or balance.' },
                reason => { type => 'string' },
                gain => { type => 'number', description => 'Expected change of the cluster objective.' },
                ha => { type => 'boolean' },
                restart => { type => 'boolean', description => 'Containers are moved with a restart.' },
                rule => { type => 'string', optional => 1 },
            },
        },
    },
    code => sub { return $result->()->{recommendations} // []; },
});

$register->({
    name => 'dismiss',
    path => 'dismiss',
    method => 'POST',
    description => "Dismiss a recommendation; the same move isn't recommended again for an hour.",
    permissions => { check => $PERM_MODIFY },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            id => { type => 'string', pattern => '\d+:[A-Za-z0-9.-]+:[A-Za-z0-9.-]+', description => 'Recommendation ID.' },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;
        PVE::WDCBalancer::State::dismiss($param->{id}, $user->());
        return undef;
    },
});

$register->({
    name => 'apply',
    path => 'apply',
    method => 'POST',
    description => "Apply recommendations (all, or the listed ones) in a task: live migration for VMs,"
        . " restart migration for containers, HA migration for HA guests.",
    permissions => {
        description => "Sys.Modify on / and VM.Migrate on every guest that is moved.",
        check => $PERM_MODIFY,
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            ids => { type => 'string', optional => 1, maxLength => 65536,
                description => 'Recommendation IDs, comma separated (default: all).' },
        },
    },
    returns => { type => 'string', description => 'Task ID.' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment::get();
        my $user = $rpcenv->get_user();
        my $state = PVE::WDCBalancer::State::read_state();
        die "Proxmox CRS automatic rebalancing (ha-auto-rebalance) is on; turn it off first, two balancers would compete\n"
            if $state->{result}->{cluster}->{crs_conflict};
        die "another apply task is running\n" if PVE::WDCBalancer::State::apply_running($state);
        die "the cluster is not quorate\n" if ($state->{result}->{cluster}->{quorate} // 1) == 0;
        my $recs = PVE::WDCBalancer::State::pick(defined($param->{ids}) ? $list->($param->{ids}) : undef);
        die "no recommendations to apply\n" if !@$recs;
        $rpcenv->check($user, "/vms/$_->{vmid}", ['VM.Migrate']) for @$recs;
        return $rpcenv->fork_worker('wdcbapply', undef, $user, sub {
            PVE::WDCBalancer::State::apply($recs, trigger => $user);
        });
    },
});

# ---------------- maintenance mode ----------------

my $host_opt = { %{ get_standard_option('pve-node') }, description => 'The node to put into or take out of maintenance mode.' };

$register->({
    name => 'maintenance',
    path => 'maintenance',
    method => 'GET',
    description => "Maintenance mode of every node, with the guests that keep a node from being empty.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'array', items => { type => 'object' } },
    code => sub {
        my $state = PVE::WDCBalancer::State::read_state();
        my $cfg = PVE::WDCBalancer::Config::load();
        my $guests = $state->{result}->{guests} // {};
        my @res;
        for my $n (sort keys %{$state->{result}->{nodes} // {}}) {
            my $m = $cfg->{maintenance}->{$n};
            my @running = grep { ($_->{node} // '') eq $n && ($_->{status} // '') eq 'running' } values %$guests;
            push @res, {
                node => $n,
                maintenance => $m ? 1 : 0,
                $m ? (since => $m->{since}, user => $m->{user}) : (),
                running => scalar(@running),
                blocked => join(', ', map { "$_->{vmid}" . ($_->{reason} ? " ($_->{reason})" : '') }
                    sort { $a->{vmid} <=> $b->{vmid} } grep { !$_->{movable} } @running),
                state => !$m ? 'online' : @running ? 'entering maintenance' : 'in maintenance',
            };
        }
        return \@res;
    },
});

$register->({
    name => 'maintenance_enter',
    path => 'maintenance/{host}/enter',
    method => 'POST',
    description => "Enter maintenance mode (in a task): move the running guests off the node (HA guests through"
        . " HA node maintenance), optionally the stopped ones too.",
    permissions => {
        description => "Sys.Modify on / and VM.Migrate on /vms.",
        check => ['and', $PERM_MODIFY, ['perm', '/vms', ['VM.Migrate']]],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            host => $host_opt,
            'move-stopped' => { type => 'boolean', optional => 1, default => 0,
                description => 'Also move powered-off guests (offline; on shared storage only their config moves).' },
        },
    },
    returns => { type => 'string', description => 'Task ID.' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment::get();
        my $user = $rpcenv->get_user();
        return $rpcenv->fork_worker('wdcbmaint', $param->{host}, $user, sub {
            PVE::WDCBalancer::Operations::enter_maintenance($param->{host}, user => $user,
                move_stopped => $param->{'move-stopped'});
        });
    },
});

$register->({
    name => 'maintenance_exit',
    path => 'maintenance/{host}/exit',
    method => 'POST',
    description => "Exit maintenance mode.",
    permissions => { check => $PERM_MODIFY },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, host => $host_opt } },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;
        PVE::WDCBalancer::Operations::exit_maintenance($param->{host}, user => $user->());
        return undef;
    },
});

# ---------------- initial placement ----------------

my $vmids_opt = { type => 'string', format => 'pve-vmid-list', description => 'Guest IDs, comma separated.' };

$register->({
    name => 'placement',
    path => 'placement',
    method => 'GET',
    description => "Where stopped guests would be started (initial placement), without doing anything.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, vmids => $vmids_opt } },
    returns => { type => 'array', items => { type => 'object' } },
    code => sub {
        my ($param) = @_;
        return PVE::WDCBalancer::Operations::placement($list->($param->{vmids}));
    },
});

$register->({
    name => 'poweron',
    path => 'poweron',
    method => 'POST',
    description => "Power On (balanced): start stopped guests on the best node, moving them there offline first."
        . " HA guests are started through HA.",
    permissions => {
        description => "VM.PowerMgmt and VM.Migrate on every guest.",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            vmids => $vmids_opt,
            target => { %{ get_standard_option('pve-node') }, optional => 1,
                description => 'Start the (single) guest on this node instead of the recommended one.' },
        },
    },
    returns => { type => 'string', description => 'Task ID.' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment::get();
        my $u = $rpcenv->get_user();
        my $ids = $list->($param->{vmids});
        $rpcenv->check($u, "/vms/$_", ['VM.PowerMgmt', 'VM.Migrate']) for @$ids;
        return $rpcenv->fork_worker('wdcbpoweron', undef, $u, sub {
            PVE::WDCBalancer::Operations::power_on($ids, user => $u, target => $param->{target});
        });
    },
});

$register->({
    name => 'ha_sync',
    path => 'ha-sync',
    method => 'POST',
    description => "Bring the HA rules mirrored from our rules in line now (the timer does it every pass).",
    permissions => { check => $PERM_MODIFY },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'object' },
    code => sub { return PVE::WDCBalancer::HARules::sync(PVE::WDCBalancer::Config::load()); },
});

$register->({
    name => 'run',
    path => 'run',
    method => 'POST',
    description => "Run a balancing pass now (Run DRS now). Moves are only made by apply, or by the timer with full automation.",
    permissions => { check => $PERM_MODIFY },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'object' },
    code => sub {
        my $state = PVE::WDCBalancer::State::run_pass(trigger => 'manual: ' . $user->());
        my $res = $state->{result};
        return {
            time => $state->{time},
            duration => $state->{duration},
            cluster => $res->{cluster},
            recommendations => scalar(@{$res->{recommendations}}),
            faults => scalar(@{$res->{faults}}),
        };
    },
});

$register->({
    name => 'resume',
    path => 'resume',
    method => 'POST',
    description => "Resume automation after the circuit breaker paused it (too many failed moves).",
    permissions => { check => $PERM_MODIFY },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'object', properties => { resumed => { type => 'boolean' } } },
    code => sub { return { resumed => PVE::WDCBalancer::State::breaker_reset($user->()) ? 1 : 0 }; },
});

$register->({
    name => 'timer_run',
    path => 'timer-run',
    method => 'POST',
    description => "Timer entry point: the node holding the lease runs a pass when the interval is up.",
    permissions => { check => $PERM_MODIFY },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'object' },
    code => sub { return PVE::WDCBalancer::State::timer_run(); },
});

$register->({
    name => 'guests',
    path => 'guests',
    method => 'GET',
    description => "Guests with their VM score, demand and whether they can be moved.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'array', items => { type => 'object' } },
    code => sub {
        my $g = $result->()->{guests} // {};
        return [ map { $g->{$_} } sort { $a <=> $b } keys %$g ];
    },
});

$register->({
    name => 'faults',
    path => 'faults',
    method => 'GET',
    description => "Faults of the last pass: rule violations that can't be fixed, conflicts, data problems.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'array', items => { type => 'object' } },
    code => sub { return $result->()->{faults} // []; },
});

$register->({
    name => 'history',
    path => 'history',
    method => 'GET',
    description => "Event history, newest first.",
    permissions => { check => $PERM_AUDIT },
    parameters => {
        additionalProperties => 0,
        properties => { node => $node_opt, limit => { type => 'integer', minimum => 1, maximum => 500, optional => 1, default => 100 } },
    },
    returns => { type => 'array', items => { type => 'object' } },
    code => sub {
        my ($param) = @_;
        my @h = reverse @{ PVE::WDCBalancer::State::history() };
        splice(@h, $param->{limit} // 100) if @h > ($param->{limit} // 100);
        return \@h;
    },
});

$register->({
    name => 'explain',
    path => 'explain',
    method => 'GET',
    description => "Where a guest could run: per node whether it may, why not, and the VM score it would get.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, vmid => $vmid_opt } },
    returns => { type => 'array', items => { type => 'object' } },
    code => sub {
        my ($param) = @_;
        my $cfg = PVE::WDCBalancer::Config::load();
        my $settings = PVE::WDCBalancer::Config::settings($cfg);
        my $snap = PVE::WDCBalancer::Collect::snapshot(window => $settings->{interval}, config => $cfg);
        return PVE::WDCBalancer::Engine::explain($snap, $cfg, $param->{vmid});
    },
});

# ---------------- settings ----------------

my $settings_props = {
    map {
        my $d = $PVE::WDCBalancer::Config::SETTINGS->{$_};
        my $c = $d->[1];
        ($_ => {
            description => $d->[2],
            optional => 1,
            $c->{enum} ? (type => 'string', enum => $c->{enum})
                : $c->{bool} ? (type => 'boolean')
                : (type => 'number', minimum => $c->{min}, maximum => $c->{max}),
        });
    } keys %$PVE::WDCBalancer::Config::SETTINGS
};

$register->({
    name => 'settings_get',
    path => 'settings',
    method => 'GET',
    description => "Balancer settings (with defaults).",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'object', properties => { map { ($_ => { %{$settings_props->{$_}} }) } keys %$settings_props } },
    code => sub { return PVE::WDCBalancer::Config::settings(PVE::WDCBalancer::Config::load()); },
});

$register->({
    name => 'settings_set',
    path => 'settings',
    method => 'PUT',
    description => "Change balancer settings.",
    permissions => { check => $PERM_MODIFY },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            %$settings_props,
            delete => { type => 'string', optional => 1, description => 'Settings to reset to their default.' },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;
        PVE::WDCBalancer::Config::update(sub {
            my ($cfg) = @_;
            for my $k (keys %$PVE::WDCBalancer::Config::SETTINGS) {
                next if !defined($param->{$k});
                $cfg->{settings}->{$k} = PVE::WDCBalancer::Config::check_setting($k, $param->{$k});
            }
            for my $k (@{ $list->($param->{delete}) }) {
                die "unknown setting '$k'\n" if !$PVE::WDCBalancer::Config::SETTINGS->{$k};
                delete $cfg->{settings}->{$k};
            }
        });
        return undef;
    },
});

# ---------------- groups ----------------

my $group_kind = { type => 'string', enum => ['vm', 'host'], description => 'VM group or host group.' };
my $members_opt = { type => 'string', maxLength => 65536, description => 'Members: VM IDs or node names, comma separated.' };

my $find_group = sub {
    my ($cfg, $name) = @_;
    return ('vm_groups', $cfg->{vm_groups}->{$name}) if $cfg->{vm_groups}->{$name};
    return ('host_groups', $cfg->{host_groups}->{$name}) if $cfg->{host_groups}->{$name};
    die "no group '$name'\n";
};

my $members = sub {
    my ($kind, $v) = @_;
    my $m = $list->($v);
    return $kind eq 'vm' ? [ map { $_ =~ /^\d+$/ ? $_ + 0 : $_ } @$m ] : $m;
};

$register->({
    name => 'groups',
    path => 'groups',
    method => 'GET',
    description => "VM groups and host groups.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'array', items => { type => 'object' } },
    code => sub {
        my $cfg = PVE::WDCBalancer::Config::load();
        my @res;
        for my $kind (qw(vm host)) {
            my $g = $cfg->{"${kind}_groups"};
            push @res, map { { name => $_, kind => $kind, members => $g->{$_}->{members}, comment => $g->{$_}->{comment} // '' } }
                sort keys %$g;
        }
        return \@res;
    },
});

$register->({
    name => 'group_create',
    path => 'groups',
    method => 'POST',
    description => "Create a VM group or host group.",
    permissions => { check => $PERM_MODIFY },
    parameters => {
        additionalProperties => 0,
        properties => { node => $node_opt, name => $name_opt, kind => $group_kind, members => $members_opt, comment => $comment_opt },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;
        PVE::WDCBalancer::Config::update(sub {
            my ($cfg) = @_;
            die "'$param->{name}' already exists\n" if $cfg->{vm_groups}->{$param->{name}} || $cfg->{host_groups}->{$param->{name}};
            $cfg->{"$param->{kind}_groups"}->{$param->{name}} = {
                members => $members->($param->{kind}, $param->{members}),
                defined($param->{comment}) ? (comment => $param->{comment}) : (),
            };
        });
        $ha_sync->();
        return undef;
    },
});

$register->({
    name => 'group_update',
    path => 'groups/{name}',
    method => 'PUT',
    description => "Change a group's members or comment.",
    permissions => { check => $PERM_MODIFY },
    parameters => {
        additionalProperties => 0,
        properties => { node => $node_opt, name => $name_opt, members => { %$members_opt, optional => 1 }, comment => $comment_opt },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;
        PVE::WDCBalancer::Config::update(sub {
            my ($cfg) = @_;
            my ($k, $g) = $find_group->($cfg, $param->{name});
            $g->{members} = $members->($k eq 'vm_groups' ? 'vm' : 'host', $param->{members}) if defined($param->{members});
            $g->{comment} = $param->{comment} if defined($param->{comment});
        });
        $ha_sync->();
        return undef;
    },
});

$register->({
    name => 'group_delete',
    path => 'groups/{name}',
    method => 'DELETE',
    description => "Delete a group that no rule uses.",
    permissions => { check => $PERM_MODIFY },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, name => $name_opt } },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;
        PVE::WDCBalancer::Config::update(sub {
            my ($cfg) = @_;
            my ($k) = $find_group->($cfg, $param->{name});
            my @users = grep { ($cfg->{rules}->{$_}->{vm_group} // '') eq $param->{name}
                || ($cfg->{rules}->{$_}->{host_group} // '') eq $param->{name} } sort keys %{$cfg->{rules}};
            die "group '$param->{name}' is used by rule(s) @users\n" if @users;
            delete $cfg->{$k}->{$param->{name}};
        });
        $ha_sync->();
        return undef;
    },
});

# ---------------- rules ----------------

my $rule_props = {
    type => { type => 'string', enum => [ @PVE::WDCBalancer::Config::RULE_TYPES ],
        description => 'together (keep VMs together), separate (keep VMs apart) or vm-host.' },
    vms => { type => 'string', optional => 1, maxLength => 65536, description => 'together/separate: VM IDs, comma separated.' },
    'vm-group' => { type => 'string', optional => 1, description => 'vm-host: VM group.' },
    'host-group' => { type => 'string', optional => 1, description => 'vm-host: host group.' },
    mode => { type => 'string', optional => 1, enum => [ @PVE::WDCBalancer::Config::RULE_MODES ],
        description => 'vm-host: must run on, should run on, must not run on, should not run on.' },
    enabled => { type => 'boolean', optional => 1, default => 1 },
    comment => $comment_opt,
};

my $apply_rule = sub {
    my ($r, $param) = @_;
    $r->{type} = $param->{type} if defined($param->{type});
    $r->{vms} = [ map { $_ =~ /^\d+$/ ? $_ + 0 : $_ } @{ $list->($param->{vms}) } ] if defined($param->{vms});
    $r->{vm_group} = $param->{'vm-group'} if defined($param->{'vm-group'});
    $r->{host_group} = $param->{'host-group'} if defined($param->{'host-group'});
    $r->{mode} = $param->{mode} if defined($param->{mode});
    $r->{enabled} = $param->{enabled} ? 1 : 0 if defined($param->{enabled});
    $r->{comment} = $param->{comment} if defined($param->{comment});
    if ($r->{type} eq 'vm-host') {
        delete $r->{vms};
    } else {
        delete @$r{qw(vm_group host_group mode)};
    }
};

$register->({
    name => 'rules',
    path => 'rules',
    method => 'GET',
    description => "VM/Host and VM-VM rules, with their state in the last pass.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'array', items => { type => 'object' } },
    code => sub {
        my $cfg = PVE::WDCBalancer::Config::load();
        my $res = $result->();
        my %state;
        for my $f (@{$res->{faults} // []}) {
            $state{$_} = 'violated (no fix)' for split(/,/, $f->{rule} // '');
        }
        for my $r (@{$res->{recommendations} // []}) {
            $state{$_} //= 'violated (fix recommended)' for split(/,/, $r->{rule} // '');
        }
        return [ map {
            my $r = $cfg->{rules}->{$_};
            {
                name => $_,
                type => $r->{type},
                $r->{type} eq 'vm-host' ? ('vm-group' => $r->{vm_group}, 'host-group' => $r->{host_group}, mode => $r->{mode})
                    : (vms => join(',', @{$r->{vms} // []})),
                enabled => ($r->{enabled} // 1) ? 1 : 0,
                comment => $r->{comment} // '',
                state => !($r->{enabled} // 1) ? 'disabled' : $state{$_} // 'ok',
            }
        } sort keys %{$cfg->{rules}} ];
    },
});

$register->({
    name => 'rule_create',
    path => 'rules',
    method => 'POST',
    description => "Create a rule. A rule that conflicts with an enabled rule can't be saved enabled.",
    permissions => { check => $PERM_MODIFY },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, name => $name_opt, %$rule_props } },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;
        PVE::WDCBalancer::Config::update(sub {
            my ($cfg) = @_;
            die "rule '$param->{name}' already exists\n" if $cfg->{rules}->{$param->{name}};
            my $r = { enabled => 1 };
            $apply_rule->($r, $param);
            $cfg->{rules}->{$param->{name}} = $r;
        });
        $ha_sync->();
        return undef;
    },
});

$register->({
    name => 'rule_update',
    path => 'rules/{name}',
    method => 'PUT',
    description => "Change a rule.",
    permissions => { check => $PERM_MODIFY },
    parameters => {
        additionalProperties => 0,
        properties => { node => $node_opt, name => $name_opt, %$rule_props, type => { %{$rule_props->{type}}, optional => 1 } },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;
        PVE::WDCBalancer::Config::update(sub {
            my ($cfg) = @_;
            my $r = $cfg->{rules}->{$param->{name}} // die "no rule '$param->{name}'\n";
            $apply_rule->($r, $param);
        });
        $ha_sync->();
        return undef;
    },
});

$register->({
    name => 'rule_delete',
    path => 'rules/{name}',
    method => 'DELETE',
    description => "Delete a rule.",
    permissions => { check => $PERM_MODIFY },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, name => $name_opt } },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;
        PVE::WDCBalancer::Config::update(sub {
            my ($cfg) = @_;
            delete($cfg->{rules}->{$param->{name}}) // die "no rule '$param->{name}'\n";
        });
        $ha_sync->();
        return undef;
    },
});

# ---------------- VM overrides ----------------

$register->({
    name => 'overrides',
    path => 'overrides',
    method => 'GET',
    description => "Per-VM automation levels.",
    permissions => { check => $PERM_AUDIT },
    parameters => { additionalProperties => 0, properties => { node => $node_opt } },
    returns => { type => 'array', items => { type => 'object' } },
    code => sub {
        my $cfg = PVE::WDCBalancer::Config::load();
        my $g = $result->()->{guests} // {};
        return [ map { { vmid => $_ + 0, name => $g->{$_}->{name} // '', automation => $cfg->{overrides}->{$_}->{automation} } }
            sort { $a <=> $b } keys %{$cfg->{overrides}} ];
    },
});

$register->({
    name => 'override_set',
    path => 'overrides/{vmid}',
    method => 'PUT',
    description => "Set a VM's automation level.",
    permissions => { check => $PERM_MODIFY },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => $node_opt,
            vmid => $vmid_opt,
            automation => { type => 'string', enum => [ @PVE::WDCBalancer::Config::AUTOMATION ] },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;
        PVE::WDCBalancer::Config::update(sub {
            my ($cfg) = @_;
            $cfg->{overrides}->{$param->{vmid}} = { automation => $param->{automation} };
        });
        return undef;
    },
});

$register->({
    name => 'override_delete',
    path => 'overrides/{vmid}',
    method => 'DELETE',
    description => "Remove a VM's override (back to the cluster's automation level).",
    permissions => { check => $PERM_MODIFY },
    parameters => { additionalProperties => 0, properties => { node => $node_opt, vmid => $vmid_opt } },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;
        PVE::WDCBalancer::Config::update(sub {
            my ($cfg) = @_;
            delete($cfg->{overrides}->{$param->{vmid}}) // die "no override for VM $param->{vmid}\n";
        });
        return undef;
    },
});

1;
