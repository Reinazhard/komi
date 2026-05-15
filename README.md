# Kernel Out-of-tree Module Integration (KOMI)
A modular and extensible build system for modern Android Kernels, designed to separate build mechanism from device-specific configuration. This system handles kernel compilation, Out-of-Tree (OOT) module building, and the assembly of Android partition images (boot, vendor_boot, dtbo, etc.).

## Quick Start

### 1. Setup Environment
Run the following command in your kernel source root to clone the build system and setup symlinks:

```bash
curl -sL https://raw.githubusercontent.com/Reinazhard/komi/main/envsetup.sh | bash
```

This will:
- Clone this repository into `./build-kernel`.
- Create symlinks (`build.sh`, `build.env`, `build_utils.sh`) in your current directory.
- Validate that required AOSP tools are present.

### 2. Configure
Edit `build.env` to match your device requirements, paths, and module lists.

### 3. Build
Use the unified build script to compile and package:

```bash
# Build everything (Kernel, Modules, DTBs, and Images)
./build.sh all

# Build only specific components
./build.sh kernel   # Kernel + DTBs + Modules
./build.sh oot      # Only Out-of-Tree modules
./build.sh assemble # Only package images from existing build artifacts
```

## Repository Structure

- `build.sh`: The main entry point for the build process.
- `build.env`: Central configuration file for device-specific variables.
- `build_utils.sh`: Internal helper functions for image assembly and module handling.
- `envsetup.sh`: Bootstrap script for repository initialization.
- `tools/`: Prebuilt AOSP binaries (mkbootimg, avbtool, etc.).
- `DOCS.md`: Comprehensive technical documentation.

## Key Features

- **Toolchain Flexibility**: Seamlessly switch between LLVM/Clang and GCC.
- **Automated OOT Building**: Handles complex techpack structures and symbol propagation.
- **Partition Image Assembly**: Automatically generates `boot.img`, `vendor_boot.img`, `vendor_dlkm.img`, and `system_dlkm.img`.
- **Modular Design**: Easy to extend for new SoC architectures or partition layouts.

For detailed technical information, refer to [DOCS.md](./DOCS.md).
