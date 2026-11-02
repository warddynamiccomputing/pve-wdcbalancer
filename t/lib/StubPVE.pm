package StubPVE;

# Lets t/90-compile.t load the PVE-dependent modules on machines without
# Proxmox VE. The hook sits at the END of @INC, so real PVE modules are
# always preferred; only missing PVE::* modules become empty stubs whose
# functions and methods all return undef.

use strict;
use warnings;

our %STUBBED;

push @INC, sub {
    my (undef, $file) = @_;
    return if $file !~ m|^PVE/.*\.pm$|;
    return if $file =~ m{^PVE/(?:WDCBalancer/|API2/WDCBalancer\.pm|CLI/wdcbalancer\.pm)};
    (my $pkg = $file) =~ s|/|::|g;
    $pkg =~ s/\.pm$//;
    $STUBBED{$pkg} = 1;
    # import() hands the caller a stub for each requested function; those
    # return {} so load-time calls like get_standard_option() can be deref'd
    my $code = <<"EOF";
package $pkg;
sub import {
    my (\$class, \@syms) = \@_;
    my \$caller = caller;
    no strict 'refs';
    for my \$s (grep { /^\\w+\$/ } \@syms) {
        *{"\${caller}::\$s"} = sub { return {}; } if !defined(&{"\${caller}::\$s"});
    }
}
our \$AUTOLOAD;
sub AUTOLOAD { return; }
sub DESTROY {}
1;
EOF
    open(my $fh, '<', \$code) or die;
    return $fh;
};

1;
