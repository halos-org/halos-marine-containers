# HaLOS Marine Containers - Technical Specification

**Status**: Draft
**Date**: 2025-11-14
**Last Updated**: 2025-11-14

## Project Overview

The HaLOS Marine Containers project provides a curated collection of marine and sailing applications packaged as Debian containers, along with a store definition package that enables filtered discovery through cockpit-apt's web interface.

This project delivers two primary artifacts:
1. **marine-container-store** - A Debian package defining the Marine store configuration
2. **Marine container apps** - Individual Debian packages for marine applications (Signal K, OpenCPN, AvNav, Grafana, InfluxDB)

## Goals

### Primary Goals

1. **Unified Store Definition**: Provide a single package that configures cockpit-apt to display marine applications in a dedicated "Marine Apps" view
2. **Curated App Collection**: Deliver a set of essential marine applications packaged for easy installation via APT
3. **Reference Implementation**: Serve as a template for creating additional container stores (development tools, home automation, etc.)
4. **Simplified Packaging**: Enable app maintainers to add new marine applications without deep Debian packaging knowledge

### Success Criteria

- Users can install marine-container-store via APT
- cockpit-apt automatically displays a "Marine Apps" toggle when the store is installed
- Marine applications are filtered and displayed based on store configuration rules
- All marine apps install, start via systemd, and function correctly
- Build process is automated via CI/CD
- Documentation enables community contributions

## Core Features

### Store Configuration Package (marine-container-store)

**Purpose**: Configure cockpit-apt's filtering and presentation of marine applications

**Key Capabilities**:
- Define filter rules to include packages based on:
  - Repository origin (e.g., "Hat Labs" APT repository)
  - Debian package sections (e.g., net, web)
  - Debian tags/debtags (e.g., field::marine, use::routing)
  - Explicit package names (e.g., grafana-container)
- Customize section metadata (labels, icons, descriptions) for marine-specific categorization
- Provide store branding assets (icon, banner)
- Enable/disable automatically based on package installation state

**Filter Logic**:
- OR logic within filter categories (match ANY origin, tag, section, or package)
- AND logic between categories (must satisfy at least one condition from EACH specified category)
- Packages matching any filter rule are included in the store view

### Container Application Packages

**Purpose**: Package marine applications as Debian-native containers managed by systemd

**Key Capabilities**:
- Each app packaged as individual .deb file
- systemd service units manage container lifecycle
- Docker Compose defines container configuration
- Configuration files use standard Linux paths
- Applications integrate with system logging via journalctl
- Web UIs accessible via standard ports
- Automatic startup on boot

**Target Applications** (Phase 1):
- Signal K Server - Marine data hub and server
- OpenCPN - Chart plotter and navigation software
- AvNav - Web-based chart plotter
- Grafana - Data visualization dashboards
- InfluxDB - Time-series database for marine data

## Technical Requirements

### Store Package Requirements

1. **Installation Paths**:
   - Store configuration: `/etc/container-apps/stores/marine.yaml`
   - Branding assets: `/usr/share/container-stores/marine/`

2. **Configuration Format**:
   - YAML format for human readability and maintainability
   - Support for comments to explain filter logic
   - Validation against schema during build

3. **Filter Compatibility**:
   - Compatible with standard Debian package metadata
   - Uses official debtags vocabulary
   - Respects APT repository metadata format

4. **Dynamic Loading**:
   - cockpit-apt detects store packages automatically
   - No restart required after installation
   - Uninstallation removes store from UI cleanly

### Container App Package Requirements

1. **Package Naming**: Follow `<upstream-name>-container` convention

2. **Standard Paths**:
   - Docker Compose file: `/var/lib/container-apps/<package>/docker-compose.yml`
   - Configuration: `/etc/container-apps/<package>/config.yml`
   - systemd service: `/etc/systemd/system/<name>-container.service`

3. **Dependencies**:
   - Docker CE or Docker.io (version >= 20.10)
   - docker-compose-plugin or docker-compose standalone
   - Standard system libraries only

4. **Resource Constraints**:
   - Must run on Raspberry Pi 4 (arm64 architecture)
   - Memory usage reasonable for embedded systems
   - Container images available for arm64

