#!/bin/bash
# Bounded serial capture for ESP32 devices
# Safe for automation/Claude use - automatically terminates after duration or line limit
#
# Usage:
#   ./monitor-capture.sh              # Capture 10 seconds (max 1000 lines)
#   ./monitor-capture.sh -t 5         # Capture 5 seconds
#   ./monitor-capture.sh -n 100       # Capture max 100 lines
#   ./monitor-capture.sh -t 30 -n 500 # Capture up to 30s OR 500 lines
#   ./monitor-capture.sh /dev/ttyACM0 # Specify port explicitly

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Defaults
DURATION=10
MAX_LINES=1000
BAUD=115200
PORT=""
RESET=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--time)
            DURATION="$2"
            shift 2
            ;;
        -n|--lines)
            MAX_LINES="$2"
            shift 2
            ;;
        -b|--baud)
            BAUD="$2"
            shift 2
            ;;
        -r|--reset)
            RESET=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options] [port]"
            echo ""
            echo "Options:"
            echo "  -t, --time SECONDS   Capture duration (default: 10)"
            echo "  -n, --lines COUNT    Max lines to capture (default: 1000)"
            echo "  -b, --baud RATE      Baud rate (default: 115200)"
            echo "  -r, --reset          Reset ESP32 before capture (see boot logs)"
            echo "  -h, --help           Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                   # 10 seconds, max 1000 lines"
            echo "  $0 -t 5              # 5 seconds"
            echo "  $0 -n 100            # Max 100 lines"
            echo "  $0 -t 30 -n 500      # 30s or 500 lines, whichever first"
            echo "  $0 -r -t 15          # Reset device, capture 15s of boot logs"
            echo "  $0 /dev/ttyACM0      # Specify port"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            PORT="$1"
            shift
            ;;
    esac
done

# Auto-detect port if not specified
if [ -z "$PORT" ]; then
    # Try to find any ttyACM device (ESP32-S3 built-in USB)
    PORT=$(ls /dev/ttyACM* 2>/dev/null | head -1)

    # Fall back to ttyUSB if no ttyACM found
    if [ -z "$PORT" ]; then
        PORT=$(ls /dev/ttyUSB* 2>/dev/null | head -1)
    fi

    if [ -z "$PORT" ]; then
        echo "Error: No serial port found. Please specify port as argument."
        exit 1
    fi
fi

# Check if port exists
if [ ! -e "$PORT" ]; then
    echo "Error: Port $PORT does not exist"
    exit 1
fi

echo "=== Serial Capture (bounded) ==="
echo "Port: $PORT | Baud: $BAUD | Duration: ${DURATION}s | Max lines: $MAX_LINES"
if [ "$RESET" = true ]; then
    echo "Reset: YES"
fi
echo "---"

# Use Python for reliable serial capture (pio device monitor has buffering issues)
python3 << EOF
import serial
import time
import sys

port = serial.Serial('$PORT', $BAUD, timeout=0.1)
reset = $( [ "$RESET" = true ] && echo "True" || echo "False" )
duration = $DURATION
max_lines = $MAX_LINES

# Reset ESP32 if requested (toggle DTR/RTS lines)
if reset:
    port.dtr = False
    port.rts = True
    time.sleep(0.1)
    port.dtr = True
    port.rts = False

# Read serial output
start = time.time()
line_count = 0
buffer = ""

try:
    while time.time() - start < duration and line_count < max_lines:
        data = port.read(1024)
        if data:
            text = data.decode('utf-8', errors='replace')
            buffer += text
            # Process complete lines
            while '\n' in buffer:
                line, buffer = buffer.split('\n', 1)
                print(line)
                sys.stdout.flush()
                line_count += 1
                if line_count >= max_lines:
                    break
except KeyboardInterrupt:
    pass
finally:
    # Print any remaining partial line
    if buffer and line_count < max_lines:
        print(buffer)
    port.close()

# Report why we stopped
print("---")
if line_count >= max_lines:
    print(f"(Captured {line_count} lines, line limit reached)")
else:
    elapsed = time.time() - start
    print(f"(Captured {line_count} lines in {elapsed:.1f}s, time limit reached)")
EOF
