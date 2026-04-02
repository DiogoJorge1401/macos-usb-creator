# macos-usb-creator

Create bootable macOS USB drives from Linux.

Supports local files (`.pkg`, `.dmg`, `.iso`, `.img`) with an interactive file browser, or downloading recovery images directly from Apple's servers via [macrecovery](https://github.com/acidanthera/OpenCorePkg/tree/master/Utilities/macrecovery) (OpenCore).

## Features

- Interactive file browser filtered by `.pkg` / `.dmg` / `.iso` / `.img`
- Download BaseSystem.dmg from Apple (macOS Sequoia through High Sierra)
- Auto-detect USB drives and list only removable devices
- GPT partitioning with EFI + Recovery layout (OpenCore compatible)
- Safety confirmation before writing
- Auto-install dependencies (Arch/Debian/Fedora)

## Requirements

- Linux (Arch, Debian/Ubuntu, Fedora)
- `dmg2img`, `sgdisk`, `mkfs.vfat`, `python3`, `git`, `bsdtar`
- A USB drive (4GB+ for recovery, 16GB+ for full installer)

## Usage

```bash
# Interactive mode
sudo ./macos-usb-creator.sh

# Or pass a file directly
sudo ./macos-usb-creator.sh /path/to/InstallAssistant.pkg
sudo ./macos-usb-creator.sh /path/to/BaseSystem.dmg
```

## How it works

1. **Download mode**: Uses `macrecovery.py` from OpenCorePkg to fetch BaseSystem.dmg from Apple's servers, then writes it to a properly partitioned USB (GPT: 200MB FAT32 EFI + HFS Recovery).

2. **Local file mode**: Browse and select a `.pkg` / `.dmg` / `.iso` / `.img` file. For `.pkg` files, the script extracts the embedded `.dmg` using `bsdtar`. The image is then converted with `dmg2img` and written to the USB.

## Based on

- [OpenCore Install Guide - Linux](https://dortania.github.io/OpenCore-Install-Guide/installer-guide/linux-install.html)
- [acidanthera/OpenCorePkg](https://github.com/acidanthera/OpenCorePkg)

## License

MIT
