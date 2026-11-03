package PVE::WDCBalancer::Notify;

# Notifications through the Proxmox VE notification system (matchers and
# targets in Datacenter > Notifications), with the templates in
# /usr/share/pve-manager/templates/default/wdcbalancer-alert-*.txt.hbs.
# Metadata: type=wdcbalancer, hostname=<node>.

use strict;
use warnings;

use PVE::INotify;

sub send {
    my ($severity, $title, $lines) = @_;
    my $text = join("\n", @$lines) . "\n";
    print "wdcbalancer notification ($severity): $title\n$text";
    eval {
        require PVE::Notify;
        my $data = eval { PVE::Notify::common_template_data() } // {};
        PVE::Notify::notify($severity, 'wdcbalancer-alert', { %$data, title => $title, message => $text },
            { type => 'wdcbalancer', hostname => PVE::INotify::nodename() });
    };
    print "WARNING: could not send notification: $@" if $@;
}

# What makes a fault the same fault from pass to pass: its type, rule and
# guests, or, for faults without guests, the message without its numbers
# (minutes left, counts, sizes change while the cause stays).
sub fault_key {
    my ($f) = @_;
    return join('|', $f->{type} // '', $f->{rule} // '', join(',', sort { $a <=> $b } @{$f->{vmids}}))
        if $f->{vmids} && @{$f->{vmids}};
    (my $m = $f->{message} // '') =~ s/\d+(?:\.\d+)?/#/g;
    return join('|', $f->{type} // '', $f->{rule} // '', $m);
}

# Not notified: missing data and balancing holds pass by themselves.
our %QUIET = (data => 1, hold => 1);

# Faults that are new since the last pass, so a fault that stays is
# reported once.
sub new_faults {
    my ($old, $new) = @_;
    my %seen = map { fault_key($_) => 1 } @{$old // []};
    return [ grep { !$seen{ fault_key($_) } && !$QUIET{$_->{type} // ''} } @{$new // []} ];
}

1;
