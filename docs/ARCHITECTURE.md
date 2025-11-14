# HaLOS Marine Containers - System Architecture

**Status**: Draft
**Date**: 2025-11-14
**Last Updated**: 2025-11-14

## System Overview

The HaLOS Marine Containers system consists of two main components that work together to provide curated marine applications through the cockpit-apt interface:

1. **marine-container-store package** - Configuration and metadata defining the Marine store
2. **Container application packages** - Individual marine applications packaged as Debian containers

These components integrate with cockpit-apt (the frontend), container-packaging-tools (the build toolchain), and apt.hatlabs.fi (the distribution channel).

## System Components

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                        End User                              │
│                     (Web Browser)                            │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────────┐
│                     cockpit-apt                              │
│           (Web UI + Backend - Phase 1)                       │
│  - Loads store configs from /etc/container-apps/stores/     │
│  - Parses package metadata (debtags, origins)                │
│  - Filters and displays marine packages                      │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────────┐
│                    APT / dpkg                                │
│              (Package Management)                            │
└─────┬──────────────────────────────────────┬────────────────┘
      │                                       │
      ▼                                       ▼
┌─────────────────────┐         ┌──────────────────────────────┐
│ marine-container-   │         │  Container App Packages      │
│ store               │         │  - signalk-server-container  │
│ - marine.yaml       │         │  - opencpn-container         │
│ - icon.svg          │         │  - avnav-container           │
│ - banner.png        │         │  - grafana-container         │
└─────────────────────┘         │  - influxdb-container        │
                                └────────┬─────────────────────┘
                                         │
                                         ▼
                                ┌────────────────────┐
                                │  systemd services  │
                                │  - Manages lifecycle│
                                │  - Start on boot   │
                                └────────┬───────────┘
                                         │
                                         ▼
                                ┌────────────────────┐
                                │   Docker Engine    │
                                │   - Runs containers│
                                │   - docker-compose │
                                └────────────────────┘
```

### Build and Distribution Pipeline

```
┌────────────────────────────────────────────────────────────┐
│                   Developer                                 │
│           (Commits to halos-marine-containers)              │
└──────────────────────┬─────────────────────────────────────┘
                       │
                       ▼
┌────────────────────────────────────────────────────────────┐
│               GitHub Actions CI/CD                          │
│  1. Build marine-container-store (dpkg-buildpackage)        │
│  2. Build container apps (container-packaging-tools)        │
│  3. Run validation and tests                                │
│  4. Create GitHub release with .deb artifacts               │
└──────────────────────┬─────────────────────────────────────┘
                       │
                       ▼