### Build and Packaging Requirements

1. **Automated Build**:
   - CI/CD builds packages on commit to main branch
   - GitHub Actions handles build orchestration
   - Artifacts published to apt.hatlabs.fi repository

2. **Package Generation**:
   - Uses container-packaging-tools for container apps
   - Standard Debian packaging for marine-container-store
   - Lintian validation during build
   - Consistent package metadata

3. **Versioning**:
   - Semantic versioning for marine-container-store
   - Container apps follow upstream version + Debian revision
   - Changelog maintained for all releases

## Key Constraints and Assumptions

### Constraints

1. **Target Platform**: Raspberry Pi OS (Debian-based, arm64) running on Raspberry Pi 4 or newer
2. **Cockpit Integration**: Requires cockpit-apt module to display store UI
3. **Docker Runtime**: Requires Docker to be installed and running
4. **Network Access**: Requires network connectivity for pulling container images
5. **Storage Space**: Each container app requires 100MB-2GB depending on images

### Assumptions

1. **User Expertise**: Users comfortable with web interfaces but may not know command line
2. **System Access**: Users have sudo/admin access to install packages
3. **APT Repository**: Hat Labs APT repository (apt.hatlabs.fi) is configured and accessible
4. **Docker Configured**: Docker daemon is properly configured for user namespace
5. **Filesystem Standards**: Target system follows Filesystem Hierarchy Standard (FHS)

## Non-Functional Requirements

### Performance

- Store configuration loading: < 100ms
- Package list filtering: < 500ms for 1000+ packages
- CI/CD build time: < 10 minutes for all packages
- Package installation time: < 2 minutes (excluding image download)

### Security

- No secrets or credentials stored in package files
- Configuration files have appropriate permissions (0644 for configs, 0755 for executables)
- Store configuration cannot execute arbitrary code
- Container apps run with minimal privileges
- systemd services use standard security hardening

### Usability

- Store appears automatically in cockpit-apt when installed
- Filter rules clearly documented in marine.yaml with comments
- Section labels and descriptions user-friendly
- Store icon recognizable at 24x24 pixel size
- Error messages actionable and clear

### Maintainability

- YAML configuration format allows inline documentation
- Package structure follows Debian standards
- Build scripts are idempotent
- Documentation enables community contributions
- Changes to store config don't require code changes

### Reliability

- Package installation is atomic (succeeds completely or fails cleanly)
- systemd ensures container apps restart on failure
- Invalid store configuration degrades gracefully (ignored, not crash)
- Container app failures don't affect system stability

## Out of Scope

The following items are explicitly out of scope for this project:

1. **Container Orchestration**: No Kubernetes, Docker Swarm, or similar orchestration platforms
2. **Multi-Host Deployments**: Single-node installations only
3. **Container Configuration UI**: Editing container settings remains command-line based (Phase 2 work)
4. **App Discovery Service**: No automatic detection of already-installed Docker containers
5. **Container Registry**: No private registry hosting; uses upstream registries
6. **Resource Monitoring**: No container resource usage dashboards (rely on system tools)
7. **Backup/Restore**: No automated backup of container data (user responsibility)
8. **Certificate Management**: No automatic HTTPS/TLS certificate provisioning
9. **Multi-Architecture**: arm64 only (amd64 support future work)
10. **Podman Support**: Docker only (Podman support future work)

## Dependencies

### External Dependencies

- **cockpit-apt**: Required for displaying store UI and filtering packages
- **container-packaging-tools**: Required for generating container app packages
- **Docker**: Required runtime for all container applications
- **APT repository (apt.hatlabs.fi)**: Hosts all generated packages

### Internal Dependencies

- Marine container apps depend on marine-container-store for optimal discovery
- Store filtering depends on proper debtags in app packages
- CI/CD depends on container-packaging-tools being available

## References

- [ADR-001: Container Store Architecture](../../cockpit-apt/docs/ADR-001-container-store.md)
- [META-PLANNING.md](../../META-PLANNING.md)
- [Debian Package Tags (Debtags)](https://wiki.debian.org/Debtags)
- [Debian Policy Manual](https://www.debian.org/doc/debian-policy/)
