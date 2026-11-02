package PVE::CLI::wdcbalancer;

# 'wdcbalancer' command line tool. Every command maps onto an API method, so
# the CLI, GUI and REST API behave identically.

use strict;
use warnings;

use PVE::CLIFormatter;
use PVE::CLIHandler;
use PVE::INotify;
use PVE::RPCEnvironment;

use PVE::API2::WDCBalancer;

use base qw(PVE::CLIHandler);

my $nodename = PVE::INotify::nodename();

sub setup_environment {
    PVE::RPCEnvironment->setup_default_cli_env();
}

my $table = sub {
    my (@cols) = @_;
    return sub {
        my ($data, $schema, $options) = @_;
        PVE::CLIFormatter::print_api_result($data, $schema, \@cols, $options);
    };
};

my $print_obj = sub {
    my ($data, $schema, $options) = @_;
    PVE::CLIFormatter::print_api_result($data, $schema, undef, $options);
};

my $pct = sub { return defined($_[0]) ? sprintf('%.0f%%', $_[0] * 100) : '-'; };

my $print_status = sub {
    my ($data, $schema, $options) = @_;
    if (($options->{'output-format'} // 'text') ne 'text') {
        PVE::CLIFormatter::print_api_result($data, $schema, undef, $options);
        return;
    }
    my $c = $data->{cluster} // {};
    if (!$data->{time}) {
        print "no pass yet (the timer runs one within a few minutes; 'wdcbalancer run' runs one now)\n";
        return;
    }
    printf("last pass: %s on %s (%s, %.1fs); leader: %s\n", scalar(localtime($data->{time})), $data->{node} // '?',
        $data->{trigger} // '?', $data->{duration} // 0, $data->{leader} // '-');
    printf("automation: %s, threshold %d\n", $data->{settings}->{automation}, $data->{settings}->{threshold});
    printf("cluster score: %s%% (after recommendations: %s%%), imbalance %.3f -> %.3f\n",
        $c->{score} // '-', $c->{expected} // '-', $c->{imbalance} // 0, $c->{expected_imbalance} // 0);
    my $b = $c->{buckets} // {};
    printf("VM scores: %s\n", join('  ', map { "$_%: " . ($b->{$_} // 0) } '0-20', '20-40', '40-60', '60-80', '80-100'));
    printf("guests: %d running, %d movable; %d recommendation(s), %d fault(s)\n",
        $c->{running} // 0, $c->{movable} // 0, $data->{recommendations}, $data->{faults});
    print "WARNING: Proxmox CRS ha-auto-rebalance is on; no moves are made while it is\n" if $c->{crs_conflict};
    printf("\n%-16s %6s %6s %8s %8s %6s %s\n", 'NODE', 'CPU', 'MEM', 'CPU AFT', 'MEM AFT', 'GUESTS', 'STATE');
    for my $n (@{$data->{nodes} // []}) {
        printf("%-16s %6s %6s %8s %8s %6d %s\n", $n->{node}, $pct->($n->{cpu}), $pct->($n->{mem}),
            $pct->($n->{expected_cpu}), $pct->($n->{expected_mem}), $n->{guests},
            !$n->{online} ? 'offline' : $n->{maintenance} ? 'maintenance' : 'online');
    }
};

my $node = { node => $nodename };
my $fmt = $PVE::RESTHandler::standard_output_options;
my $api = 'PVE::API2::WDCBalancer';

our $cmddef = {
    status => [ $api, 'status', [], $node, $print_status, $fmt ],
    run => [ $api, 'run', [], $node, $print_obj, $fmt ],
    recommendations => [ $api, 'recommendations', [], $node,
        $table->(qw(priority vmid name from to reason gain kind rule id)), $fmt ],
    dismiss => [ $api, 'dismiss', ['id'], $node ],
    guests => [ $api, 'guests', [], $node,
        $table->(qw(vmid name type node status score expected cpu_demand mem_demand automation movable reason)), $fmt ],
    faults => [ $api, 'faults', [], $node, $table->(qw(type rule message)), $fmt ],
    history => [ $api, 'history', [], $node, $table->(qw(time type node trigger score recommendations faults user id)), $fmt ],
    explain => [ $api, 'explain', ['vmid'], $node, $table->(qw(node current ok score gain cpu mem reason)), $fmt ],

    settings => {
        get => [ $api, 'settings_get', [], $node, $print_obj, $fmt ],
        set => [ $api, 'settings_set', [], $node ],
    },
    group => {
        list => [ $api, 'groups', [], $node, $table->(qw(name kind members comment)), $fmt ],
        add => [ $api, 'group_create', ['name', 'kind', 'members'], $node ],
        set => [ $api, 'group_update', ['name'], $node ],
        remove => [ $api, 'group_delete', ['name'], $node ],
    },
    rule => {
        list => [ $api, 'rules', [], $node, $table->(qw(name type vms vm-group mode host-group enabled state comment)), $fmt ],
        add => [ $api, 'rule_create', ['name', 'type'], $node ],
        set => [ $api, 'rule_update', ['name'], $node ],
        remove => [ $api, 'rule_delete', ['name'], $node ],
    },
    override => {
        list => [ $api, 'overrides', [], $node, $table->(qw(vmid name automation)), $fmt ],
        set => [ $api, 'override_set', ['vmid', 'automation'], $node ],
        remove => [ $api, 'override_delete', ['vmid'], $node ],
    },

    # run by the systemd timer
    'timer-run' => [ $api, 'timer_run', [], $node, $print_obj, $fmt ],
};

1;
