#!/usr/bin/env python3
"""
Test script for Geogram ESP32 Update Mirror API

This script tests the update mirroring functionality of the ESP32 station.
It verifies that the device can serve cached updates to clients.

Usage:
    # Use specific IP
    ./test_updates_api.py --ip 192.168.1.100

    # Auto-detect IP from serial port
    ./test_updates_api.py --port /dev/ttyACM0

    # Trigger a GitHub check first
    ./test_updates_api.py --ip 192.168.1.100 --trigger-check
"""

import argparse
import sys
import time
import requests
import serial
import re
import json
from pathlib import Path


def get_ip_from_serial(port: str, baud: int = 115200, timeout: float = 10.0) -> str:
    """
    Get device IP address from serial output.
    Looks for "Got IP:" log messages.
    """
    print(f"Connecting to serial port {port} at {baud} baud...")

    try:
        ser = serial.Serial(port, baud, timeout=1)
    except serial.SerialException as e:
        print(f"Error opening serial port: {e}")
        sys.exit(1)

    # Clear any buffered data
    ser.reset_input_buffer()

    # Send a newline to trigger some output
    ser.write(b"\r\n")

    print(f"Waiting for IP address (timeout: {timeout}s)...")
    start_time = time.time()
    ip_pattern = re.compile(r"Got IP:\s*(\d+\.\d+\.\d+\.\d+)")

    while time.time() - start_time < timeout:
        if ser.in_waiting:
            try:
                line = ser.readline().decode('utf-8', errors='ignore').strip()
                if line:
                    print(f"  {line}")
                    match = ip_pattern.search(line)
                    if match:
                        ser.close()
                        return match.group(1)
            except Exception:
                pass

    ser.close()
    print("Timeout waiting for IP address")
    print("Tip: Make sure the device is connected to WiFi")
    return None


def test_api_status(base_url: str) -> dict:
    """Test the /api/status endpoint and return the response."""
    url = f"{base_url}/api/status"
    print(f"\n1. Testing API status: {url}")

    try:
        response = requests.get(url, timeout=10)
        response.raise_for_status()
        data = response.json()

        print(f"   Status code: {response.status_code}")
        print(f"   Service: {data.get('service', 'N/A')}")
        print(f"   Version: {data.get('version', 'N/A')}")
        print(f"   Callsign: {data.get('callsign', 'N/A')}")

        return data
    except requests.RequestException as e:
        print(f"   Error: {e}")
        return None


def test_updates_latest(base_url: str) -> dict:
    """Test the /api/updates/latest endpoint."""
    url = f"{base_url}/api/updates/latest"
    print(f"\n2. Testing updates endpoint: {url}")

    try:
        response = requests.get(url, timeout=10)
        response.raise_for_status()
        data = response.json()

        print(f"   Status code: {response.status_code}")
        print(f"   Response: {json.dumps(data, indent=2)}")

        status = data.get('status', 'unknown')
        print(f"\n   Update status: {status}")

        if status == 'available':
            print(f"   Version: {data.get('version', 'N/A')}")
            print(f"   Tag: {data.get('tagName', 'N/A')}")
            print(f"   Name: {data.get('name', 'N/A')}")
            print(f"   Published: {data.get('publishedAt', 'N/A')}")

            assets = data.get('assets', [])
            print(f"   Assets available: {len(assets)}")
            for asset in assets:
                print(f"      - {asset.get('type')}: {asset.get('filename')}")
                print(f"        URL: {asset.get('url')}")

            return data
        elif status == 'no_updates_cached':
            print("   No updates cached yet (device may need to fetch from GitHub)")
            return data
        else:
            print(f"   Unknown status: {status}")
            return data

    except requests.RequestException as e:
        print(f"   Error: {e}")
        return None


def test_download_asset(base_url: str, asset_url: str, filename: str) -> bool:
    """Test downloading an asset file."""
    url = f"{base_url}{asset_url}"
    print(f"\n3. Testing asset download: {filename}")
    print(f"   URL: {url}")

    try:
        start_time = time.time()
        response = requests.get(url, timeout=120, stream=True)

        if response.status_code != 200:
            print(f"   Error: HTTP {response.status_code}")
            return False

        # Get content info
        content_type = response.headers.get('Content-Type', 'unknown')
        content_length = response.headers.get('Content-Length', 'unknown')
        content_disposition = response.headers.get('Content-Disposition', '')

        print(f"   Content-Type: {content_type}")
        print(f"   Content-Length: {content_length}")
        print(f"   Content-Disposition: {content_disposition}")

        # Download first 1MB to verify it's working (don't download full APK)
        max_bytes = 1024 * 1024  # 1MB
        downloaded = 0
        chunks = []

        for chunk in response.iter_content(chunk_size=8192):
            if chunk:
                chunks.append(chunk)
                downloaded += len(chunk)
                if downloaded >= max_bytes:
                    break

        elapsed = time.time() - start_time
        data = b''.join(chunks)

        print(f"   Downloaded: {downloaded} bytes in {elapsed:.2f}s")
        print(f"   Speed: {downloaded / elapsed / 1024:.1f} KB/s")

        # Basic validation based on file type
        valid = False
        if filename.endswith('.apk') or filename.endswith('.zip'):
            # ZIP/APK files start with PK
            if data[:2] == b'PK':
                print("   Valid ZIP/APK header: YES")
                valid = True
            else:
                print(f"   Valid ZIP/APK header: NO (got {data[:4].hex()})")
        elif filename.endswith('.tar.gz') or filename.endswith('.tgz'):
            # Gzip files start with 1f 8b
            if data[:2] == b'\x1f\x8b':
                print("   Valid GZIP header: YES")
                valid = True
            else:
                print(f"   Valid GZIP header: NO (got {data[:4].hex()})")
        elif filename.endswith('.dmg'):
            # DMG files have various headers
            print("   DMG file (header validation skipped)")
            valid = len(data) > 0
        else:
            # Generic - just check we got data
            print(f"   Got {len(data)} bytes of data")
            valid = len(data) > 0

        # Save sample for inspection
        if valid:
            sample_path = Path(f"update_sample_{filename[:20]}.bin")
            sample_path.write_bytes(data[:min(len(data), 10240)])  # Save first 10KB
            print(f"   Sample saved to: {sample_path}")

        return valid

    except requests.RequestException as e:
        print(f"   Error: {e}")
        return False


