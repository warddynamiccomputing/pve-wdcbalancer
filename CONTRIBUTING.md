# Contributing

Bug reports, test results from your cluster and pull requests are welcome.

## Reporting a problem

Open an issue with:
- the Proxmox VE version (`pveversion`) and the pve-wdcbalancer version;
- what you expected and what happened;
- `wdcbalancer status`, and for a surprising recommendation
  `wdcbalancer explain <vmid>`.

Before posting output, **remove** node names, guest names, addresses and
anything else you don't want public.

## Development

```bash
make test        # unit tests; PVE modules are stubbed when not installed
make lint        # shellcheck, perlcritic, actions pinned (needs shellcheck libperl-critic-perl)
make deb         # Debian package (needs debhelper)
```

- The tests run anywhere with Perl 5.36+. On a Proxmox node they compile
  against the real PVE libraries.
- The engine is pure Perl working on a snapshot (`PVE::WDCBalancer::Engine`,
  `Score`, `Constraints`). Add a scenario to `t/30-engine.t` or
  `t/40-rules.t` with `t/lib/SnapFixture.pm` for any change to its decisions.
- Keep `debian/changelog` and `CHANGELOG.md` in step.

## Pull requests

One topic per pull request, tests included, `make test` and `make lint` green.
