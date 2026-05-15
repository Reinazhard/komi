#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2026 M. "Harumajati" Alfarozi
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.

# Unified Build & Assembly Script
# Separates mechanism (this script) from configuration (build.env)
set -e

# --- Configuration & Environment Selection ---
CWD=$(pwd)
VERBOSE=0

# Priority: 1. Flag (-c/--config), 2. $BUILD_CONFIG env, 3. build.env in CWD
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            CLI_CONFIG="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL_ARGS[@]}"

if [ -n "$CLI_CONFIG" ]; then
    ENV_FILE="$CLI_CONFIG"
elif [ -n "$BUILD_CONFIG" ]; then
    ENV_FILE="$BUILD_CONFIG"
else
    ENV_FILE="$CWD/build.env"
fi

if [ -f "$ENV_FILE" ]; then
    echo "[*] Sourcing environment from $ENV_FILE"
    source "$ENV_FILE"
else
    echo "[!] Error: Configuration file $ENV_FILE not found."
    exit 1
fi

# Source build_utils.sh
if [ -f "$CWD/build_utils.sh" ]; then
    source "$CWD/build_utils.sh"
else
    echo "[!] Error: build_utils.sh not found in $CWD"
    exit 1
fi

# Set defaults for common variables if not in build.env
OUT_DIR="${OUT_DIR:-$CWD/out}"
DIST_DIR="${DIST_DIR:-$CWD/dist}"
STAGING_DIR="$OUT_DIR/staging"
MODULES_STAGING_DIR="$STAGING_DIR/modules"
VENDOR_DLKM_STAGING_DIR="$STAGING_DIR/vendor_dlkm"
SYSTEM_DLKM_STAGING_DIR="$STAGING_DIR/system_dlkm"
TOOLS_DIR="${AOSP_TOOLS_DIR:-$CWD/build-tools/linux_musl-x86/bin}"
JOBS=${JOBS:-$(nproc)}
ARCH="${ARCH:-arm64}"

# --- Toolchain Configuration ---
LLVM="${LLVM:-1}"
LLVM_IAS="${LLVM_IAS:-1}"
CROSS_COMPILE="${CROSS_COMPILE:-}"
CROSS_COMPILE_COMPAT="${CROSS_COMPILE_COMPAT:-}"

# Enforce mutual exclusivity:
# CROSS_COMPILE/COMPAT must be empty if LLVM/_IAS=1 is set, and vice versa.
if [ "$LLVM" -eq 1 ] || [ "$LLVM_IAS" -eq 1 ]; then
    CROSS_COMPILE=""
    CROSS_COMPILE_COMPAT=""
elif [ -n "$CROSS_COMPILE" ] || [ -n "$CROSS_COMPILE_COMPAT" ]; then
    LLVM=0
    LLVM_IAS=0
fi

# Define toolchain arguments for make
export PAHOLE="${TOOLS_DIR}/pahole"
TOOLCHAIN_ARGS="LLVM=$LLVM LLVM_IAS=$LLVM_IAS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_COMPAT=$CROSS_COMPILE_COMPAT PAHOLE=$PAHOLE"

export ROOT_DIR="$CWD"
export OUT_DIR
export DIST_DIR
export MODULES_STAGING_DIR
export VENDOR_DLKM_STAGING_DIR
export SYSTEM_DLKM_STAGING_DIR
export EXT_MODULES_MAKEFILE=1
export SYSTEM_DLKM_RE_SIGN="${SYSTEM_DLKM_RE_SIGN:-0}"

# AOSP Blocklists and Lists (populated by build.env)
export VENDOR_DLKM_MODULES_LIST
export SYSTEM_DLKM_MODULES_LIST
export VENDOR_BOOT_MODULES_LIST
export VENDOR_BOOT_MODULES_BLOCKLIST
export MODULES_RECOVERY_LIST
export MODULES_BLOCKLIST # Generic blocklist fallback if needed
export VENDOR_DLKM_MODULES_BLOCKLIST
export SYSTEM_DLKM_MODULES_BLOCKLIST

