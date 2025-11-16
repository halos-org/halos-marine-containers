# HaLOS Marine Containers - Design Document

**Status**: Draft
**Date**: 2025-11-11
**Last Updated**: 2025-11-11

## Overview

This repository contains both the marine container store definition AND the marine application definitions. This combined approach keeps the store configuration and its curated apps together as a single source of truth with unified CI/CD.

## Purpose

- Provide a curated collection of marine-specific container applications
- Define the "Marine Apps" store configuration for cockpit-apt
- Generate Debian packages for both the store definition and container apps
- Serve as a reference implementation for other container store repositories

## Repository Structure

```
halos-marine-containers/
├── store/
│   ├── marine.yaml          # Store configuration
│   ├── icon.svg             # Store branding (24x24 or SVG)
│   ├── banner.png           # Store banner (recommended 1200x300)
│   └── debian/              # Packaging for marine-container-store package
│       ├── control
│       ├── rules
│       ├── install
│       ├── changelog
│       └── copyright
├── apps/
│   ├── signalk-server/
│   │   ├── docker-compose.yml
│   │   ├── config.yml
│   │   ├── metadata.json
│   │   └── icon.png
│   ├── opencpn/
│   ├── influxdb/
│   ├── grafana/
│   └── ...
├── tools/                    # Build scripts for this repo
│   └── build-all.sh
├── .github/workflows/
│   └── build.yml             # Builds marine-container-store + all app packages
├── docs/
│   ├── DESIGN.md             # This file
│   └── ADDING_APPS.md        # Guide for contributors
└── README.md
```

## Store Configuration Format

### Store Definition File: `store/marine.yaml`

The store configuration file defines how packages are filtered and displayed in cockpit-apt's store view.

```yaml
# Store metadata
id: marine
name: Marine Apps
description: Marine and sailing applications including navigation, weather, and AIS
icon: /usr/share/container-stores/marine/icon.svg
banner: /usr/share/container-stores/marine/banner.png

# Filter logic (OR within each category, AND between categories)
filters:
  # Repository origins (from APT Release file "Origin:" field)
  include_origins:
    - "Hat Labs"

  # Debian sections
  include_sections:
    - net
    - web

  # Debian tags (faceted debtags)
  include_tags:
    - field::marine
    - use::routing

  # Optional explicit package list
  include_packages:
    - influxdb-container
    - grafana-container

# Custom sections that don't exist in standard Debian
custom_sections:
  - id: ais
    label: AIS
    description: Automatic Identification System tools
    icon: ship

  - id: radar
    label: Radar
    description: Marine radar integration
    icon: radar

  - id: weather
    label: Weather Routing
    description: Weather forecasting and routing
    icon: cloud

# Display preferences
display:
  sort_by: popularity  # or: name, recent
  show_screenshots: true
  show_ratings: false  # Future feature
```

### Filter Logic Details

**OR Logic Within Categories**:
- If a package matches ANY origin in `include_origins`, it's included
- If a package matches ANY tag in `include_tags`, it's included
- If a package matches ANY section in `include_sections`, it's included

**AND Logic Between Categories** (when multiple specified):
- Package must satisfy at least one condition from EACH category
- Example: If both `include_origins` and `include_tags` specified, package needs matching origin AND matching tag

**Origin Filtering**:
- Uses APT repository metadata (`Origin:` field from Release file)
- Allows automatic categorization of all packages from specific repositories
- No need to tag individual packages if entire repo is marine-focused

### Store Package Installation

The `marine-container-store` package installs:
- `/etc/container-apps/stores/marine.yaml` - Configuration
- `/usr/share/container-stores/marine/icon.svg` - Branding icon
- `/usr/share/container-stores/marine/banner.png` - Store banner

When installed, cockpit-apt automatically detects the store configuration and displays the "Marine Apps" toggle in the UI.

## App Definition Format

Each application in `apps/` directory contains these files:

### 1. metadata.json

Required metadata describing the application:

```json
{
  "name": "Signal K Server",
  "package_name": "signalk-server-container",
  "version": "2.8.0",
  "upstream_version": "2.8.0",
  "description": "Signal K server for marine data processing and routing",
  "long_description": "Signal K is a modern and open data format for marine use. A Signal K server provides a central hub for collecting, processing, and distributing marine data from multiple sources.",
  "homepage": "https://signalk.org/",
  "icon": "icon.png",
  "screenshots": [
    "screenshot1.png",
    "screenshot2.png"
  ],
  "maintainer": "Hat Labs <support@hatlabs.fi>",
  "license": "Apache-2.0",
  "tags": [
    "role::container-app",
    "field::marine",
    "interface::web",
    "use::routing",
    "network::server"
  ],
  "debian_section": "net",
  "architecture": "arm64",
  "depends": [
    "docker-ce (>= 20.10) | docker.io (>= 20.10)"
  ],
  "web_ui": {
    "enabled": true,
    "path": "/",
    "port": 3000,
    "protocol": "http"
  },
  "default_config": {
    "HTTP_PORT": "3000",
    "SIGNALK_SERVER_CONFIG": "/etc/signalk"
  }
}
```

