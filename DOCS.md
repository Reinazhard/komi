# Technical Documentation: Kernel Out-of-tree Module Integration (KOMI)

This document provides a detailed reference for the variables and functions used in KOMI.

## `build.env` Configuration Reference

`build.env` is the central source of truth for device-specific configuration.

### Identity & Architecture
- `DEVICE_NAME`: The name of the target device (used for logging/display).
- `ARCH`: Target architecture (default: `arm64`).

### Compiler & Kbuild Configuration
- `KCFLAGS`: Kernel C flags passed to all `make` calls.
- `HOSTCFLAGS`: Host C flags used for compiled host tools.
- `LLVM`: Set to `1` to use LLVM/Clang toolchain. Set to `0` for GCC.
- `LLVM_IAS`: Set to `1` to use the Integrated Assembler.
- `CROSS_COMPILE`: GCC prefix for the main kernel architecture (e.g., `aarch64-linux-android-`).
- `CROSS_COMPILE_COMPAT`: GCC prefix for 32-bit compatibility mode.
- `EXTRA_KBUILD_FLAGS`: Additional Kbuild flags (e.g., `CONFIG_ARCH_SUN=y`).

### Paths
- `OUT_DIR`: Directory for build artifacts and intermediate objects.
- `DIST_DIR`: Final directory where packaged images (`.img`) are moved.
- `AOSP_TOOLS_DIR`: Path to the folder containing AOSP binaries (`mkbootimg`, etc.).

### Image & Partition Parameters
- `BOOT_HEADER_VERSION`: Android boot image header version (e.g., `4`).
- `KERNEL_IMAGE_NAME`: The name of the kernel binary to package (default: `Image`).
- `PARTITION_SIZE`: Default size (in bytes) for generated partition images.

### DTB & DTBO Configuration
- `DTS_OUT_DIR`: Relative path under `$OUT_DIR` where compiled DTBs are located.
- `MKDTBOIMG_OPTIONS`: Arguments passed to the `mkdtboimg` tool.
- `DTBO_LIST`: Bash array of DTBO overlay filenames to include in `dtbo.img`.
- `DTB_LIST`: Bash array of DTB filenames to be concatenated into `vendor_boot.img`.

### Module Staging & DLKM
- `SYSTEM_DLKM_FS_TYPE`: Filesystem for `system_dlkm` image (`ext4` or `erofs`).
- `VENDOR_DLKM_FS_TYPE`: Filesystem for `vendor_dlkm` image (`ext4` or `erofs`).
- `SYSTEM_DLKM_GEN_FLATTEN_IMAGE`: Set to `1` for a flat module directory structure.
- `SYSTEM_DLKM_MODULES_LIST`: Path to the load list for the system partition.
- `VENDOR_DLKM_MODULES_LIST`: Path to the load list for the vendor partition.
- `VENDOR_BOOT_MODULES_LIST`: Path to modules included in the ramdisk.

### Out-of-Tree (OOT) Modules
- `OOT_MODULE_DIRS`: Directories to search for compiled `.ko` files after OOT building.
- `DLKM_SOURCES`: Structured list of OOT modules.
  - Format: `"source_path:target_partition:ROOT_VARIABLE"`
  - `source_path`: Relative path to module source.
  - `target_partition`: Partition to install into.
  - `ROOT_VARIABLE`: The variable name the module's Makefile expects for its root path.

---

## `build.sh` Function Reference

`build.sh` implements the build logic and phases.

### Toolchain Logic
The script enforces mutual exclusivity between LLVM and GCC. If `LLVM=1` is detected, it clears `CROSS_COMPILE` to ensure the kernel's top-level Makefile correctly triggers Clang mode.

### Compilation Functions
- `build_kernel_image()`: Compiles the main kernel binary (`Image`).
- `build_dtbs()`: Compiles device tree blobs.
- `build_modules()`: Compiles in-tree kernel modules.
- `build_oot_modules()`: Iterates through `DLKM_SOURCES`. It automatically extracts `KBUILD_OPTIONS` from local Makefiles and handles symbol propagation via `Module.symvers`.

### Staging & Assembly
- `stage_modules()`: Installs all compiled modules (in-tree and OOT) into a unified staging directory. Handles symbol stripping and `depmod`.
- `assemble_images()`: The final packaging phase.
  1. Concatenates DTBs.
  2. Generates `boot.img`.
  3. Generates `dtbo.img`.
  4. Generates `vendor_boot.img` with ramdisk and DTBs.
  5. Calls `build_utils.sh` to generate `vendor_dlkm` and `system_dlkm` images.

---

## `envsetup.sh` Workflow

This script is the entry point for new environments:
1. **Cloning**: Clones the build repository to `./build-kernel`.
2. **Symlinking**: Maps the core scripts to the project root for easy access.
3. **Pre-flight Validation**: Checks that the local system has the necessary binaries in `./build-kernel/tools` to successfully package Android images.
