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

# Faults that are new since the last pass (by message), so a fault that
# stays is reported once.
sub new_faults {
    my ($old, $new) = @_;
    my %seen = map { ($_->{message} // '') => 1 } @{$old // []};
    return [ grep { !$seen{$_->{message} // ''} && ($_->{type} // '') ne 'data' } @{$new // []} ];
}

1;
