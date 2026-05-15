#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2026 M. "Harumajati" Alfarozi
#
# Environment Setup Script for Unified Build System
# Usage: curl -sL <link> | bash

set -e

REPO_URL="https://github.com/Reinazhard/kernel_build"
TARGET_DIR="build-kernel"
CWD=$(pwd)

echo "=================================================="
echo "  Kernel Build System Setup"
echo "=================================================="

# 1. Clone the repository
if [ -d "$TARGET_DIR" ]; then
    echo "[*] Updating existing build system in $TARGET_DIR..."
    (cd "$TARGET_DIR" && git pull)
else
    echo "[*] Cloning build system into $TARGET_DIR..."
    git clone "$REPO_URL" "$TARGET_DIR"
fi

# 2. Create Symlinks
echo "[*] Creating symlinks..."
ln -sf "$TARGET_DIR/build.sh" "build.sh"
ln -sf "$TARGET_DIR/build.env" "build.env"
ln -sf "$TARGET_DIR/build_utils.sh" "build_utils.sh"

# 3. Tool Availability Verification
validate_environment() {
    echo "[*] Validating build tools..."
    local tools_dir="$CWD/$TARGET_DIR/tools"
    local required_tools=("mkbootimg" "mkdtboimg" "avbtool" "depmod" "mke2fs")
    
    # Temporarily add tools dir to PATH for validation
    local OLD_PATH="$PATH"
    export PATH="$tools_dir:$PATH"

    local missing_tools=()
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        echo "[!] Error: The following required tools are missing in $tools_dir:"
        for tool in "${missing_tools[@]}"; do
            echo "    - $tool"
        done
        export PATH="$OLD_PATH"
        exit 1
    fi
    
    echo "    [+] All required tools found."
    export PATH="$OLD_PATH"
}

validate_environment

echo "=================================================="
echo "  Setup Complete."
echo "  Enjoy Building the Kernel!"
echo "=================================================="
