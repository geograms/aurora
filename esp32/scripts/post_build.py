Import("env")
import os
import shutil
import filecmp
import json
from datetime import datetime, timezone

def post_build_action(source, target, env):
    """
    Post-build script to rename firmware to custom name and sync to flasher downloads.
    """
    firmware_name = env.GetProjectOption("custom_firmware_name", "firmware")
    build_dir = env.subst("$BUILD_DIR")

    # Source files
    bin_src = os.path.join(build_dir, "firmware.bin")
    elf_src = os.path.join(build_dir, "firmware.elf")

    # Destination files
    output_dir = os.path.join(env.subst("$PROJECT_DIR"), "firmware")
    os.makedirs(output_dir, exist_ok=True)

    bin_dst = os.path.join(output_dir, f"{firmware_name}.bin")
    elf_dst = os.path.join(output_dir, f"{firmware_name}.elf")

    # Copy and rename
    if os.path.exists(bin_src):
        shutil.copy2(bin_src, bin_dst)
        print(f"[Geogram] Firmware copied to: {bin_dst}")

    if os.path.exists(elf_src):
        shutil.copy2(elf_src, elf_dst)
        print(f"[Geogram] ELF copied to: {elf_dst}")

    # Sync to flasher downloads if this board has a flasher entry
    flasher_model = env.GetProjectOption("custom_flasher_model", "")
    if flasher_model and os.path.exists(bin_dst):
        flasher_dir = os.path.join(
            env.subst("$PROJECT_DIR"), "..",
            "downloads", "flasher", "geogram", "esp32", flasher_model
        )
        flasher_bin = os.path.join(flasher_dir, "firmware.bin")
        if os.path.isdir(flasher_dir):
            if os.path.exists(flasher_bin) and filecmp.cmp(bin_dst, flasher_bin, shallow=False):
                print(f"[Geogram] Flasher firmware unchanged, skipping: {flasher_bin}")
            else:
                shutil.copy2(bin_dst, flasher_bin)
                print(f"[Geogram] Flasher firmware synced to: {flasher_bin}")
                # Update modified_at in device.json so the app detects the new firmware
                device_json_path = os.path.join(flasher_dir, "device.json")
                if os.path.exists(device_json_path):
                    with open(device_json_path, 'r') as f:
                        device_data = json.load(f)
                    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                    device_data["modified_at"] = now
                    with open(device_json_path, 'w') as f:
                        json.dump(device_data, f, indent=2)
                        f.write("\n")
                    print(f"[Geogram] Updated device.json modified_at to {now}")
        else:
            print(f"[Geogram] Warning: flasher dir not found: {flasher_dir}")

# Hook into the build process
env.AddPostAction("$BUILD_DIR/${PROGNAME}.bin", post_build_action)
