#!/usr/bin/perl

# Run on a PVE host: checks that every fully qualified PVE::*::function the
# plugin calls exists in the installed PVE libraries. Catches renamed or
# imagined helpers that a compile check cannot see.
#
# usage: perl -Isrc t/symbols.pl

use strict;
use warnings;

use File::Find;

my %calls;
find(sub {
    return if !/\.pm$/;
    open(my $fh, '<', $_) or die;
    while (my $line = <$fh>) {
        next if $line =~ /^\s*#/;
        while ($line =~ /\b(PVE::(?:[A-Za-z0-9_]+::)+)([a-z_][A-Za-z0-9_]*)\s*\(/g) {
            my ($pkg, $fn) = ($1, $2);
            $pkg =~ s/::$//;
            next if $pkg =~ /^PVE::(?:WDCBalancer\b|API2::WDCBalancer|CLI::wdcbalancer)/; # ours, covered by tests
            push @{$calls{"${pkg}::$fn"}}, "$File::Find::name:$.";
        }
        # class method calls: PVE::Foo->bar(
        while ($line =~ /\b(PVE::(?:[A-Za-z0-9_]+::)*[A-Za-z0-9_]+)->([a-z_][A-Za-z0-9_]*)\s*\(/g) {
            push @{$calls{"$1->$2"}}, "$File::Find::name:$.";
        }
    }
    close($fh);
}, 'src');

my $bad = 0;
for my $sym (sort keys %calls) {
    my ($pkg, $fn, $method) = $sym =~ /^(.*)->(.*)$/ ? ($1, $2, 1) : ($sym =~ /^(.*)::([^:]+)$/);
    (my $file = "$pkg.pm") =~ s|::|/|g;
    eval { require $file };
    no strict 'refs';
    my $ok = !$@ && ($method ? $pkg->can($fn) : defined(&{"${pkg}::$fn"}));
    # RESTHandler methods are created at registration time
    $ok ||= $method && !$@ && $pkg->can('map_method_by_name') && $pkg->map_method_by_name($fn);
    printf("%-4s %s  (%s)\n", $ok ? 'ok' : 'MISS', $sym, $calls{$sym}->[0]);
    $bad++ if !$ok;
}
print $bad ? "$bad missing symbol(s)\n" : "all symbols resolve\n";
exit($bad ? 1 : 0);
