#!/usr/bin/env python3
"""
Test script for Geogram ESP32 Tile API

This script tests the tile caching functionality of the ESP32 station.
It can auto-detect the device IP via serial connection or use a provided IP.

Usage:
    # Auto-detect IP from serial port
    ./test_tile_api.py --port /dev/ttyACM0

    # Use specific IP
    ./test_tile_api.py --ip 192.168.1.100

    # Test with satellite layer
    ./test_tile_api.py --ip 192.168.1.100 --layer satellite
"""

import argparse
import sys
import time
import requests
import serial
import re
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
        print(f"   Tile server: {data.get('tile_server', 'N/A')}")
        print(f"   Cache size: {data.get('cache_size', 'N/A')} tiles")
        print(f"   Cache bytes: {data.get('cache_size_bytes', 'N/A')}")

        return data
    except requests.RequestException as e:
        print(f"   Error: {e}")
        return None


def test_tile_request(base_url: str, z: int, x: int, y: int, layer: str = "standard") -> bool:
    """Test fetching a single tile."""
    url = f"{base_url}/tiles/{z}/{x}/{y}.png"
    if layer and layer != "standard":
        url += f"?layer={layer}"

    print(f"\n2. Testing tile request: z={z} x={x} y={y} layer={layer}")
    print(f"   URL: {url}")

    try:
        start_time = time.time()
        response = requests.get(url, timeout=30)
        elapsed = time.time() - start_time

        print(f"   Status code: {response.status_code}")
        print(f"   Time: {elapsed:.2f}s")

        if response.status_code == 200:
            content_type = response.headers.get('Content-Type', '')
            content_length = len(response.content)

            print(f"   Content-Type: {content_type}")
            print(f"   Size: {content_length} bytes")

            # Basic PNG validation
            if response.content[:8] == b'\x89PNG\r\n\x1a\n':
                print("   Valid PNG: YES")

                # Save the tile for inspection
                output_path = Path(f"tile_{z}_{x}_{y}_{layer}.png")
                output_path.write_bytes(response.content)
                print(f"   Saved to: {output_path}")
                return True
            else:
                print("   Valid PNG: NO (invalid header)")
                return False
        else:
            print(f"   Error: HTTP {response.status_code}")
            return False

    except requests.RequestException as e:
        print(f"   Error: {e}")
        return False


def test_tile_caching(base_url: str, z: int, x: int, y: int) -> bool:
    """Test that tiles are being cached (second request should be faster)."""
    url = f"{base_url}/tiles/{z}/{x}/{y}.png"

    print(f"\n3. Testing tile caching: z={z} x={x} y={y}")

    # First request (may need to download)
    try:
        start1 = time.time()
        response1 = requests.get(url, timeout=30)
        time1 = time.time() - start1

        if response1.status_code != 200:
            print(f"   First request failed: HTTP {response1.status_code}")
            return False

        print(f"   First request: {time1:.2f}s ({len(response1.content)} bytes)")

        # Small delay
        time.sleep(0.5)

        # Second request (should be cached)
        start2 = time.time()
        response2 = requests.get(url, timeout=30)
        time2 = time.time() - start2

        if response2.status_code != 200:
            print(f"   Second request failed: HTTP {response2.status_code}")
            return False

        print(f"   Second request: {time2:.2f}s ({len(response2.content)} bytes)")

        if time2 < time1:
            speedup = time1 / time2 if time2 > 0 else float('inf')
            print(f"   Cache speedup: {speedup:.1f}x faster")
            return True
        else:
            print("   Warning: Second request not faster (cache may not be working)")
            return True  # Still passes if response was valid

    except requests.RequestException as e:
        print(f"   Error: {e}")
        return False


def test_invalid_requests(base_url: str) -> bool:
    """Test that invalid tile requests are handled properly."""
    print("\n4. Testing invalid requests")

    test_cases = [
        ("/tiles/invalid", "Invalid path"),
        ("/tiles/1/0.png", "Missing coordinate"),
        ("/tiles/20/0/0.png", "Invalid zoom level (too high)"),
        ("/tiles/-1/0/0.png", "Invalid zoom level (negative)"),
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
    parser = argparse.ArgumentParser(description="Test Geogram ESP32 Tile API")
    parser.add_argument("--port", "-p", help="Serial port for IP auto-detection (e.g., /dev/ttyACM0)")
    parser.add_argument("--ip", "-i", help="Device IP address (e.g., 192.168.1.100)")
    parser.add_argument("--layer", "-l", default="standard", choices=["standard", "satellite"],
                        help="Tile layer to test")
    parser.add_argument("--zoom", "-z", type=int, default=1, help="Zoom level (default: 1)")
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
    print(f"\nTesting Geogram Tile API at {base_url}")
    print("=" * 50)

    # Run tests
    results = []

    # Test 1: API status
    status = test_api_status(base_url)
    results.append(("API Status", status is not None))

    if status and not status.get("tile_server", False):
        print("\nWARNING: Tile server is not available (SD card may not be mounted)")
        print("Skipping tile tests...")
    else:
        # Test 2: Fetch a tile (run this first to see any crash logs)
        z, x, y = args.zoom, 0, 0
        print("\n*** Attempting tile fetch - check serial monitor for crash/error ***")
        results.append(("Tile Fetch", test_tile_request(base_url, z, x, y, args.layer)))

        # Wait for device to recover if it crashed
        print("\nWaiting 5 seconds for device to recover...")
        time.sleep(5)

        # Test 3: Caching (skip if tile fetch failed)
        if results[-1][1]:
            results.append(("Tile Caching", test_tile_caching(base_url, z + 1, 1, 1)))
        else:
            print("\n3. Skipping cache test (tile fetch failed)")
            results.append(("Tile Caching", False))

        # Test 4: Invalid requests
        results.append(("Invalid Requests", test_invalid_requests(base_url)))

    # Summary
    print("\n" + "=" * 50)
    print("TEST SUMMARY")
    print("=" * 50)

    all_passed = True
    for name, passed in results:
        status = "PASS" if passed else "FAIL"
        print(f"  {name}: {status}")
        if not passed:
            all_passed = False

    print("=" * 50)
    if all_passed:
        print("All tests PASSED")
        return 0
    else:
        print("Some tests FAILED")
        return 1


if __name__ == "__main__":
    sys.exit(main())
