# Release Process

This document describes how to publish a new release of the Geogram ESP32 firmware.

## Prerequisites

- PlatformIO installed
- GitHub CLI (`gh`) authenticated
- Device connected for build verification

## Steps

### 1. Build the firmware

```bash
pio run -e esp32c3_mini
```

Verify the build succeeds and check the binary:
```bash
ls -la .pio/build/esp32c3_mini/firmware.bin
```

### 2. Test on device (optional but recommended)

```bash
pio run -e esp32c3_mini -t upload
```

### 3. Commit changes

```bash
git add -A
git commit -m "Your commit message"
git push
```

### 4. Determine version number

Check existing tags:
```bash
git tag --list | tail -5
```

Increment appropriately (e.g., v1.2.0 → v1.3.0).

### 5. Create the release

```bash
gh release create vX.Y.Z \
  --repo geograms/geogram-esp32 \
  --title "vX.Y.Z" \
  --notes "Release notes here"
```

### 6. Upload firmware binary

Due to shell compatibility issues with `gh release upload`, use curl:

```bash
TOKEN=$(gh auth token)
RELEASE_ID=$(gh api repos/geograms/geogram-esp32/releases/tags/vX.Y.Z --jq '.id')

curl -X POST \
  -H "Authorization: token $TOKEN" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @.pio/build/esp32c3_mini/firmware.bin \
  "https://uploads.github.com/repos/geograms/geogram-esp32/releases/${RELEASE_ID}/assets?name=geogram-esp32c3-mini-firmware.bin"
```

### 7. Update release notes (optional)

```bash
gh release edit vX.Y.Z --repo geograms/geogram-esp32 --notes "$(cat <<'EOF'
## Changes
- Change 1
- Change 2

## ESP32-C3 Mini Binary
- `geogram-esp32c3-mini-firmware.bin` - Main firmware

### Flash with esptool:
```bash
esptool.py --chip esp32c3 --port /dev/ttyUSB0 write_flash 0x10000 geogram-esp32c3-mini-firmware.bin
```
EOF
)"
```

### 8. Verify release

```bash
gh release view vX.Y.Z --repo geograms/geogram-esp32
```

## Notes

- Only the `firmware.bin` is needed for releases (bootloader and partitions are not required)
- The firmware is flashed at address `0x10000`
- Users with fresh devices should use the full PlatformIO build which includes bootloader and partitions
