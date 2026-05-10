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

# Priority: 1. Flag (-c/--config), 2. $BUILD_CONFIG env, 3. build.env in CWD
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            CLI_CONFIG="$2"
            shift 2
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

# Set defaults for common variables if not in build.env
OUT_DIR="${OUT_DIR:-$CWD/out}"
DIST_DIR="${DIST_DIR:-$CWD/dist}"
STAGING_DIR="$OUT_DIR/staging"
VENDOR_STAGING="$STAGING_DIR/vendor_dlkm"
SYSTEM_STAGING="$STAGING_DIR/system_dlkm"
TOOLS_DIR="${AOSP_TOOLS_DIR:-$CWD/build-tools/linux_musl-x86/bin}"
JOBS=${JOBS:-$(nproc)}
ARCH="${ARCH:-arm64}"

export PATH="$TOOLS_DIR:$PATH"

echo "=================================================="
echo "  Kernel Unified Build System"
echo "  Device: ${DEVICE_NAME:-Unknown}"
echo "=================================================="

# --- Phase 1: Kernel Compilation ---
build_kernel() {
    echo "[*] Phase 1: Compiling Kernel, DTBs, and In-Tree Modules..."
    make ARCH="$ARCH" O="$OUT_DIR" LLVM=1 LLVM_IAS=1 \
         KCFLAGS="$KCFLAGS" \
         HOSTCFLAGS="$HOSTCFLAGS" \
         $EXTRA_KBUILD_FLAGS \
         -j"$JOBS" Image dtbs modules
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
        IFS=':' read -r rel_src_path partition root_var <<< "$entry"
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
                # Create a wrapper to include the techpack Makefile and print KBUILD_OPTIONS and KBUILD_EXTRA_SYMBOLS
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
                
                echo "  [DEBUG] Extracted opts: $makefile_opts"
                echo "  [DEBUG] Extracted syms: $mk_extra_syms"
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
                 ARCH="$ARCH" LLVM=1 LLVM_IAS=1 \
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

# --- Phase 3: Module Splitting & Staging ---
stage_modules() {
    echo "[*] Phase 3: Staging and Splitting Modules..."
    rm -rf "$STAGING_DIR"
    mkdir -p "$VENDOR_STAGING/lib/modules"
    mkdir -p "$SYSTEM_STAGING/lib/modules"

    TEMP_STAGING="$STAGING_DIR/temp"
    mkdir -p "$TEMP_STAGING"
    make ARCH="$ARCH" O="$OUT_DIR" LLVM=1 LLVM_IAS=1 \
         INSTALL_MOD_PATH="$TEMP_STAGING" modules_install
    
    KVER=$(ls "$TEMP_STAGING/lib/modules")
    
    echo "  [+] Sorting in-tree modules based on $VENDOR_DLKM_MODULES_LIST"
    mkdir -p "$VENDOR_STAGING/lib/modules/$KVER"
    mkdir -p "$SYSTEM_STAGING/lib/modules/$KVER"
    
    for file in modules.order modules.builtin modules.builtin.modinfo; do
        if [ -f "$TEMP_STAGING/lib/modules/$KVER/$file" ]; then
            cp "$TEMP_STAGING/lib/modules/$KVER/$file" "$VENDOR_STAGING/lib/modules/$KVER/"
            cp "$TEMP_STAGING/lib/modules/$KVER/$file" "$SYSTEM_STAGING/lib/modules/$KVER/"
        fi
    done
    
    if [ -f "$VENDOR_DLKM_MODULES_LIST" ]; then
        while read -r mod_path; do
            mod_name=$(basename "$mod_path")
            find "$TEMP_STAGING/lib/modules/$KVER" -name "$mod_name" -exec mv {} "$VENDOR_STAGING/lib/modules/$KVER/" \;
        done < "$VENDOR_DLKM_MODULES_LIST"
    fi

    find "$TEMP_STAGING/lib/modules/$KVER" -name "*.ko" -exec mv {} "$SYSTEM_STAGING/lib/modules/$KVER/" \;

    # OOT Module Collection
    echo "  [+] Collecting OOT modules from output tree..."
    for oot_dir in "${OOT_MODULE_DIRS[@]}"; do
        if [ -d "$OUT_DIR/$oot_dir" ]; then
            find "$OUT_DIR/$oot_dir" -name "*.ko" -exec cp {} "$VENDOR_STAGING/lib/modules/$KVER/" \;
        fi
    done

    find "$STAGING_DIR" -type l -delete

    echo "  [+] Running depmod..."
    depmod -b "$VENDOR_STAGING" "$KVER"
    depmod -b "$SYSTEM_STAGING" "$KVER"
}

# --- Phase 4: Image Assembly ---
assemble_images() {
    echo "[*] Phase 4: Packaging Images..."
    mkdir -p "$DIST_DIR"
    local KERNEL_IMAGE="$OUT_DIR/arch/$ARCH/boot/${KERNEL_IMAGE_NAME:-Image}"

    # 1. boot.img
    if [ -f "$KERNEL_IMAGE" ]; then
        echo "  [+] Packaging boot.img..."
        mkbootimg \
            --kernel "$KERNEL_IMAGE" \
            --header_version "$BOOT_HEADER_VERSION" \
            --output "$DIST_DIR/boot.img"
    fi

    # 2. dtbo.img
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
            mkdtboimg create "$DIST_DIR/dtbo.img" --page_size "${PAGE_SIZE:-4096}" "${dtbo_paths[@]}"
        fi
    fi

    # 3. vendor_boot.img (with concatenated DTB)
    if [ "${#DTB_LIST[@]}" -gt 0 ]; then
        echo "  [+] Building vendor_boot.img..."
        local dtb_img="$OUT_DIR/dtb.img"
        rm -f "$dtb_img"
        
        local found_dtbs=0
        for dtb in "${DTB_LIST[@]}"; do
            local path="$OUT_DIR/$DTS_OUT_DIR/$dtb"
            if [ -f "$path" ]; then
                cat "$path" >> "$dtb_img"
                found_dtbs=$((found_dtbs + 1))
            else
                echo "  [!] Warning: DTB $dtb not found at $path"
            fi
        done

        if [ "$found_dtbs" -gt 0 ]; then
            mkbootimg \
                --header_version "$BOOT_HEADER_VERSION" \
                --vendor_boot "$DIST_DIR/vendor_boot.img" \
                --dtb "$dtb_img"
        fi
    fi

    # 4. vendor_dlkm.img & system_dlkm.img
    local img_size="${PARTITION_SIZE:-536870912}"
    for part in "vendor_dlkm" "system_dlkm"; do
        echo "  [+] Building ${part}.img..."
        PROP_FILE="$OUT_DIR/${part}.prop"
        cat <<EOF > "$PROP_FILE"
fs_type=ext4
mount_point=${part}
partition_size=$img_size
extfs_sparse_flag=-s
ext_mkuserimg=mkuserimg_mke2fs
mke2fs=mke2fs
e2fsdroid=e2fsdroid
EOF
        build_image "$STAGING_DIR/$part" "$PROP_FILE" "$DIST_DIR/${part}.img" "/${part}"
    done
}

# --- Execution ---
case "$1" in
    "kernel")   build_kernel ;;
    "oot")      build_oot_modules ;;
    "stage")    stage_modules ;;
    "assemble") assemble_images ;;
    "all"|*)
        build_kernel
        build_oot_modules
        stage_modules
        assemble_images
        ;;
esac

echo "=================================================="
echo "  Build & Assembly Pipeline Complete."
echo "  Artifacts located in: $DIST_DIR"
echo "=================================================="
