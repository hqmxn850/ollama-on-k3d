#!/usr/bin/env python3
"""
AMD XDNA NPU Power Mode Control Utility
Allows querying and configuring the power mode of AMD XDNA NPU devices via DRM ioctl.

Power modes:
  0: DEFAULT (Calculated DPM)
  1: LOW (Lowest DPM)
  2: MEDIUM (Medium DPM)
  3: HIGH (Highest DPM)
  4: TURBO (Maximum power / performance)
"""

import ctypes
import fcntl
import os
import struct
import sys

MODE_MAP = {
    "0": 0, "default": 0,
    "1": 1, "low": 1,
    "2": 2, "med": 2, "medium": 2,
    "3": 3, "high": 3,
    "4": 4, "turbo": 4,
}

MODE_NAMES = {
    0: "DEFAULT",
    1: "LOW",
    2: "MEDIUM",
    3: "HIGH",
    4: "TURBO",
}

IOC_TYPE = ord("d")
IOC_DIR = 3
IOC_SIZE = 16
GET_INFO_IOCTL = (IOC_DIR << 30) | (IOC_SIZE << 16) | (IOC_TYPE << 8) | 0x47
SET_STATE_IOCTL = (IOC_DIR << 30) | (IOC_SIZE << 16) | (IOC_TYPE << 8) | 0x48

def get_power_mode(fd):
    buf = ctypes.create_string_buffer(8)
    addr = ctypes.addressof(buf)
    req = struct.pack("IIQ", 9, 8, addr)  # DRM_AMDXDNA_GET_POWER_MODE = 9
    fcntl.ioctl(fd, GET_INFO_IOCTL, req)
    return buf.raw[0]

def set_power_mode(fd, mode):
    buf_set = ctypes.create_string_buffer(struct.pack("B7x", mode))
    addr_set = ctypes.addressof(buf_set)
    req_set = struct.pack("IIQ", 0, 8, addr_set)  # DRM_AMDXDNA_SET_POWER_MODE = 0
    fcntl.ioctl(fd, SET_STATE_IOCTL, req_set)

def main():
    if len(sys.argv) < 2:
        print("Usage: npu-power-mode.py <get|set> [mode] [dev_path]")
        sys.exit(1)

    action = sys.argv[1].lower()
    mode_arg = sys.argv[2] if len(sys.argv) > 2 else "TURBO"
    dev_path = sys.argv[3] if len(sys.argv) > 3 else os.environ.get("ACCEL_DEVICE_PATH", "/dev/accel")

    if os.path.isdir(dev_path):
        dev_path = os.path.join(dev_path, "accel0")

    if not os.path.exists(dev_path):
        print(f"NPU device not found: {dev_path}")
        sys.exit(0)

    try:
        fd = os.open(dev_path, os.O_RDWR)
    except PermissionError:
        print(f"Permission denied accessing {dev_path} (root / sudo privileges required)", file=sys.stderr)
        sys.exit(2)
    except Exception as e:
        print(f"Error opening {dev_path}: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        curr_mode = get_power_mode(fd)
        curr_name = MODE_NAMES.get(curr_mode, f"UNKNOWN({curr_mode})")

        if action == "get":
            print(f"power_mode={curr_mode} ({curr_name})")
            sys.exit(0)

        elif action == "set":
            target_mode = MODE_MAP.get(str(mode_arg).lower())
            if target_mode is None:
                print(f"Invalid power mode: {mode_arg}. Valid values: 0/DEFAULT, 1/LOW, 2/MED, 3/HIGH, 4/TURBO", file=sys.stderr)
                sys.exit(1)

            target_name = MODE_NAMES.get(target_mode, f"UNKNOWN({target_mode})")
            if curr_mode == target_mode:
                print(f"NPU power mode is already set to {target_name} ({target_mode})")
                sys.exit(0)

            try:
                set_power_mode(fd, target_mode)
                new_mode = get_power_mode(fd)
                new_name = MODE_NAMES.get(new_mode, f"UNKNOWN({new_mode})")
                print(f"NPU power mode successfully changed: {curr_name} ({curr_mode}) -> {new_name} ({new_mode})")
            except OSError as e:
                if e.errno == 22:  # EINVAL
                    print(f"Failed to set power mode to {target_name} ({target_mode}): Device returned EINVAL (active contexts like FastFlowLM must be stopped first)", file=sys.stderr)
                else:
                    print(f"Failed to set power mode: {e}", file=sys.stderr)
                sys.exit(1)
        else:
            print(f"Unknown action: {action}", file=sys.stderr)
            sys.exit(1)

    finally:
        os.close(fd)

if __name__ == "__main__":
    main()