# AOSP Flatten image support
export SYSTEM_DLKM_GEN_FLATTEN_IMAGE="${SYSTEM_DLKM_GEN_FLATTEN_IMAGE:-0}"
export VENDOR_DLKM_GEN_FLATTEN_IMAGE="${VENDOR_DLKM_GEN_FLATTEN_IMAGE:-0}"

# --- Build Flags ---
BUILD_VENDOR_DLKM="${BUILD_VENDOR_DLKM:-1}"
BUILD_SYSTEM_DLKM="${BUILD_SYSTEM_DLKM:-1}"

# --- Reproducibility & Determinism ---
export KBUILD_BUILD_USER="komi-build"
export KBUILD_BUILD_HOST="kernel"
export KBUILD_BUILD_TIMESTAMP=$(date -u +%Y-%m-%d)

export PATH="$TOOLS_DIR:$PATH"
export LD_LIBRARY_PATH="$TOOLS_DIR/../lib64:$LD_LIBRARY_PATH"

echo "=================================================="
echo "  Kernel Out-of-tree Module Integration (KOMI)"
echo "  Device: ${DEVICE_NAME:-Unknown}"
echo "=================================================="

# --- Pre-flight Validation ---
validate_environment() {
    echo "  [*] Validating build configuration files..."
    local list_vars=("VENDOR_DLKM_MODULES_LIST" "SYSTEM_DLKM_MODULES_LIST" "VENDOR_BOOT_MODULES_LIST" "MODULES_RECOVERY_LIST" "MODULES_BLOCKLIST" "VENDOR_DLKM_MODULES_BLOCKLIST" "SYSTEM_DLKM_MODULES_BLOCKLIST" "VENDOR_BOOT_MODULES_BLOCKLIST")
    for var in "${list_vars[@]}"; do
        local file_path="${!var}"
        if [ -n "$file_path" ] && [ ! -f "$file_path" ]; then
             echo "  [!] Warning: $var points to missing file: $file_path"
        fi
    done
}

validate_environment

# --- Phase 0: Kernel Configuration ---
build_defconfig() {
    echo "[*] Phase 0: Configuring Kernel ($DEFCONFIG)..."
    make ARCH="$ARCH" O="$OUT_DIR" $TOOLCHAIN_ARGS $DEFCONFIG
}

save_defconfig() {
    if [[ "$DEFCONFIG" == *" "* ]]; then
        echo "[!] Error: save_defconfig is not supported when using multiple fragments."
        echo "    Current DEFCONFIG: $DEFCONFIG"
        exit 1
    fi
    echo "[*] Saving defconfig..."
    make ARCH="$ARCH" O="$OUT_DIR" $TOOLCHAIN_ARGS savedefconfig
    cp "$OUT_DIR/defconfig" "arch/$ARCH/configs/$DEFCONFIG"
}

# --- Phase 1: Kernel Compilation ---
build_kernel_image() {
    echo "[*] Phase 1a: Compiling Kernel Image..."
    make ARCH="$ARCH" O="$OUT_DIR" $TOOLCHAIN_ARGS \
         KCFLAGS="$KCFLAGS" \
         HOSTCFLAGS="$HOSTCFLAGS" \
         $EXTRA_KBUILD_FLAGS \
         -j"$JOBS" Image
}

build_dtbs() {
    echo "[*] Phase 1b: Compiling DTBs..."
    make ARCH="$ARCH" O="$OUT_DIR" $TOOLCHAIN_ARGS \
         KCFLAGS="$KCFLAGS" \
         HOSTCFLAGS="$HOSTCFLAGS" \
         $EXTRA_KBUILD_FLAGS \
         -j"$JOBS" dtbs
}

build_modules() {
    echo "[*] Phase 1c: Compiling In-Tree Modules..."
    make ARCH="$ARCH" O="$OUT_DIR" $TOOLCHAIN_ARGS \
         KCFLAGS="$KCFLAGS" \
         HOSTCFLAGS="$HOSTCFLAGS" \
         $EXTRA_KBUILD_FLAGS \
         -j"$JOBS" modules
}

