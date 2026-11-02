package PVE::WDCBalancer::HARules;

# Mirrors our rules into native HA rules for the guests that are under HA,
# so the HA manager honours them too (when it starts, recovers or fences).
#
#   vm-host must / should          -> node-affinity, positive, strict 1 / 0
#   vm-host must-not / should-not  -> node-affinity, negative, strict 1 / 0
#   together / separate            -> resource-affinity, positive / negative
#                                     (only with at least two HA guests)
#
# Mirrored rules are named 'wdcb-<rule>' and carry $MARK as comment; only
# those are ever changed or deleted. Rules created by hand are left alone.
#
# desired() and plan() are pure; sync() reads the HA config and calls the API.

use strict;
use warnings;

use JSON::PP;

use PVE::Tools;

use PVE::WDCBalancer::Config;

our $PREFIX = 'wdcb-';
our $MARK = 'managed by pve-wdcbalancer';

# vmid => sid ('vm:100', 'ct:200') of the HA resources in resources.cfg
sub parse_ha_resources {
    my ($raw) = @_;
    my %sids;
    for my $line (split /\n/, $raw // '') {
        $sids{$2} = "$1:$2" if $line =~ /^(vm|ct):\s*(\d+)\s*$/;
    }
    return \%sids;
}

# rules.cfg with everything sync() compares
sub parse_rules {
    my ($raw) = @_;
    my (%rules, $cur);
    for my $line (split /\n/, $raw // '') {
        if ($line =~ /^([a-z-]+):\s*(\S+)\s*$/) {
            $cur = $rules{$2} = { type => $1 };
        } elsif ($cur && $line =~ /^\s+(\S+)\s+(.*?)\s*$/) {
            $cur->{$1} = $2;
        }
    }
    for my $r (values %rules) {
        $r->{resources} = join(',', sort split(/,/, $r->{resources} // ''));
        $r->{nodes} = join(',', sort split(/,/, $r->{nodes})) if defined($r->{nodes});
        $r->{affinity} //= 'positive';
        $r->{strict} //= 0 if $r->{type} eq 'node-affinity';
    }
    return \%rules;
}

sub rule_id {
    my ($name) = @_;
    return $PREFIX . substr($name, 0, 58);
}

# rule-id => { type, resources, nodes, affinity, strict } from our config
sub desired {
    my ($cfg, $sids) = @_;
    my %want;
    for my $r (@{ PVE::WDCBalancer::Config::enabled_rules($cfg) }) {
        my @ha = sort map { $sids->{$_} // () } @{ PVE::WDCBalancer::Config::rule_vms($cfg, $r) };
        if ($r->{type} eq 'vm-host') {
            next if !@ha;
            my @nodes = sort @{ PVE::WDCBalancer::Config::rule_hosts($cfg, $r) };
            next if !@nodes;
            $want{ rule_id($r->{name}) } = {
                type => 'node-affinity',
                resources => join(',', @ha),
                nodes => join(',', @nodes),
                affinity => $r->{mode} =~ /-not$/ ? 'negative' : 'positive',
                strict => $r->{mode} =~ /^must/ ? 1 : 0,
            };
        } else {
            next if @ha < 2;
            $want{ rule_id($r->{name}) } = {
                type => 'resource-affinity',
                resources => join(',', @ha),
                affinity => $r->{type} eq 'together' ? 'positive' : 'negative',
            };
        }
    }
    return \%want;
}

my @KEYS = qw(type resources nodes affinity strict);

sub same {
    my ($a, $b) = @_;
    for my $k (@KEYS) {
        return 0 if ($a->{$k} // '') ne ($b->{$k} // '');
    }
    return 1;
}

# [ [ 'create' | 'update', id, props ], [ 'delete', id ], [ 'conflict', id ] ]
sub plan {
    my ($want, $have) = @_;
    my @ops;
    for my $id (sort keys %$want) {
        my $h = $have->{$id};
        if (!$h) {
            push @ops, [ 'create', $id, $want->{$id} ];
        } elsif (($h->{comment} // '') ne $MARK) {
            push @ops, [ 'conflict', $id ];
        } elsif ($h->{disable} || !same($h, $want->{$id})) {
            # the type can't change in place
            push @ops, $h->{type} eq $want->{$id}->{type} ? [ 'update', $id, $want->{$id} ] : ([ 'delete', $id ], [ 'create', $id, $want->{$id} ]);
        }
    }
    for my $id (sort keys %$have) {
        next if $want->{$id} || ($have->{$id}->{comment} // '') ne $MARK || index($id, $PREFIX) != 0;
        push @ops, [ 'delete', $id ];
    }
    return \@ops;
}

sub pvesh {
    my (@args) = @_;
    my $err = '';
    PVE::Tools::run_command(['pvesh', @args], outfunc => sub {}, errfunc => sub { $err .= "$_[0]\n" }, timeout => 60);
    return 1;
}

# Brings the mirrored HA rules in line with our config. Returns
# { changes => [ ... ], errors => [ ... ] }.
sub sync {
    my ($cfg) = @_;
    my $sids = parse_ha_resources(eval { PVE::Tools::file_get_contents('/etc/pve/ha/resources.cfg') } // '');
    my $have = parse_rules(eval { PVE::Tools::file_get_contents('/etc/pve/ha/rules.cfg') } // '');
    my $ops = plan(desired($cfg, $sids), $have);
    my (@changes, @errors);
    for my $op (@$ops) {
        my ($what, $id, $p) = @$op;
        if ($what eq 'conflict') {
            push @errors, "HA rule '$id' exists and was not made by pve-wdcbalancer; not changed";
            next;
        }
        my @props = $p ? map { defined($p->{$_}) && $_ ne 'type' ? ("--$_", $p->{$_}) : () } qw(resources nodes affinity strict) : ();
        my @cmd = $what eq 'create' ? ('create', '/cluster/ha/rules', '--rule', $id, '--type', $p->{type}, @props, '--comment', $MARK)
            : $what eq 'update' ? ('set', "/cluster/ha/rules/$id", '--type', $p->{type}, @props, '--comment', $MARK, '--disable', 0)
            : ('delete', "/cluster/ha/rules/$id");
        eval { pvesh(@cmd) };
        if (my $err = $@) {
            chomp($err);
            push @errors, "HA rule '$id': $what failed: $err";
        } else {
            push @changes, "$what $id";
        }
    }
    return { changes => \@changes, errors => \@errors };
}

1;