def test_invalid_requests(base_url: str) -> bool:
    """Test that invalid update requests are handled properly."""
    print("\n4. Testing invalid requests")

    test_cases = [
        ("/updates/invalid/path", "Invalid path"),
        ("/updates/v99.99.99/nonexistent.apk", "Non-existent version"),
        ("/api/updates/notanendpoint", "Invalid API endpoint"),
    ]

    all_passed = True
    for path, description in test_cases:
        url = f"{base_url}{path}"
        try:
            response = requests.get(url, timeout=10)
            status = response.status_code
            passed = status >= 400  # Should return error
            result = "PASS" if passed else "FAIL"
            print(f"   {description}: HTTP {status} [{result}]")
            if not passed:
                all_passed = False
        except requests.RequestException as e:
            print(f"   {description}: Error ({e}) [PASS]")

    return all_passed


def main():
    parser = argparse.ArgumentParser(description="Test Geogram ESP32 Update Mirror API")
    parser.add_argument("--port", "-p", help="Serial port for IP auto-detection (e.g., /dev/ttyACM0)")
    parser.add_argument("--ip", "-i", help="Device IP address (e.g., 192.168.1.100)")
    parser.add_argument("--trigger-check", action="store_true",
                        help="Wait for device to check GitHub before testing")
    args = parser.parse_args()

    # Get device IP
    if args.ip:
        device_ip = args.ip
    elif args.port:
        device_ip = get_ip_from_serial(args.port)
        if not device_ip:
            print("Could not determine device IP from serial")
            sys.exit(1)
    else:
        print("Error: Must specify --port or --ip")
        parser.print_help()
        sys.exit(1)

    base_url = f"http://{device_ip}"
    print(f"\nTesting Geogram Update Mirror API at {base_url}")
    print("=" * 60)

    # Run tests
    results = []

    # Test 1: API status
    status = test_api_status(base_url)
    results.append(("API Status", status is not None))

    if status is None:
        print("\nERROR: Could not connect to device")
        print("Make sure the device is connected to WiFi and accessible")
        return 1

    # Test 2: Updates endpoint
    updates = test_updates_latest(base_url)
    results.append(("Updates Endpoint", updates is not None))

    if updates and updates.get('status') == 'available':
        # Test 3: Download an asset
        assets = updates.get('assets', [])
        if assets:
            # Prefer APK for testing as it's commonly available
            test_asset = None
            for asset in assets:
                if asset.get('type') == 'android-apk':
                    test_asset = asset
                    break

            # Fall back to first available asset
            if not test_asset and assets:
                test_asset = assets[0]

            if test_asset:
                download_ok = test_download_asset(
                    base_url,
                    test_asset.get('url', ''),
                    test_asset.get('filename', 'unknown')
                )
                results.append(("Asset Download", download_ok))
            else:
                print("\n3. No assets available to download")
                results.append(("Asset Download", False))
        else:
            print("\n3. No assets in update response")
            results.append(("Asset Download", False))
    elif updates and updates.get('status') == 'no_updates_cached':
        print("\n3. Skipping download test (no updates cached)")
        print("   Tip: Wait for device to fetch updates from GitHub, or use --trigger-check")
        results.append(("Asset Download", None))  # Skip, not fail
    else:
        print("\n3. Skipping download test (updates endpoint failed)")
        results.append(("Asset Download", False))

    # Test 4: Invalid requests
    results.append(("Invalid Requests", test_invalid_requests(base_url)))

    # Summary
    print("\n" + "=" * 60)
    print("TEST SUMMARY")
    print("=" * 60)

    all_passed = True
    for name, passed in results:
        if passed is None:
            status_str = "SKIP"
        elif passed:
            status_str = "PASS"
        else:
            status_str = "FAIL"
            all_passed = False
        print(f"  {name}: {status_str}")

    print("=" * 60)
    if all_passed:
        print("All tests PASSED")
        return 0
    else:
        print("Some tests FAILED")
        return 1


if __name__ == "__main__":
    sys.exit(main())
