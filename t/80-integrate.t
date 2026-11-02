use strict;
use warnings;

use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);

# Run bin/wdcbalancer-integrate against a fake pve-manager tree, then load
# the patched Nodes.pm with a working and a broken PVE::API2::WDCBalancer,
# alone and next to pve-fcsan's integration line.

my $root = tempdir(CLEANUP => 1);
my $nodes = "$root/usr/share/perl5/PVE/API2/Nodes.pm";
my $index = "$root/usr/share/pve-manager/index.html.tpl";
my $lib = "$root/lib";
make_path("$root/usr/share/perl5/PVE/API2", "$root/usr/share/pve-manager", "$lib/PVE/API2");

my $NODES = <<'EOF';
package PVE::API2::Nodes::Nodeinfo;
use strict;
use warnings;
our @REGISTERED;
sub register_method { my ($class, $info) = @_; push @REGISTERED, $info->{path}; }
__PACKAGE__->register_method({
    subclass => "PVE::API2::Disks",
    path => 'disks',
});
__PACKAGE__->register_method({ subclass => "PVE::API2::Other", path => 'other' });
1;
EOF
my $INDEX = <<'EOF';
    <script type="text/javascript" src="/pve2/js/pvemanagerlib.js?ver=[% version %]"></script>
  </head>
EOF
my $SAN_LINE = 'eval { require PVE::API2::SAN; __PACKAGE__->register_method({ subclass => "PVE::API2::SAN", path => \'san\' }); 1 }'
    . " or warn \"pve-fcsan: SAN API disabled - \$@\"; # pvesan-integration\n";
my $SAN_JS = "    <script type=\"text/javascript\" src=\"/pve2/js/pvesan.js?ver=[% version %]\"></script> <!-- pvesan-integration -->\n";

sub write_file {
    my ($file, $content) = @_;
    open(my $fh, '>', $file) or die "$file: $!";
    print $fh $content;
    close($fh);
}

sub read_file {
    my ($file) = @_;
    open(my $fh, '<', $file) or die "$file: $!";
    local $/;
    return scalar(<$fh>);
}

sub fake_module {
    my ($broken) = @_;
    write_file("$lib/PVE/API2/WDCBalancer.pm", $broken
        ? "package PVE::API2::WDCBalancer;\ndie \"Can't locate PVE/Missing.pm in \@INC\\n\";\n1;\n"
        : "package PVE::API2::WDCBalancer;\n1;\n");
    write_file("$lib/PVE/API2/SAN.pm", "package PVE::API2::SAN;\n1;\n");
}

sub integrate {
    my ($cmd) = @_;
    local $ENV{WDCBALANCER_INTEGRATE_ROOT} = $root;
    local $ENV{PERL5LIB} = $lib;
    my $out = qx("$^X" bin/wdcbalancer-integrate $cmd 2>&1);
    return ($? >> 8, $out);
}

sub load_nodes {
    my $code = "require q{$nodes}; print join(q{,}, \@PVE::API2::Nodes::Nodeinfo::REGISTERED)";
    my $out = qx("$^X" -I"$lib" -e "$code" 2>&1);
    return ($? >> 8, $out);
}

sub marked_lines { my @l = grep { /wdcbalancer-integration/ } split(/^/, read_file($_[0])); return scalar(@l) }

write_file($nodes, $NODES);
write_file($index, $INDEX);

fake_module(0);
my ($rc, $out) = integrate('apply');
is($rc, 0, 'apply succeeds') or diag($out);
like($out, qr/Nodes\.pm: integrated/, 'Nodes.pm integrated');
like($out, qr/index\.html\.tpl: integrated/, 'index.html.tpl integrated');
is(marked_lines($nodes), 1, 'one marked line in Nodes.pm');
like(read_file($nodes), qr/path => 'disks',\n\}\);\neval \{ require PVE::API2::WDCBalancer;/, 'API line follows the Disks subclass');
like(read_file($index), qr/pvemanagerlib\.js.*\n.*wdcbalancer\.js/, 'GUI script follows pvemanagerlib.js');

($rc, $out) = load_nodes();
is($rc, 0, 'Nodes.pm loads') or diag($out);
like($out, qr/^disks,wdcbalancer,other$/m, 'wdcbalancer registered between disks and other');

($rc, $out) = integrate('apply');
like($out, qr/Nodes\.pm: already integrated/, 'second apply changes nothing');
($rc, $out) = integrate('status');
is($rc, 0, 'status exits 0');
like($out, qr/PVE::API2::WDCBalancer: loads/, 'status: API module loads');

# a broken pve-wdcbalancer must not take the rest of the API down
fake_module(1);
($rc, $out) = load_nodes();
is($rc, 0, 'Nodes.pm still loads with a broken module') or diag($out);
like($out, qr/^disks,other$/m, 'other subclasses still registered');
like($out, qr/pve-wdcbalancer: load balancing API disabled - Can't locate PVE\/Missing\.pm/, 'warning names the cause');
($rc, $out) = integrate('status');
is($rc, 1, 'status exits 1 when the module fails');
fake_module(0);

# next to pve-fcsan: our line goes after its line, and re-applying either
# leaves the file alone
write_file($nodes, $NODES =~ s/(path => 'disks',\n\}\);\n)/$1$SAN_LINE/r);
write_file($index, $INDEX =~ s/(pvemanagerlib\.js.*\n)/$1$SAN_JS/r);
($rc, $out) = integrate('apply');
is($rc, 0, 'apply next to pve-fcsan') or diag($out);
like(read_file($nodes), qr/# pvesan-integration\neval \{ require PVE::API2::WDCBalancer;/, 'our line after pve-fcsan\'s');
like(read_file($index), qr/pvesan\.js.*\n.*wdcbalancer\.js/, 'our script after pve-fcsan\'s');
($rc, $out) = load_nodes();
like($out, qr/^disks,san,wdcbalancer,other$/m, 'both registered');
($rc, $out) = integrate('apply');
like($out, qr/Nodes\.pm: already integrated/, 're-apply is stable');
like($out, qr/index\.html\.tpl: already integrated/, '... for the GUI too');
# pve-fcsan re-applying (strip its line, put it right after Disks) gives the same file
my $content = read_file($nodes);
my $sim = join('', grep { !/pvesan-integration/ } split(/^/, $content));
$sim =~ s/(path => 'disks',\n\}\);\n)/$1$SAN_LINE/;
is($sim, $content, "pve-fcsan's re-apply would not move anything either");

# a Nodes.pm without the anchor is left alone
write_file($nodes, "package PVE::API2::Nodes::Nodeinfo;\n1;\n");
($rc, $out) = integrate('apply');
is($rc, 1, 'apply fails without the anchor');
like($out, qr/anchor \(Disks subclass\) not found/, 'and says why');

# remove keeps pve-fcsan's lines
write_file($nodes, $NODES =~ s/(path => 'disks',\n\}\);\n)/$1$SAN_LINE/r);
write_file($index, $INDEX);
integrate('apply');
($rc, $out) = integrate('remove');
like($out, qr/Nodes\.pm: removed/, 'remove Nodes.pm');
is(read_file($nodes), $NODES =~ s/(path => 'disks',\n\}\);\n)/$1$SAN_LINE/r, 'only our line removed');
is(read_file($index), $INDEX, 'index.html.tpl restored exactly');

done_testing();