# --- Phase 2: OOT Modules ---
build_oot_modules() {
    echo "[*] Phase 2: Compiling OOT Modules..."
    local symvers_files=""
    
    export KERNEL_SRC="$CWD"
    export KERNEL_ROOT="$CWD"
    export O="$OUT_DIR"
    export KBUILD_OUTPUT="$OUT_DIR"
    export MAKEFLAGS="O=$OUT_DIR $MAKEFLAGS"

    for entry in "${DLKM_SOURCES[@]}"; do
        IFS=':' read -r rel_src_path root_var <<< "$entry"
        local src_path="$CWD/$rel_src_path"
        
        if [ -d "$src_path" ]; then
            local mod_name=$(basename "$src_path")
            echo "  [+] Building OOT: $mod_name ($root_var)"
            
            if [ -z "$root_var" ]; then
                root_var=$(echo "$mod_name" | tr '-' '_' | tr '[:lower:]' '[:upper:]')_ROOT
            fi

            local root_val="$src_path"
            # Platform-specific root path adjustments should ideally be in build.env
            # but we keep this logic for compatibility with existing techpack structures
            if [[ "$root_var" == MSM_*_ROOT ]] || [[ "$root_var" == SYNC_FENCE_ROOT ]] || [[ "$root_var" == VIDEO_ROOT ]]; then
                root_val="$src_path/../"
            fi

            # Surgically extract KBUILD_OPTIONS from Makefile if it exists
            # to support modules that define their own configs there
            local makefile_opts=""
            local mk_extra_syms=""
            if [ -f "$src_path/Makefile" ]; then
                echo "  [+] Extracting options from Makefile..."
                # Wrapper Makefile to extract KBUILD_OPTIONS and KBUILD_EXTRA_SYMBOLS
                cat <<EOF > "$OUT_DIR/oot_wrapper.mk"
KERNEL_SRC := $CWD
KERNEL_ROOT := $CWD
M := $rel_src_path
$root_var := $root_val
include $src_path/Makefile
print_opts:
	@echo \$(KBUILD_OPTIONS)
print_syms:
	@echo \$(KBUILD_EXTRA_SYMBOLS)
EOF
                makefile_opts=$(make -s -f "$OUT_DIR/oot_wrapper.mk" print_opts 2>/dev/null || true)
                mk_extra_syms=$(make -s -f "$OUT_DIR/oot_wrapper.mk" print_syms 2>/dev/null || true)
                
                # Strip KBUILD_EXTRA_SYMBOLS from makefile_opts as we handle it separately
                makefile_opts=$(echo "$makefile_opts" | sed -E 's/KBUILD_EXTRA_SYMBOLS\s*[+:]?=[^ ]*//g')
                
                if [ "$VERBOSE" -eq 1 ]; then
                    echo "  [DEBUG] Extracted opts: $makefile_opts"
                    echo "  [DEBUG] Extracted syms: $mk_extra_syms"
                fi
            fi

            # Merge and de-duplicate extra symbols
            local -A unique_symvers
            # Add from Makefile
            for s in $mk_extra_syms; do
                # Handle relative paths in Makefile
                if [[ "$s" == /* ]]; then
                    unique_symvers["$s"]=1
                elif [[ -f "$CWD/$s" ]]; then
                    unique_symvers["$(realpath -m "$CWD/$s")"]=1
                else
                    unique_symvers["$(realpath -m "$src_path/$s")"]=1
                fi
            done
            # Add from our tracker
            for s in $symvers_files; do
                unique_symvers["$(realpath -m "$s")"]=1
            done

            local final_extra_symbols=""
            for s in "${!unique_symvers[@]}"; do
                final_extra_symbols+="${final_extra_symbols:+ }$s"
            done

            local extra_symbols_arg=""
            if [ -n "$final_extra_symbols" ]; then
                extra_symbols_arg="KBUILD_EXTRA_SYMBOLS=$final_extra_symbols"
            fi

            # Build the module
            make -C "$CWD" O="$OUT_DIR" M="$rel_src_path" \
                 KERNEL_SRC="$CWD" \
                 KERNEL_ROOT="$CWD" \
                 "$root_var"="$root_val" \
                 ARCH="$ARCH" $TOOLCHAIN_ARGS \
                 KCFLAGS="$KCFLAGS" \
                 $EXTRA_KBUILD_FLAGS \
                 $makefile_opts \
                 "$extra_symbols_arg" \
                 -j"$JOBS" modules

            # Track symvers for symbol propagation
            if [ -f "$OUT_DIR/$rel_src_path/Module.symvers" ]; then
                symvers_files="$symvers_files $OUT_DIR/$rel_src_path/Module.symvers"
                ln -sf "$OUT_DIR/$rel_src_path/Module.symvers" "$src_path/Module.symvers"
            fi
        else
            echo "  [!] Warning: Source directory $src_path not found. Skipping."
        fi
    done
}

build_kernel() {
    build_defconfig
    build_kernel_image
    build_dtbs
    build_modules
    build_oot_modules
}

# --- Phase 3: Module Splitting & Staging ---
stage_modules() {
    echo "[*] Phase 3: Staging Modules..."
    rm -rf "$MODULES_STAGING_DIR"
    mkdir -p "$MODULES_STAGING_DIR"

    make ARCH="$ARCH" O="$OUT_DIR" $TOOLCHAIN_ARGS \
         INSTALL_MOD_PATH="$MODULES_STAGING_DIR" modules_install
    
    # Get KVER reliably
    if [ -f "$OUT_DIR/include/config/kernel.release" ]; then
        KVER=$(cat "$OUT_DIR/include/config/kernel.release")
    else
        KVER=$(ls -1 "$MODULES_STAGING_DIR/lib/modules" 2>/dev/null | head -n 1 || true)
        if [ -z "$KVER" ] || [ "$KVER" == "*" ]; then
            KVER="unknown"
        fi
    fi

    # Ensure base, kernel, and extra directories exist to avoid find errors in build_utils.sh
    mkdir -p "$MODULES_STAGING_DIR/lib/modules/$KVER/kernel"
    mkdir -p "$MODULES_STAGING_DIR/lib/modules/$KVER/extra"
    
    # Touch necessary files to prevent missing file errors in build_utils.sh if no in-tree modules exist
    touch "$MODULES_STAGING_DIR/lib/modules/$KVER/modules.order"
    touch "$MODULES_STAGING_DIR/lib/modules/$KVER/modules.builtin"
    touch "$MODULES_STAGING_DIR/lib/modules/$KVER/modules.builtin.modinfo"

    # OOT Module Collection into unified staging
    echo "  [+] Collecting OOT modules from output tree..."
    for oot_dir in "${OOT_MODULE_DIRS[@]}"; do
        if [ -d "$OUT_DIR/$oot_dir" ]; then
            find "$OUT_DIR/$oot_dir" -name "*.ko" -exec cp {} "$MODULES_STAGING_DIR/lib/modules/$KVER/extra/" \;
        fi
    done

    # Remove symlinks from module staging tree.
    find "$MODULES_STAGING_DIR" -type l -delete
    
    # We do NOT run depmod here. build_utils.sh will do it in create_modules_staging.
    # However, if DLKM images are completely disabled, we need depmod for the unified tree.
    if [ "$BUILD_VENDOR_DLKM" -eq 0 ] && [ "$BUILD_SYSTEM_DLKM" -eq 0 ]; then
        echo "  [+] DLKM images disabled. Running depmod on unified staging directory..."
        depmod -b "$MODULES_STAGING_DIR" "$KVER"
    fi
}

# Staging for vendor_boot ramdisk
build_vendor_boot_modules() {
    echo "  [+] Staging modules for vendor_boot ramdisk..."
    local VENDOR_BOOT_STAGING_DIR="$STAGING_DIR/vendor_boot"
    rm -rf "$VENDOR_BOOT_STAGING_DIR"

    # Stage vendor_boot modules. 
    # $VENDOR_BOOT_MODULES_LIST limits what goes in the ramdisk.
    # $MODULES_RECOVERY_LIST specifies what loads in recovery.
    create_modules_staging "${VENDOR_BOOT_MODULES_LIST}" "$MODULES_STAGING_DIR" \
        "$VENDOR_BOOT_STAGING_DIR" "${VENDOR_BOOT_MODULES_BLOCKLIST}" "${MODULES_RECOVERY_LIST}" "" "" ""
}

# --- Phase 4: Image Assembly ---
sign_image() {
    local image_path="$1"
    local partition_name="$2"
    if [ "$AVB_SIGN_BOOT_IMG" -eq 1 ]; then
        echo "  [+] Signing $partition_name..."
        avbtool add_hash_footer \
            --partition_name "$partition_name" \
            --partition_size "$AVB_BOOT_PARTITION_SIZE" \
            --image "$image_path" \
            --algorithm "$AVB_BOOT_ALGORITHM" \
            --key "$AVB_BOOT_KEY"
    fi
}

stage_anykernel() {
    echo "[*] Phase 4 (AK3): Packaging AnyKernel3 Zip..."
    local AK3_STAGING_DIR="$OUT_DIR/ak3_staging"
    rm -rf "$AK3_STAGING_DIR"
    mkdir -p "$AK3_STAGING_DIR"

    if [ ! -d "$AK3_DIR" ]; then
        echo "  [!] Error: AnyKernel3 directory ($AK3_DIR) not found."
        exit 1
    fi

    # Copy AK3 template
    cp -r "$AK3_DIR"/* "$AK3_STAGING_DIR/"

    # Copy Kernel & DTB/DTBO
    local KERNEL_IMAGE
    if [ -n "$KERNEL_BINARY_PATH" ] && [ -f "$KERNEL_BINARY_PATH" ]; then
        KERNEL_IMAGE="$KERNEL_BINARY_PATH"
    else
        KERNEL_IMAGE="$OUT_DIR/arch/$ARCH/boot/${KERNEL_IMAGE_NAME:-Image}"
    fi
    cp "$KERNEL_IMAGE" "$AK3_STAGING_DIR/"
    
    # We already have dtb.img from assemble_images concatenation
    [ -f "$OUT_DIR/dtb.img" ] && cp "$OUT_DIR/dtb.img" "$AK3_STAGING_DIR/dtb"
    [ -f "$DIST_DIR/dtbo.img" ] && cp "$DIST_DIR/dtbo.img" "$AK3_STAGING_DIR/"

    # Inline DLKMs
    [ -f "$DIST_DIR/vendor_dlkm.img" ] && cp "$DIST_DIR/vendor_dlkm.img" "$AK3_STAGING_DIR/"
    [ -f "$DIST_DIR/system_dlkm.img" ] && cp "$DIST_DIR/system_dlkm.img" "$AK3_STAGING_DIR/"

    # Create Zip
    (cd "$AK3_STAGING_DIR" && zip -r9 "$DIST_DIR/$AK3_ZIP_NAME" * -x .git README.md)
    echo "  [+] AnyKernel3 zip created: $DIST_DIR/$AK3_ZIP_NAME"
}

assemble_images() {
    echo "[*] Phase 4: Packaging Images..."

    if [ ! -d "$MODULES_STAGING_DIR/lib/modules" ] || [ -z "$(ls -A "$MODULES_STAGING_DIR/lib/modules" 2>/dev/null)" ]; then
        echo "  [!] Modules staging directory not found or empty. Running stage_modules..."
        stage_modules
    fi

    mkdir -p "$DIST_DIR"
    if [ -f "$OUT_DIR/System.map" ]; then
        cp "$OUT_DIR/System.map" "$DIST_DIR/"
    fi

    # 1. dtbo.img (Built first as it may be needed by both methods)
    if [ "${#DTBO_LIST[@]}" -gt 0 ]; then
        echo "  [+] Building dtbo.img..."
        local dtbo_paths=()
        for dtbo in "${DTBO_LIST[@]}"; do
            local path="$OUT_DIR/$DTS_OUT_DIR/$dtbo"
            if [ -f "$path" ]; then
                dtbo_paths+=("$path")
            else
                echo "  [!] Warning: DTBO $dtbo not found at $path"
            fi
        done

        if [ "${#dtbo_paths[@]}" -gt 0 ]; then
            mkdtboimg create "$DIST_DIR/dtbo.img" $MKDTBOIMG_OPTIONS "${dtbo_paths[@]}"
        fi
    fi

    # 2. vendor_dlkm.img & system_dlkm.img (Built first for inlining)
    if [ "$BUILD_VENDOR_DLKM" -eq 1 ]; then
        echo "  [+] Building vendor_dlkm.img..."
        export VENDOR_DLKM_FS_TYPE="${VENDOR_DLKM_FS_TYPE:-ext4}"
        build_vendor_dlkm
    fi
    if [ "$BUILD_SYSTEM_DLKM" -eq 1 ]; then
        echo "  [+] Building system_dlkm.img..."
        export SYSTEM_DLKM_FS_TYPE="${SYSTEM_DLKM_FS_TYPE:-ext4}"
        build_system_dlkm
    fi

    # Concatenate DTB (Used by both methods)
    local dtb_img="$OUT_DIR/dtb.img"
    rm -f "$dtb_img"
    local found_dtbs=0
    if [ "${#DTB_LIST[@]}" -gt 0 ]; then
        for dtb in "${DTB_LIST[@]}"; do
            local path="$OUT_DIR/$DTS_OUT_DIR/$dtb"
            if [ -f "$path" ]; then
                cat "$path" >> "$dtb_img"
                found_dtbs=$((found_dtbs + 1))
            else
                echo "  [!] Warning: DTB $dtb not found at $path"
            fi
        done
    fi

    if [ "$FLASH_METHOD" == "anykernel3" ]; then
        stage_anykernel
        return 0
    fi

    # --- Traditional boot image assembly ---
    local KERNEL_IMAGE
    if [ -n "$KERNEL_BINARY_PATH" ] && [ -f "$KERNEL_BINARY_PATH" ]; then
        KERNEL_IMAGE="$KERNEL_BINARY_PATH"
    else
        KERNEL_IMAGE="$OUT_DIR/arch/$ARCH/boot/${KERNEL_IMAGE_NAME:-Image}"
    fi

    # 1. boot.img
    if [ -f "$KERNEL_IMAGE" ]; then
        echo "  [+] Packaging boot.img..."
        local BOOT_ARGS=()
        BOOT_ARGS+=("--kernel" "$KERNEL_IMAGE")
        BOOT_ARGS+=("--header_version" "$BOOT_HEADER_VERSION")
        BOOT_ARGS+=("--cmdline" "${KERNEL_CMDLINE}")
        BOOT_ARGS+=("--output" "$DIST_DIR/boot.img")

        # Offsets
        [ -n "$BASE_ADDRESS" ] && BOOT_ARGS+=("--base" "$BASE_ADDRESS")
        [ -n "$PAGE_SIZE" ]    && BOOT_ARGS+=("--pagesize" "$PAGE_SIZE")
        [ -n "$KERNEL_OFFSET" ] && BOOT_ARGS+=("--kernel_offset" "$KERNEL_OFFSET")
        [ -n "$RAMDISK_OFFSET" ] && BOOT_ARGS+=("--ramdisk_offset" "$RAMDISK_OFFSET")
        [ -n "$TAGS_OFFSET" ] && BOOT_ARGS+=("--tags_offset" "$TAGS_OFFSET")
        [ -n "$DTB_OFFSET" ] && BOOT_ARGS+=("--dtb_offset" "$DTB_OFFSET")

        # GKI Ramdisk
        if [ -n "$GKI_RAMDISK_PREBUILT_BINARY" ] && [ -f "$GKI_RAMDISK_PREBUILT_BINARY" ]; then
            echo "  [+] Using GKI prebuilt ramdisk..."
            BOOT_ARGS+=("--ramdisk" "$GKI_RAMDISK_PREBUILT_BINARY")
        fi

        # Extra Args
        [ -n "$MKBOOTIMG_EXTRA_ARGS" ] && BOOT_ARGS+=($MKBOOTIMG_EXTRA_ARGS)

        mkbootimg "${BOOT_ARGS[@]}"
        sign_image "$DIST_DIR/boot.img" "boot"
    fi

    # 3. vendor_boot.img
    if [ "$found_dtbs" -gt 0 ]; then
        echo "  [+] Building vendor_boot.img..."
        
        local V_BOOT_ARGS=()
        V_BOOT_ARGS+=("--header_version" "$BOOT_HEADER_VERSION")
        V_BOOT_ARGS+=("--vendor_boot" "$DIST_DIR/vendor_boot.img")
        V_BOOT_ARGS+=("--vendor_cmdline" "${KERNEL_VENDOR_CMDLINE}")

        # Offsets
        [ -n "$BASE_ADDRESS" ] && V_BOOT_ARGS+=("--base" "$BASE_ADDRESS")
        [ -n "$PAGE_SIZE" ]    && V_BOOT_ARGS+=("--pagesize" "$PAGE_SIZE")
        [ -n "$KERNEL_OFFSET" ] && V_BOOT_ARGS+=("--kernel_offset" "$KERNEL_OFFSET")
        [ -n "$RAMDISK_OFFSET" ] && V_BOOT_ARGS+=("--ramdisk_offset" "$RAMDISK_OFFSET")
        [ -n "$TAGS_OFFSET" ] && V_BOOT_ARGS+=("--tags_offset" "$TAGS_OFFSET")
        [ -n "$DTB_OFFSET" ] && V_BOOT_ARGS+=("--dtb_offset" "$DTB_OFFSET")

        # Extra Args
        [ -n "$MKBOOTIMG_EXTRA_ARGS" ] && V_BOOT_ARGS+=($MKBOOTIMG_EXTRA_ARGS)

        # Stage ramdisk modules if list is provided
        if [ -n "$VENDOR_BOOT_MODULES_LIST" ]; then
            build_vendor_boot_modules
            local V_RAMDISK="$OUT_DIR/vendor_ramdisk.cpio.gz"
            echo "  [+] Creating vendor_ramdisk.cpio.gz..."
            mkbootfs "$STAGING_DIR/vendor_boot" | gzip > "$V_RAMDISK"
            V_BOOT_ARGS+=("--vendor_ramdisk" "$V_RAMDISK")
        fi

        # Handle Bootconfig
        if [ "${#BOARD_BOOTCONFIG[@]}" -gt 0 ]; then
            local BC_IMG="$OUT_DIR/vendor-bootconfig.img"
            echo "  [+] Creating vendor-bootconfig.img..."
            rm -f "$BC_IMG"
            for param in "${BOARD_BOOTCONFIG[@]}"; do
                echo "$param" >> "$BC_IMG"
            done
            
            # Ensure "bootconfig" is in the vendor_cmdline
            if [[ ! "${KERNEL_VENDOR_CMDLINE}" == *"bootconfig"* ]]; then
                for i in "${!V_BOOT_ARGS[@]}"; do
                    if [[ "${V_BOOT_ARGS[i]}" == "--vendor_cmdline" ]]; then
                        V_BOOT_ARGS[i+1]="${V_BOOT_ARGS[i+1]} bootconfig"
                    fi
                done
            fi
            V_BOOT_ARGS+=("--vendor_bootconfig" "$BC_IMG")
        fi

        V_BOOT_ARGS+=("--dtb" "$dtb_img")
        mkbootimg "${V_BOOT_ARGS[@]}"
        sign_image "$DIST_DIR/vendor_boot.img" "vendor_boot"
    fi
}

# --- Execution ---
case "$1" in
    "defconfig") build_defconfig ;;
    "savedefconfig") save_defconfig ;;
    "kernel")   build_kernel ;;
    "image")    build_kernel_image ;;
    "dtbs")     build_dtbs ;;
    "modules")  build_modules ;;
    "oot")      build_oot_modules ;;
    "stage")    stage_modules ;;
    "assemble") assemble_images ;;
    "all"|*)
        build_kernel
        stage_modules
        assemble_images
        ;;
esac

echo "=================================================="
echo "  Build & Assembly Pipeline Complete."
echo "  Artifacts located in: $DIST_DIR"
echo "=================================================="
