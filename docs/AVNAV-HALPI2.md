# AvNav on HALPI2

This document records the HALPI2 AvNav deployment and the fixes needed for
O-ChartsNG and Signal K when AvNav is opened through the HaLOS HTTPS proxy.

## Current deployment

- HaLOS app package: `marine-avnav-container_20260709-12_all.deb`
- AvNav image: `stangsdal/avnav-daily:20260709-https9`
- AvNav service: `marine-avnav-container`
- AvNav URL: `https://halos.local:4431/viewer/avnav_viewer.html`
- O-ChartsNG URL: `https://halos.local:4431/ocharts/static/index.html`
- Signal K URL: `https://halos.local:4430/`

The image is ARM64 and is built on the development Mac. HALPI2 is a test and
deployment device only; it must not be used to compile or build the image.

## What was fixed

### O-ChartsNG

- The official ARM64 provider from the AvNav base image is used.
- `oexserverd` and `libpreload.so` are included in the image.
- The container runs as root and is privileged so O-ChartsNG can access the
  SG-Lock USB/HID dongle (normally `/dev/hidraw0`).
- The provider UI is exposed through the authenticated HTTPS path `/ocharts/`
  instead of exposing its internal HTTP port directly.
- Provider links are rewritten to relative `/ocharts/...` URLs. This prevents
  browser mixed-content failures and keeps chart downloads behind the proxy.
- The provider app URL and AvNav WebSocket URL use HTTPS/WSS when AvNav is
  opened through HaLOS HTTPS.

### Signal K

AvNav uses the Docker host name `host.docker.internal` for its backend
connection to Signal K on port 3000. This is intentionally HTTP inside the
Docker network. The browser-facing Signal K app link is instead rewritten to
the HaLOS HTTPS entrypoint on port 4430. This avoids a mixed-content block
while keeping the backend connection local.

## Build and deploy

From the repository root on the development Mac:

```sh
docker build --platform linux/arm64 \
  -t stangsdal/avnav-daily:20260709-https9 \
  apps/avnav

docker run --rm \
  -v "$PWD:/workspace" \
  -e CONTAINER_TOOLS_REF=v0.10.0+1 \
  halos-marine-containers-builder \
  bash -lc 'cd /workspace && uvx --from git+https://github.com/halos-org/container-packaging-tools.git@v0.10.0+1 generate-container-packages -o build/avnav-only --prefix marine apps/avnav'
```

When the image is not available from a registry, transfer it directly to
HALPI2 without building there:

```sh
docker save stangsdal/avnav-daily:20260709-https9 | gzip | \
  ssh peter@192.168.1.181 'gunzip | docker load'
scp build/avnav-only/marine-avnav-container_20260709-12_all.deb \
  peter@192.168.1.181:/tmp/
```

Install the package on HALPI2 using the normal HaLOS package workflow. The
package installer preserves a backup of the generated Compose file before
applying the update. Restart the managed service rather than running Compose
manually:

```sh
sudo systemctl restart marine-avnav-container
sudo systemctl is-active marine-avnav-container
sudo docker ps --filter name=avnav
```

## Verification

Check the container and the two proxied applications:

```sh
sudo docker inspect --format '{{.Config.Image}} {{.State.Status}} {{.State.Health.Status}}' avnav
curl -kI https://halos.local:4431/viewer/avnav_viewer.html
curl -kI https://halos.local:4431/ocharts/static/index.html
curl -kI https://halos.local:4430/
```

In AvNav, confirm that the O-ChartsNG provider is connected and that the
SG-Lock dongle is detected. Then open the Signal K integration and confirm
that its browser page opens on `https://halos.local:4430/` rather than an
internal HTTP or `host.docker.internal` URL.

## Troubleshooting and rollback

- A browser error mentioning mixed content normally means that a generated
  link still points to `http://halos.local:8083` or `http://host.docker.internal`.
- A `502` on `/ocharts/status/` means that the provider is not listening on
  port 8083; inspect `sudo docker logs avnav` and the container health status.
- A missing dongle usually means that `/dev/hidraw*` is absent or permissions
  changed. Check `ls -l /dev/hidraw*` on HALPI2 and the container's privileged
  setting before changing application code.
- Do not edit the generated Compose file as the permanent fix. Change
  `apps/avnav/docker-compose.yml`, `apps/avnav/Dockerfile`, or
  `apps/avnav/prestart.sh`, rebuild the package/image, and reinstall through
  the managed service.
- Before a manual recovery, copy the current Compose file. The package
  installer also creates timestamped `*.before-*` backups in
  `/var/lib/container-apps/marine-avnav-container/`.
