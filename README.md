# HaLOS Marine Containers

Marine container store definition and curated marine application definitions for HaLOS.

## What's in This Repository

This repository contains:

1. **Store Definition** (`store/`): Configuration and branding for the Marine container store
   - Installs to `/etc/container-apps/stores/marine.yaml` on target systems
   - Provides filtering rules, section metadata, and branding

2. **Marine App Definitions** (`apps/`): Curated marine applications packaged as containers
   - Signal K server
   - OpenCPN chartplotter
   - InfluxDB (for marine data logging)
   - Grafana (for marine data visualization)
   - And more...

## Build Output

CI/CD builds multiple Debian packages from this repository:
- `marine-container-store` - Store definition package
- `signalk-server-container` - Signal K marine data server
- `opencpn-container` - OpenCPN chartplotter
- etc.

All packages are published to apt.hatlabs.fi.

## Agentic Coding Setup (Claude Code, GitHub Copilot, etc.)

For development with AI assistants, use the halos-distro workspace for full context:

```bash
# Clone the workspace
git clone https://github.com/hatlabs/halos-distro.git
cd halos-distro

# Get all sub-repositories including halos-marine-containers
./run repos:clone

# Work from workspace root for AI-assisted development
# Claude Code gets full context across all repos
```

See `halos-distro/docs/` for development workflows:
- `HUMAN_DEVELOPMENT_GUIDANCE.md` - Quick start guide
- `IMPLEMENTATION_CHECKLIST.md` - Development checklist
- `DEVELOPMENT_WORKFLOW.md` - Detailed workflows

## Repository Structure

```
halos-marine-containers/
├── store/
│   ├── marine.yaml          # Store configuration
│   ├── icon.svg             # Store branding
│   ├── banner.png
│   └── debian/              # Packaging for marine-container-store
├── apps/
│   ├── signalk-server/      # Each app has its definition
│   ├── opencpn/
│   └── ...
├── tools/                    # Build scripts
├── .github/workflows/        # CI/CD
├── docs/
│   └── DESIGN.md             # Detailed design documentation
└── README.md
```

## Adding a New App

See [docs/DESIGN.md](docs/DESIGN.md) for detailed instructions on adding new marine applications to the store.

## Building Locally

Requirements:
- `container-packaging-tools` package installed

```bash
# Build all packages
./tools/build-all.sh

# Build output in build/ directory
ls build/*.deb
```

## Related Repositories

- [halos-distro](https://github.com/hatlabs/halos-distro) - HaLOS workspace and planning
- [cockpit-apt](https://github.com/hatlabs/cockpit-apt) - APT package manager with store filtering
- [container-packaging-tools](https://github.com/hatlabs/container-packaging-tools) - Package generation tooling
- [apt.hatlabs.fi](https://github.com/hatlabs/apt.hatlabs.fi) - APT repository infrastructure

## License

See individual app definitions for their respective licenses.
