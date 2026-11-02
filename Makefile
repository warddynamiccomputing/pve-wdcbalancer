PACKAGE := pve-wdcbalancer
VERSION := $(shell dpkg-parsechangelog -S Version 2>/dev/null || echo 0.1.0)

DESTDIR ?=
PERLDIR := $(DESTDIR)/usr/share/perl5
SBINDIR := $(DESTDIR)/usr/sbin
LIBDIR := $(DESTDIR)/usr/share/$(PACKAGE)
WWWDIR := $(DESTDIR)/usr/share/pve-manager/js
UNITDIR := $(DESTDIR)/lib/systemd/system
TEMPLATEDIR := $(DESTDIR)/usr/share/pve-manager/templates/default

MODULES := $(wildcard src/PVE/WDCBalancer/*.pm)

.PHONY: all install test check lint deb clean

all:

install:
	install -d $(PERLDIR)/PVE/WDCBalancer $(PERLDIR)/PVE/API2 $(PERLDIR)/PVE/CLI
	install -m 0644 $(MODULES) $(PERLDIR)/PVE/WDCBalancer/
	install -m 0644 src/PVE/API2/WDCBalancer.pm $(PERLDIR)/PVE/API2/
	install -m 0644 src/PVE/CLI/wdcbalancer.pm $(PERLDIR)/PVE/CLI/
	install -D -m 0755 bin/wdcbalancer $(SBINDIR)/wdcbalancer
	install -D -m 0755 bin/wdcbalancer-integrate $(LIBDIR)/wdcbalancer-integrate
	install -D -m 0644 www/wdcbalancer.js $(WWWDIR)/wdcbalancer.js
	install -D -m 0644 systemd/wdcbalancer.service $(UNITDIR)/wdcbalancer.service
	install -m 0644 systemd/wdcbalancer.timer $(UNITDIR)/
	install -d $(TEMPLATEDIR)
	install -m 0644 templates/wdcbalancer-alert-subject.txt.hbs templates/wdcbalancer-alert-body.txt.hbs $(TEMPLATEDIR)/

# unit tests + compile check; runs anywhere with Perl (PVE modules are stubbed when absent)
test:
	prove -I src -I t/lib t/

check: test
	@command -v node >/dev/null && node --check www/wdcbalancer.js && echo "www/wdcbalancer.js: syntax OK" || true

# needs shellcheck and perlcritic (Debian: shellcheck libperl-critic-perl)
lint:
	shellcheck tools/*.sh debian/postinst debian/prerm debian/postrm
	perlcritic --profile .perlcriticrc src bin
	@! grep -nE "uses: *[^ ]+@" .github/workflows/*.yml | grep -vE "@[0-9a-f]{40}( |$$)" || { echo "actions must be pinned to a full commit SHA"; exit 1; }

# exec bits get lost when the tree is copied from Windows or a zip
deb:
	chmod 0755 debian/rules bin/wdcbalancer bin/wdcbalancer-integrate
	dpkg-buildpackage -b -us -uc

clean:
	rm -rf debian/$(PACKAGE) debian/.debhelper debian/files debian/*.substvars debian/*.debhelper* debian/debhelper-build-stamp
