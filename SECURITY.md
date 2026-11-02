# Security policy

pve-wdcbalancer runs as root on Proxmox VE nodes and recommends and carries out guest migrations, so security reports are welcome.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private vulnerability
reporting instead: the **Security** tab of this repository → **Report a
vulnerability**. Include the version, what an attacker could do, and steps to
reproduce.

## How it is built to be safe

- **Permissions:** viewing needs `Sys.Audit` on `/`; changing settings, groups,
  rules or overrides needs `Sys.Modify` on `/`. The timer entry point needs `Sys.Modify`
  on `/` too.
- **What it reads:** guest and node usage from local RRD files, guest configs
  from pmxcfs, and cluster facts through `pvesh`. It talks to nothing outside
  the cluster.
- **What it writes:** `/etc/pve/wdcbalancer/` (configuration, last pass,
  history, lease, node-facts cache) and its own HA rules. Configuration changes are validated and
  written under the cluster lock.
- **Moves:** only through the apply API (needs `Sys.Modify` on `/` and
  `VM.Migrate` on every moved guest) or, with full automation, by the timer
  as `root@pam`. Every move is a Proxmox migration task; nothing else is
  changed on the guests.
- **HA rules:** only rules named `wdcb-*` with its marker comment are ever
  changed or deleted.
- **GUI:** everything that comes from guests or the configuration (names,
  comments, rule and group names, messages) is HTML-encoded, and IDs in URLs
  are URL-encoded.
- **Integration:** the API is loaded inside an `eval`. If the module fails to
  load, only `/nodes/{node}/wdcbalancer` is missing; the rest of the Proxmox VE
  API keeps working. The patched `Nodes.pm` is compile-checked and rolled back
  if it does not compile.

## Verifying a download

Each release has a `SHA256SUMS` file and a build-provenance attestation
signed by GitHub Actions, which ties the `.deb` to the commit and workflow
run that built it:

```bash
sha256sum -c SHA256SUMS --ignore-missing
gh attestation verify pve-wdcbalancer_X.Y.Z_all.deb --repo warddynamiccomputing/pve-wdcbalancer
```

## How releases are built

- CI runs with a read-only token. Only the job that publishes a tagged
  release can write to it, and it runs no code from pull requests.
- Every GitHub Action is pinned to a full commit SHA; Dependabot proposes
  updates, and `make lint` fails on an unpinned one.
- `make lint` also runs shellcheck and perlcritic.

## Supported versions

Only the latest release receives fixes.