**Field Descriptions**:
- `name`: Human-readable application name
- `package_name`: Debian package name (must end with `-container`)
- `version`: Package version (can include Debian revision)
- `upstream_version`: Original application version
- `description`: Short description (< 80 chars, for package lists)
- `long_description`: Detailed description (for package details view)
- `homepage`: Upstream project URL
- `icon`: Relative path to icon file (PNG, 64x64 or larger)
- `screenshots`: Array of screenshot filenames
- `maintainer`: Package maintainer (Name <email>)
- `license`: SPDX license identifier
- `tags`: Array of debtags (faceted vocabulary)
- `debian_section`: Debian section (net, web, etc.)
- `architecture`: Target architecture (arm64, amd64, all)
- `depends`: Array of package dependencies (Debian control syntax)
- `web_ui`: Optional web interface configuration
- `default_config`: Default environment variables for .env file

### 2. docker-compose.yml

Standard Docker Compose file defining the container configuration:

```yaml
version: '3.8'

services:
  signalk:
    image: signalk/signalk-server:latest
    container_name: signalk-server
    restart: unless-stopped
    ports:
      - "${HTTP_PORT:-3000}:3000"
    volumes:
      - signalk-config:/home/node/.signalk
      - /etc/signalk:/etc/signalk:ro
    environment:
      - SIGNALK_SERVER_CONFIG=/etc/signalk
    networks:
      - signalk-net

volumes:
  signalk-config:

networks:
  signalk-net:
    driver: bridge
```

**Requirements**:
- Use environment variables with `${VAR:-default}` syntax for user-configurable values
- Define named volumes for persistent data
- Use `restart: unless-stopped` for production reliability
- Set meaningful `container_name` for easier management
- Use bridge networks for isolation

### 3. config.yml

User-configurable parameters with metadata for UI generation:

```yaml
# Configuration schema for Signal K Server
# Used by cockpit-container-config (Phase 2) to generate configuration UI

version: "1.0"

# Configuration groups organize related settings
groups:
  - id: network
    label: Network Settings
    description: Port and network configuration
    fields:
      - id: HTTP_PORT
        label: HTTP Port
        type: integer
        default: 3000
        min: 1024
        max: 65535
        required: true
        description: Port for web interface and API

  - id: storage
    label: Storage
    description: Data storage configuration
    fields:
      - id: SIGNALK_SERVER_CONFIG
        label: Configuration Directory
        type: path
        default: /etc/signalk
        required: true
        description: Directory containing server configuration files
```

**Field Types**:
- `string`: Text input
- `integer`: Numeric input with optional min/max
- `boolean`: Checkbox
- `enum`: Dropdown with predefined options
- `path`: File/directory path
- `password`: Masked text input

### 4. Icon and Screenshots

- `icon.png`: Application icon (PNG, 64x64 or larger, square)
- `screenshot1.png`, etc.: Screenshots showing application UI

## Package Naming Conventions

### Container Application Packages

**Format**: `<upstream-name>-container`

Examples:
- `signalk-server-container`
- `opencpn-container`
- `influxdb-container`
- `grafana-container`

**systemd Service**: `<package-name>.service`
- Example: `signalk-server-container.service`

### Store Definition Package

**Format**: `<store-id>-container-store`

Example: `marine-container-store`

## File Installation Paths

Packages install files following these conventions:

### Container Application Package

```
/var/lib/container-apps/<package>/
├── docker-compose.yml       # Compose file
├── .env.template            # Environment template
└── metadata.json            # App metadata (for UI)

/etc/container-apps/<package>/
├── config.yml               # User-editable configuration
└── .env                     # Generated from config.yml + defaults

/etc/systemd/system/
└── <package>.service        # systemd service unit

/usr/share/pixmaps/
└── <package>.png            # Application icon

/usr/share/doc/<package>/
├── copyright
└── changelog.gz
```

### Store Definition Package

```
/etc/container-apps/stores/
└── marine.yaml              # Store configuration

/usr/share/container-stores/marine/
├── icon.svg                 # Store icon
└── banner.png               # Store banner

/usr/share/doc/marine-container-store/
├── copyright
└── changelog.gz
```

## systemd Service Management

Each container application is managed by a systemd service that:

1. Reads configuration from `/etc/container-apps/<package>/.env`
2. Starts containers using `docker-compose up -d`
3. Stops containers using `docker-compose down`
4. Enables automatic restart on failure
5. Logs to journald

