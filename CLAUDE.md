⚠️ **THESE RULES ONLY APPLY TO FILES IN /halos-marine-containers/** ⚠️

# HaLOS Marine Containers

Marine container store definition and curated marine application definitions.

**Local Instructions**: For environment-specific instructions and configurations, see @CLAUDE.local.md (not committed to version control).

## Git Workflow Policy

**Branch Workflow:** Never push to main directly - always use feature branches and PRs.

## What This Repository Contains

**Two things in one repository**:
1. **Marine Container Store** (`store/`) - Store definition package
2. **Marine Apps** (`apps/`) - Curated marine application definitions

**Rationale**: Store and apps are tightly coupled. The store defines which apps belong in the marine category, and those apps live right here. Single source of truth, unified CI/CD.

## Repository Structure

```
halos-marine-containers/
├── store/
│   ├── marine.yaml          # Store configuration
│   ├── icon.svg             # Branding (256x256)
│   ├── banner.png           # Branding (1200x300)
│   └── debian/              # Debian packaging for store package
│       ├── control
│       ├── rules
│       ├── install
│       └── ...
├── apps/
│   ├── signalk-server/
│   │   ├── docker-compose.yml
│   │   ├── config.yml
│   │   ├── metadata.json
│   │   └── icon.png
│   ├── opencpn/
│   └── ...
├── tools/
│   └── build-all.sh         # Build all packages
├── .github/workflows/
│   └── build.yml            # CI/CD
├── docs/
│   └── DESIGN.md            # Detailed design docs
└── README.md
```

## Adding a New Marine App

See [docs/DESIGN.md](docs/DESIGN.md) for complete instructions.

**Quick overview**:
1. Create `apps/<app-name>/` directory
2. Add `docker-compose.yml`, `config.yml`, `metadata.json`, `icon.png`
3. Test locally with `generate-container-packages`
4. Create PR - CI will build and validate

## Building

**Requirements**: `container-packaging-tools` installed

```bash
# Build all packages (store + apps)
./tools/build-all.sh

# Output: build/*.deb
```

**CI/CD**: GitHub Actions builds on push and creates releases.

## Store Configuration

The `store/marine.yaml` defines:
- Which packages appear in the Marine store (filter rules)
- Custom section labels and icons
- Store branding

## Related

- **Parent**: [../CLAUDE.md](../CLAUDE.md) - Workspace documentation
- **Tooling**: [container-packaging-tools](https://github.com/hatlabs/container-packaging-tools)
- **UI**: [cockpit-apt](https://github.com/hatlabs/cockpit-apt)