┌────────────────────────────────────────────────────────────┐
│               apt.hatlabs.fi Repository                     │
│           (APT repository hosting)                          │
│  - Packages published automatically                         │
│  - Signed with repository key                               │
│  - Accessible via APT over HTTPS                            │
└────────────────────────────────────────────────────────────┘
```

## Data Models and Schemas

### Store Configuration Schema (marine.yaml)

The store configuration file uses YAML format with the following structure:

**Top-Level Fields**:
- **id** (string, required): Unique store identifier (lowercase, alphanumeric + hyphen)
- **name** (string, required): Human-readable store name
- **description** (string, required): Multi-line description of store purpose
- **icon** (string, required): Absolute path to store icon file
- **banner** (string, optional): Absolute path to banner image

**filters** (object, required):
- **include_origins** (array of strings, optional): APT repository Origin field values to match
- **include_sections** (array of strings, optional): Debian section names to include
- **include_tags** (array of strings, optional): Debtag values to match
- **include_packages** (array of strings, optional): Explicit package names to include

**section_metadata** (object, optional): Maps Debian section names to display metadata:
- **label** (string): User-friendly section name
- **icon** (string): Icon identifier for UI
- **description** (string): Section description

**Filter Evaluation Logic**:
- Within each filter category (origins, sections, tags, packages): OR logic (match ANY)
- Between filter categories: OR logic (package included if it matches ANY category)
- If a package appears in include_packages, all other filters are bypassed for that package

### Container App Metadata Schema (metadata.yaml)

Each container app directory contains a metadata.yaml file with package information:

**Required Fields**:
- **name**: Human-readable application name
- **package_name**: Debian package name (must end with -container)
- **version**: Package version string
- **description**: Short description (< 80 characters)
- **maintainer**: Maintainer name and email
- **license**: SPDX license identifier

**Optional Fields**:
- **homepage**: Upstream project URL
- **icon**: Relative path to icon file
- **debian_section**: Debian section (default: misc)
- **architecture**: Target architecture (default: all)
- **depends**: Array of package dependencies
- **tags**: Array of debtags

### Container App Configuration Schema (config.yml)

Runtime configuration for each container app:

**Fields**:
- **ports**: Port mappings (host:container)
- **volumes**: Volume mounts (host:container)
- **environment**: Environment variables
- **restart_policy**: systemd restart behavior
- **user**: Container user ID
- **capabilities**: Linux capabilities to grant

## Technology Stack

### Store Package Technologies

**Chosen: Traditional Debian Packaging**

**Rationale**:
- Store package is simple (configuration files + assets only)
- No compilation required
- Standard Debian tools (dpkg-buildpackage) sufficient
- Follows Debian Policy Manual guidelines
- Easy to review and audit

**Alternatives Considered**:
- Python-based packaging: Rejected as overkill for static files
- FPM (Effing Package Management): Rejected to maintain standard Debian compliance

### Container App Packaging Technologies

**Chosen: container-packaging-tools**

**Rationale**:
- Purpose-built for generating container app packages
- Abstracts Debian packaging complexity
- Consistent package structure across apps
- Automated Jinja2 template rendering
- Validates app definitions against schema

**Alternatives Considered**:
- Manual Debian packaging per app: Rejected due to high maintenance burden
- FPM: Rejected for insufficient Docker Compose integration

### Container Runtime

**Chosen: Docker with Docker Compose**

**Rationale**:
- Industry-standard container runtime
- Docker Compose widely understood format
- Extensive documentation and community support
- Mature arm64 support for Raspberry Pi
- Standard on Raspberry Pi OS

**Alternatives Considered**:
- Podman: Deferred to Phase 2+ (Docker compatibility prioritized)
- Native systemd-nspawn: Rejected for complexity and limited tooling

### Configuration Format

**Chosen: YAML**

**Rationale**:
- Human-readable and writable
- Supports comments for documentation
- Standard for Docker Compose compatibility
- Good library support in Python/JavaScript
- No ambiguity with properly formatted YAML

**Alternatives Considered**:
- JSON: Rejected for lack of comments and reduced readability
- TOML: Rejected for less familiarity in container ecosystem

## Integration Points

### Integration with cockpit-apt

**Discovery Mechanism**:
- cockpit-apt scans `/etc/container-apps/stores/` for YAML files on startup
- Store packages install configuration to this directory
- No restart required; periodic polling detects new stores

**Data Exchange**:
- Store configuration consumed by cockpit-apt backend
- No API calls; file-based integration only
- cockpit-apt parses YAML and applies filters to package lists

**UI Integration**:
- Store toggle group appears when one or more stores detected
- Repository dropdown filters within active store context
- Standard cockpit-apt package views display filtered results

### Integration with APT Repositories

**Metadata Requirements**:
- Packages must include Tag: field in debian/control with debtags
- APT repository must provide Origin: and Label: fields in Release file
- Package lists fetched via standard APT protocols (https)

**Package Discovery**:
- cockpit-apt queries APT cache for available packages
- Filter logic applied based on package metadata
- No special API; standard APT metadata only

### Integration with systemd

**Service Management**:
- Each container app includes systemd service unit
- Service units call docker-compose up/down in package directory
- Standard systemd controls (start, stop, restart, enable, disable)

**Lifecycle Hooks**:
- postinst script enables and starts service
- prerm script stops and disables service
- postrm script cleans up state files if purged

### Integration with Docker

**Container Lifecycle**:
- systemd service units invoke docker-compose
- Docker Compose files reference images from public registries
- No direct Docker API interaction; CLI only

**Image Management**:
- Container images pulled on first start
- No automatic image updates (user responsibility)
- Images cached in Docker image store

## Deployment Architecture

### Installation Flow

1. **User adds apt.hatlabs.fi repository** to APT sources
2. **User installs cockpit-apt package** via APT
3. **User installs marine-container-store package** via APT or cockpit-apt
   - Package installs to `/etc/container-apps/stores/marine.yaml`
   - cockpit-apt detects new store configuration
4. **User browses Marine Apps store** in cockpit-apt web UI
5. **User installs container app** (e.g., signalk-server-container)
   - Package installs files to `/var/lib/container-apps/`, `/etc/container-apps/`, `/etc/systemd/system/`
   - postinst script enables and starts systemd service
   - Service pulls Docker image and starts container
6. **Container app running** and accessible via web UI

### File System Layout

```
/
├── etc/
│   ├── container-apps/
│   │   ├── stores/
│   │   │   └── marine.yaml              # Store configuration
│   │   └── signalk-server-container/
│   │       └── config.yml               # App configuration
│   └── systemd/
│       └── system/
│           └── signalk-server-container.service
│
├── var/
│   └── lib/
│       └── container-apps/
│           └── signalk-server-container/
│               ├── docker-compose.yml   # Container definition
│               ├── .env.template        # Environment template
│               └── metadata.yaml        # App metadata
│
└── usr/
    └── share/
        └── container-stores/
            └── marine/
                ├── icon.svg             # Store branding
                └── banner.png
