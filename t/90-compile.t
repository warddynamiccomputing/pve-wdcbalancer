use strict;
use warnings;

use Test::More;

use StubPVE;

# Load every module. On a PVE host this compiles against the real PVE
# libraries; elsewhere missing PVE modules are stubbed (see StubPVE).
my @modules = qw(
    PVE::WDCBalancer::Config
    PVE::WDCBalancer::Score
    PVE::WDCBalancer::Constraints
    PVE::WDCBalancer::Engine
    PVE::WDCBalancer::Collect
    PVE::WDCBalancer::State
    PVE::API2::WDCBalancer
    PVE::CLI::wdcbalancer
);

# compile warnings (like "Useless use of ... in void context") are bugs here
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, $_[0] };
require_ok($_) for @modules;
is_deeply(\@warnings, [], 'no compile warnings') or diag(@warnings);

diag("stubbed: " . join(' ', sort keys %StubPVE::STUBBED)) if %StubPVE::STUBBED;

for my $script ('bin/wdcbalancer-integrate', 'bin/wdcbalancer') {
    my $out = `"$^X" -Isrc -It/lib -MStubPVE -c $script 2>&1`;
    like($out, qr/syntax OK/, "$script compiles");
}

# with the real PVE libraries: every CLI command maps to a valid API method
SKIP: {
    skip 'PVE libraries not installed', 1 if $StubPVE::STUBBED{'PVE::CLIHandler'} || $StubPVE::STUBBED{'PVE::RESTHandler'};
    ok(eval { PVE::CLI::wdcbalancer->verify_api(); 1 }, 'CLI and API definitions verify') or diag($@);
}

# every module is installed by the Makefile (wildcard) and the API version
# matches the package version
open(my $fh, '<', 'debian/changelog') or die;
my ($version) = <$fh> =~ /\(([^)]+)\)/;
close($fh);
is($PVE::API2::WDCBalancer::VERSION, $version, 'API version matches debian/changelog');

done_testing();
