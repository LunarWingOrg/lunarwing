# Podman Rootless Deployment Guide

This guide covers deploying the OCR sidecar with rootless Podman.

## Prerequisites

- Podman 4.3+ (for `--health-on-failure` support)
- Podman 4.7+ (for native `podman compose` - recommended)
- `podman-compose` (alternative for older Podman versions)
- Tesseract OCR installed on the host (optional, for local development)

## Quick Start

### Using Podman Compose (Recommended)

```bash
# Build and start
podman compose up --build -d

# Check health
podman inspect lunarwing-ocr-sidecar --format '{{.State.Health.Status}}'

# View logs
podman logs -f lunarwing-ocr-sidecar

# Stop
podman compose down
```

### Using Podman Run

```bash
# Build the image
podman build -t lunarwing/vision-service .

# Run with healthcheck auto-restart (Podman 4.3+)
podman run -d \
  --name lunarwing-ocr-sidecar \
  --health-on-failure=restart \
  -p 8088:8088 \
  -e LUNARWING_AUTH_TOKEN=your-secret-token \
  -v ocr_cache:/app/cache \
  lunarwing/vision-service

# Check health
podman inspect lunarwing-ocr-sidecar --format '{{.State.Health.Status}}'
```

## Systemd Integration (Rootless)

### Install the User Unit

```bash
# Copy the unit file to your user systemd directory
mkdir -p ~/.config/systemd/user
cp init-templates/ocr-sidecar.service ~/.config/systemd/user/

# Reload systemd
systemctl --user daemon-reload

# Enable and start
systemctl --user enable --now ocr-sidecar.service

# Check status
systemctl --user status ocr-sidecar.service
```

### Enable Lingering (Optional)

To keep the service running after logout:

```bash
sudo loginctl enable-linger $USER
```

## OpenRC Integration

```bash
# Install the init script
sudo cp init-templates/ocr-sidecar /etc/init.d/
sudo chmod +x /etc/init.d/ocr-sidecar

# Add to default runlevel
sudo rc-update add ocr-sidecar default

# Start the service
sudo rc-service ocr-sidecar start

# Check status
sudo rc-service ocr-sidecar status
```

## Health Monitoring

### Podman Health Status

```bash
# Check container health
podman inspect lunarwing-ocr-sidecar --format '{{.State.Health.Status}}'
# Output: healthy | unhealthy | starting | ""

# View health logs
podman inspect lunarwing-ocr-sidecar --format '{{json .State.Health}}' | jq
```

### Prometheus Metrics

```bash
# Scrape metrics endpoint
curl http://localhost:8088/metrics
```

### Health Check Endpoint

```bash
curl http://localhost:8088/health
```

## Rootless Podman Considerations

### Port Binding

Rootless Podman can bind to ports ≥ 1024 without privileges. Port 8088 works fine.

### User Namespaces

The container runs in a user namespace. The sidecar listens on `0.0.0.0:8088` inside the container, which maps to the host's non-privileged port.

### Volume Ownership

Volumes are owned by the user running Podman. No special permissions needed.

### Socket Path

Rootless Podman uses `~/.config/containers/podman.sock` instead of `/var/run/docker.sock`.

## Troubleshooting

### Health Check Failing

```bash
# Check if curl is in the container
podman exec lunarwing-ocr-sidecar which curl

# Manually test the health endpoint
podman exec lunarwing-ocr-sidecar curl -f http://localhost:8088/health
```

### Permission Denied on Port

If you see permission errors binding to port 8088:

```bash
# Check if port is in use
ss -tlnp | grep 8088

# Kill the process or use a different port
podman compose down
podman compose up -d
```

### Container Won't Start After Unhealthy

Podman doesn't auto-restart unhealthy containers by default. Options:

1. **Use `--health-on-failure=restart`** (Podman 4.3+):
   ```bash
   podman run --health-on-failure=restart ...
   ```

2. **Use systemd** (recommended for production):
   The systemd unit has `Restart=on-failure` which handles this.

3. **Use the LunarWing self-heal watchdog**:
   The watchdog monitors health and restarts unhealthy services.

## Migration from Docker

If you're migrating from Docker:

```bash
# Stop Docker containers
docker-compose down

# Remove Docker images (optional)
docker rmi lunarwing/vision-service

# Start with Podman
podman compose up -d
```

The compose file is compatible with both Docker and Podman.

## Environment Variables

All environment variables from the Docker deployment work with Podman:

- `LUNARWING_AUTH_TOKEN` - Required authentication token
- `VL_URL` - Vision language model endpoint
- `VL_API_KEY` - Vision language API key
- `VL_MODEL` - Vision language model name
- `VL_TIMEOUT_SECS` - Vision language request timeout
- `ENABLE_PADDLEOCR` - Enable PaddleOCR fallback
- `ENABLE_CACHE` - Enable response caching
- `ENABLE_PROMETHEUS` - Enable Prometheus metrics endpoint
- `RATE_LIMIT_PER_SECOND` - Request rate limit

Set them in `/etc/lunarwing/ocr-sidecar.env` or pass via `-e` flags.

## Security Notes

- Rootless Podman is more secure than rootful Docker
- The container runs as a non-root user
- No Docker daemon socket exposure
- User namespace isolation
- Seccomp and AppArmor profiles enabled by default

## Performance

Podman is generally faster than Docker for:
- Container startup (no daemon overhead)
- Image pulls (parallel layer downloads)
- Health checks (direct process inspection)

Memory usage is similar or slightly lower than Docker.