```

### Runtime Architecture

**Process Hierarchy**:
```
systemd (PID 1)
└── signalk-server-container.service
    └── docker-compose up
        └── dockerd
            └── signalk-server container
```

**Network Architecture**:
- Container exposes ports on host network (bridge mode)
- No internal service mesh or overlay networks
- Each app responsible for own port management
- Port conflicts resolved by user configuration

## Security Considerations

### Package Security

**Build-Time Security**:
- All packages built in clean CI/CD environment
- No secrets embedded in package files
- Lintian validation checks common security issues
- Packages signed by APT repository key

**Installation Security**:
- Packages install with standard file permissions (0644 for files, 0755 for directories)
- No setuid/setgid binaries
- Configuration files owned by root, readable by all
- systemd services run as root but containers may drop privileges

### Container Security

**Isolation**:
- Containers run with Docker's default security profile
- No host network mode (uses bridge networking)
- File system isolation via Docker volumes
- Process isolation via cgroups and namespaces

**Privilege Management**:
- systemd services run as root (required for Docker socket access)
- Container processes should run as non-root user (app-specific)
- Capabilities dropped by Docker unless explicitly granted

**Network Security**:
- Container ports exposed only on localhost by default (configurable)
- No automatic firewall rules configured
- User responsible for network security policy

### Store Configuration Security

**File Permissions**:
- Store configuration files readable by all users (0644)
- Only root can modify store configuration files
- Branding assets readable by all (0644)

**Code Execution**:
- YAML configuration files are data-only (no code execution)
- cockpit-apt validates YAML schema before parsing
- Invalid configurations ignored gracefully

**Injection Prevention**:
- Filter values treated as literal strings (no evaluation)
- No shell command injection possible via configuration
- cockpit-apt sanitizes all user-supplied filter inputs

## Build and Release Process

### Build Steps

**marine-container-store**:
1. Clone repository
2. Change to store/ directory
3. Run dpkg-buildpackage -us -uc -b
4. Validate package with lintian
5. Upload .deb artifact to GitHub release

**Container Apps**:
1. Clone repository
2. Run generate-container-packages apps/ build/
3. Validate generated packages with lintian
4. Upload all .deb artifacts to GitHub release

### Versioning Strategy

**marine-container-store**:
- Semantic versioning (MAJOR.MINOR.PATCH)
- Increment MINOR for new features (new filters, metadata fields)
- Increment PATCH for bug fixes (typos, documentation)
- No breaking changes expected (store format stable)

**Container Apps**:
- Follow upstream version + Debian revision
- Format: UPSTREAM_VERSION-DEBIAN_REVISION
- Example: 2.8.0-1 (Signal K version 2.8.0, Debian revision 1)

### Release Automation

**Trigger**: Push to main branch or new Git tag

**GitHub Actions Workflow**:
1. Checkout repository
2. Install build dependencies (debhelper, container-packaging-tools)
3. Build all packages
4. Run validation (lintian, unit tests)
5. Create GitHub release with .deb artifacts
6. Publish packages to apt.hatlabs.fi (automated webhook)

## Scalability and Performance

### Package Loading Performance

**Expectation**: < 100ms to load and parse marine.yaml

**Factors**:
- Small file size (< 10KB)
- Simple YAML structure
- No network I/O required
- Parsed once on cockpit-apt startup or store installation

### Package Filtering Performance

**Expectation**: < 500ms to filter 1000+ packages

**Factors**:
- In-memory filtering (no disk I/O)
- Simple string matching on metadata
- No regex or complex queries
- Results cached by cockpit-apt

### Repository Scalability

**Store Package**:
- Single package, minimal growth
- Updates infrequent (quarterly or less)

**Container Apps**:
- Linear growth with app additions
- Target: 20-50 apps in marine store
- Each package 1-5 MB (metadata + small scripts)
- Total repository size manageable (< 500 MB)

## References

- [SPEC.md](SPEC.md) - Technical specification
- [DESIGN.md](DESIGN.md) - Detailed design documentation
- [ADR-001: Container Store Architecture](../../cockpit-apt/docs/ADR-001-container-store.md)
- [Filesystem Hierarchy Standard](https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html)
- [Debian Policy Manual](https://www.debian.org/doc/debian-policy/)
- [systemd Service Units](https://www.freedesktop.org/software/systemd/man/systemd.service.html)
