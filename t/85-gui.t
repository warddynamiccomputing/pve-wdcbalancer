use strict;
use warnings;

use Test::More;

# Static checks of www/wdcbalancer.js (no JavaScript engine in the test
# environment; CI also runs node --check on the file).

open(my $fh, '<', 'www/wdcbalancer.js') or die "www/wdcbalancer.js: $!";
my $js = do { local $/; <$fh> };
close($fh);

open($fh, '<', 'src/PVE/API2/WDCBalancer.pm') or die;
my $api = do { local $/; <$fh> };
close($fh);

sub class_body {
    my ($name) = @_;
    my ($body) = $js =~ /Ext\.define\('\Q$name\E', \{(.*?)\n\}\);/s;
    return $body;
}

# every grid column list is HTML-safe
my @lists = $js =~ /\bcolumns:\s*([^\s\d][^\n]{0,40})/g;
ok(@lists >= 8, 'column lists found');
is_deeply([ grep { !/^PVE\.wdcb\.Utils\.safeColumns\(/ } @lists ], [], 'every column list goes through safeColumns');
my @plain = $js =~ /renderer:\s*(?:v|\(v[^)]*\))\s*=>\s*(v\b[^,}\n]*|`\$\{v\}[^`]*`)/g;
is_deeply(\@plain, [], 'no renderer returns its value unencoded');

# the summary panel builds HTML from API data: every interpolation is encoded
my $summary = class_body('PVE.wdcb.Summary') // '';
my @raw = grep { !/^(?:enc\(|PVE\.wdcb\.Utils\.render|w\b|h\b|60 - h|color|pct|n\b|bars)/ } $summary =~ /\$\{([^}]*)\}/g;
is_deeply(\@raw, [], 'summary HTML: every value encoded or numeric');

# every API path the GUI calls exists
my %paths = map { $_ => 1 } $api =~ /path => '([^']*)'/g;
my @used = $js =~ /Utils\.url\((?:'|`)([a-z-]+)/g;
ok(@used >= 8, 'API calls found');
for my $p (sort keys %{{ map { $_ => 1 } @used }}) {
    ok($paths{$p} || $paths{"$p/{name}"} || $paths{"$p/{vmid}"}, "GUI path '$p' exists in the API");
}

# menu hook
my $hook = class_body('PVE.wdcb.ConfigHook') // '';
like($hook, qr/\$className === 'PVE\.dc\.Config'/, 'hook: datacenter panel');
like($hook, qr/itemId === 'ha'/, 'placed after HA');
like($hook, qr/Sys\.Audit/, 'only for users who may audit');
like($hook, qr/try \{.*\} catch \(err\)/s, 'a failure only drops the entry');
like($hook, qr/me\.callParent\(arguments\)/, 'always calls the parent');

my $dc = class_body('PVE.wdcb.DcPanel') // '';
is_deeply([ $dc =~ /xtype: '(pveWdcb\w+)'/g ],
    [ qw(pveWdcbSummary pveWdcbRecGrid pveWdcbGuestGrid pveWdcbFaultGrid pveWdcbHistoryGrid pveWdcbSettingsView
        pveWdcbGroupGrid pveWdcbRuleGrid pveWdcbOverrideGrid pveWdcbMaintenanceGrid) ], 'datacenter tabs');
like($hook, qr/\$className === 'PVE\.node\.Config'.*pveWdcbNodePanel/s, 'node menu entry');
like($js, qr/enableFn: rec => rec.data.status === 'stopped'/, 'Power On only for stopped guests');
for my $x ($dc =~ /xtype: '(pveWdcb\w+)'/g) {
    like($js, qr/alias: 'widget\.\Q$x\E'/, "$x is defined");
}

# moves only go through the apply API (permission checks, limits, history)
unlike($js, qr/['"]migrate['"]|\/migrate\b/, 'the GUI never migrates guests itself');
like($js, qr/Utils\.url\('apply'\)/, 'it uses the apply API');
like($js, qr/Ext\.Msg\.confirm\(gettext\('Apply recommendations'\)/, 'applying asks first');
like($js, qr/Proxmox\.window\.TaskViewer/, 'and shows the task');
my ($ov) = class_body('PVE.wdcb.OverrideEdit') // '';
like($ov, qr/\['disabled', 'manual', 'partial', 'full'\]/, 'overrides offer all four levels');

# methods must not replace ExtJS component methods (a tab panel calls show())
my @clash = $js =~ /^    (show|hide|close|load|render|destroy|update|enable|disable|focus|add|remove|setTitle)\s*:\s*function/mg;
is_deeply(\@clash, [], 'no class overrides a built-in component method');

# guest IDs and names in URLs are encoded
unlike($js, qr/Utils\.url\(`[^`]*\$\{(?!encodeURIComponent)/, 'URL parameters are URL-encoded');

done_testing();