**Service Template** (generated by container-packaging-tools):

```ini
[Unit]
Description=Signal K Server Container
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/var/lib/container-apps/signalk-server-container
EnvironmentFile=/etc/container-apps/signalk-server-container/.env
ExecStart=/usr/bin/docker-compose up -d
ExecStop=/usr/bin/docker-compose down
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

## Build Process

### Local Development Build

```bash
# Install dependencies
sudo apt install dpkg-dev debhelper dh-make

# Build store definition package
cd store/
dpkg-buildpackage -b -us -uc
cd ..

# Build individual app packages (requires container-packaging-tools)
cd apps/signalk-server/
generate-container-packages .
cd ../..

# Or build all apps at once
./tools/build-all.sh
```

### CI/CD Workflow

The `.github/workflows/build.yml` workflow:

1. Triggers on push to main branch or pull requests
2. Installs container-packaging-tools from apt.hatlabs.fi
3. Builds marine-container-store package from `store/`
4. Builds each app package from `apps/*/`
5. Uploads artifacts (all .deb packages)
6. On tagged releases:
   - Publishes packages to apt.hatlabs.fi repository
   - Creates GitHub release with package attachments

### Package Versioning

**Versioning Flexibility**: Any versioning scheme compatible with Debian package versioning
- No requirement for semantic versioning
- Version format must be comparable using `dpkg --compare-versions`
- Format: `<upstream-version>-<debian-revision>`

**Common Versioning Schemes**:

*Semantic Versioning (semver)*:
- Example: `signalk-server-container_2.8.0-1_arm64.deb`
- Version: `2.8.0` (upstream) + `-1` (Debian revision)

*Date-based Versioning*:
- Example: `avnav-container_20250113-1_arm64.deb`
- Version: `20250113` (2025-01-13) + `-1` (Debian revision)
- Sorts chronologically by default

*Calendar Versioning (CalVer)*:
- Example: `myapp-container_2025.01.13-1_arm64.deb`
- Version: `2025.01.13` (year.month.day) + `-1` (Debian revision)

*Store Package Versioning*:
- Recommend semver for store packages: `marine-container-store_1.0.0-1_all.deb`
- Store definitions change less frequently and benefit from semantic versions

**Debian Revision**: Increment when:
- Packaging changes (new dependencies, path changes)
- Configuration changes
- Bug fixes to the package itself (not upstream)

## Dependency Management

### Direct Dependencies

All container app packages directly depend on Docker:

```
Depends: docker-ce (>= 20.10) | docker.io (>= 20.10)
```

This can be refined later with:
- Virtual package: `container-runtime`
- Alternative runtimes: podman, containerd

### Store Package Dependencies

The store package can recommend but not require apps:

```
Recommends: signalk-server-container, opencpn-container
Suggests: influxdb-container, grafana-container
```

## Debian Tags (debtags)

### Faceted Vocabulary

Uses Debian's standard debtags vocabulary for rich categorization:

**Common Facets for Marine Apps**:
- `role::container-app` - Identifies as container application
- `field::marine` - Marine/sailing domain
- `interface::web` - Has web UI
- `interface::commandline` - CLI interface
- `use::organizing` - Data organization
- `use::monitoring` - System monitoring
- `use::routing` - Navigation/routing
- `network::server` - Network server role
- `works-with::*` - Data types handled

**Custom HaLOS Facets**:
- `category::navigation` - Navigation tools (broad category)
- `category::chartplotters` - Chart plotting applications
- `category::monitoring` - Data logging and system monitoring
- `category::communication` - NMEA gateways, AIS, radio integration
- `category::visualization` - Dashboards and data visualization

The `category::` facet is used for store-specific categorization and UI organization. Packages can have multiple category tags to appear in multiple categories within a store.

**Example Tags**:
```
Tag: role::container-app, field::marine, interface::web, use::routing, network::server
```

### Tag Benefits

- **Multi-store inclusion**: Apps can appear in multiple stores
  - Example: InfluxDB in both marine and development stores
- **Rich search**: Users can find apps by purpose, not just keywords
- **Automatic categorization**: Stores filter by tag combinations
- **Upstream compatibility**: Standard Debian vocabulary

**Reference**: [Debtags Vocabulary](https://salsa.debian.org/debtags-team/debtags-vocabulary)

## How to Add New Apps

### Step-by-Step Guide

1. **Create app directory**:
   ```bash
   mkdir -p apps/myapp
   cd apps/myapp
   ```

2. **Create docker-compose.yml**:
   - Use environment variables for configurable values
   - Define persistent volumes
   - Set `restart: unless-stopped`
   - Use meaningful container names

3. **Create metadata.json**:
   - Fill in all required fields
   - Choose appropriate debtags
   - Set correct Debian section
   - Define web UI configuration if applicable

4. **Create config.yml**:
   - Define configuration groups
   - Specify field types and validation
   - Provide sensible defaults
   - Add helpful descriptions

5. **Add icon and screenshots**:
   - Icon: PNG, 64x64 or larger, square
   - Screenshots: Show key features

6. **Test locally**:
   ```bash
   # Build the package
   generate-container-packages .

   # Install and test
   sudo dpkg -i ../myapp-container_*.deb
   sudo systemctl start myapp-container
   sudo systemctl status myapp-container
   journalctl -u myapp-container -f

   # Access web UI (if applicable)
   curl http://localhost:<port>
   ```

7. **Create pull request**:
   - Include app directory with all files
   - Update README.md with app description
   - Add changelog entry
   - CI/CD will build and test automatically

### Validation Checklist

Before submitting:
- [ ] All required metadata fields present
- [ ] Package name follows `<name>-container` convention
- [ ] Debtags include `role::container-app`
- [ ] Docker Compose uses environment variables
- [ ] Icon provided (PNG, 64x64+)
- [ ] config.yml has sensible defaults
- [ ] Successfully builds with `generate-container-packages`
- [ ] Service starts and stops cleanly
- [ ] Logs accessible via journalctl
- [ ] Web UI accessible (if applicable)

## Testing Procedures

### Unit Tests

Test individual app definitions:

```bash
# Validate metadata.json against schema
generate-container-packages --validate apps/myapp/

# Validate docker-compose.yml
docker-compose -f apps/myapp/docker-compose.yml config

# Validate config.yml against schema
# (Future: dedicated validation tool)
```

### Integration Tests

Test package installation and service management:

```bash
# Install package
sudo dpkg -i myapp-container_*.deb

# Check files installed correctly
ls -la /var/lib/container-apps/myapp-container/
ls -la /etc/container-apps/myapp-container/

# Start service
sudo systemctl start myapp-container

# Check status
sudo systemctl status myapp-container

# Check logs
journalctl -u myapp-container

# Test web UI (if applicable)
curl http://localhost:<port>

# Stop and remove
sudo systemctl stop myapp-container
sudo apt remove myapp-container
```

### Store Integration Test

Test store visibility in cockpit-apt:

```bash
# Install store package
sudo dpkg -i marine-container-store_*.deb

# Install cockpit-apt
sudo apt install cockpit-apt

# Access Cockpit
# Navigate to http://localhost:9090
# Go to Software section
# Click "Marine Apps" toggle
# Verify apps appear in filtered view
```

## Relationship to container-packaging-tools

This repository **depends on** `container-packaging-tools` for package generation.

**container-packaging-tools provides**:
- `generate-container-packages` command
- Debian package templates
- Validation schemas
- systemd service generation

**This repository provides**:
- App definitions (metadata, compose files, configuration)
- Store definition (marine.yaml)
- Build orchestration (CI/CD)
- Documentation and examples

**Workflow**:
1. Developers define apps in this repository
2. CI/CD installs container-packaging-tools
3. CI/CD runs `generate-container-packages` on each app
4. Generated .deb packages published to apt.hatlabs.fi

## Future Enhancements

### Phase 1 (Current)
- Basic app definitions and store configuration
- CI/CD package generation
- Manual configuration via .env files

### Phase 2 (cockpit-container-config)
- Web UI for app configuration (generated from config.yml)
- Visual service management (start/stop/restart)
- Real-time log viewer

### Phase 3 (Expansion)
- More marine apps (20+ target)
- AppStream metadata for richer package descriptions
- Screenshot hosting and management
- App ratings and reviews (optional)
- Automated testing in CI/CD

### Phase 4 (Community)
- Contributor guidelines
- External app submissions
- Community moderation
- Documentation for creating other stores (dev, home automation, etc.)

## References

### Internal Documentation
- [META-PLANNING.md](../../META-PLANNING.md) - Overall project planning
- [container-packaging-tools/docs/DESIGN.md](../../container-packaging-tools/docs/DESIGN.md) - Tooling design
- [cockpit-apt/docs/CONTAINER_STORE_DESIGN.md](../../cockpit-apt/docs/CONTAINER_STORE_DESIGN.md) - UI design
- [PROJECT_PLANNING_GUIDE.md](../../PROJECT_PLANNING_GUIDE.md) - Development workflow

### External References
- [Docker Compose Specification](https://docs.docker.com/compose/compose-file/)
- [systemd Service Units](https://www.freedesktop.org/software/systemd/man/systemd.service.html)
- [Debian Policy Manual](https://www.debian.org/doc/debian-policy/)
- [Debtags Vocabulary](https://salsa.debian.org/debtags-team/debtags-vocabulary)
- [YAML Specification](https://yaml.org/spec/1.2.2/)
- [SPDX License List](https://spdx.org/licenses/)
