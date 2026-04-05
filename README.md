# macos-usb-creator

Create bootable macOS USB drives from Linux — with full offline installer support via OpenCore.

## Modes

### 1. Download recovery from Apple
Downloads `BaseSystem.dmg` directly from Apple's servers via [macrecovery](https://github.com/acidanthera/OpenCorePkg/tree/master/Utilities/macrecovery) and writes it to a GPT-partitioned USB. Requires internet on the Mac during installation.

### 2. Local file
Browse and select a `.pkg` / `.dmg` / `.iso` / `.img` file from your filesystem. Writes the image to the USB using `dmg2img` or `dd`.

### 3. Full offline installer with OpenCore ⭐
**No internet required on the Mac.** Intended for legacy Macs (MacBook Pro 2013–2015) running macOS Sonoma via [OpenCore Legacy Patcher](https://github.com/dortania/OpenCore-Legacy-Patcher).

- Partitions USB as GPT: 300 MB FAT32 EFI + HFS+ installer
- Writes a full macOS installer image (`.hfs` / `SharedSupport.dmg`) to the USB
- Automatically downloads and assembles a complete OpenCore EFI:
  - **OpenCorePkg** (BOOTx64.efi, OpenCore.efi, OpenRuntime.efi, ResetNvramEntry.efi)
  - **HfsPlus.efi** (HFS+ filesystem driver)
  - **Kexts**: Lilu, WhateverGreen, VirtualSMC (+ SMC plugins), AirportBrcmFixup, BrcmPatchRAM3, BrcmFirmwareData, BrcmBluetoothInjector, RestrictEvents, CryptexFixup
- Generates a complete `config.plist` tuned for the selected SMBIOS model and macOS Sonoma

Supported models (selectable in the menu):

| Option | SMBIOS | Mac |
|--------|--------|-----|
| 1 | MacBookPro11,5 | MacBook Pro 15" 2015 (dGPU AMD R9 M370X) |
| 2 | MacBookPro11,4 | MacBook Pro 15" 2015 (iGPU only) |
| 3 | MacBookPro12,1 | MacBook Pro 13" 2015 |
| 4 | Custom | Any model (type manually) |

> **After installing macOS**, run [OpenCore Legacy Patcher](https://github.com/dortania/OpenCore-Legacy-Patcher/releases) to apply root patches (GPU, WiFi, Bluetooth).

## Requirements

- Linux (Arch/CachyOS, Debian/Ubuntu, Fedora)
- `dmg2img`, `sgdisk`, `mkfs.vfat`, `python3`, `git`, `bsdtar`
- USB drive: 4 GB+ for recovery · **32 GB+ for offline installer**
- Internet on the Linux machine (to download OpenCore and kexts)

## Usage

```bash
git clone https://github.com/DiogoJorge1401/macos-usb-creator
cd macos-usb-creator
sudo ./macos-usb-creator.sh

# Or pass a file directly (skips source selection)
sudo ./macos-usb-creator.sh /path/to/InstallAssistant.pkg
sudo ./macos-usb-creator.sh /path/to/BaseSystem.dmg
```

## Offline installer — step by step

1. Obtain a full macOS installer image on Linux (`.hfs` or `InstallAssistant.pkg`)
2. Run the script and choose **option 3**
3. Select your Mac model and the installer image
4. Select the USB drive and confirm
5. The script downloads ~50 MB of OpenCore + kexts and sets everything up
6. Boot the Mac holding **Option/Alt**, select **EFI Boot / OpenCore**
7. In the OpenCore picker, select the macOS installer
8. Install macOS — no internet needed
9. After first boot, run **OCLP** to patch GPU, WiFi, and Bluetooth

## Config highlights (Sonoma on unsupported hardware)

| Setting | Value |
|---------|-------|
| `SecureBootModel` | `Disabled` |
| `ScanPolicy` | `0` (all drives) |
| `csr-active-config` | `03080000` |
| `boot-args` | `-v amfi_get_out_of_my_way=0x01 brcmfx-driver=2 revpatch=sbvmm,asset` |

## References

- [OpenCore Install Guide — Linux](https://dortania.github.io/OpenCore-Install-Guide/installer-guide/linux-install.html)
- [acidanthera/OpenCorePkg](https://github.com/acidanthera/OpenCorePkg)
- [dortania/OpenCore-Legacy-Patcher](https://github.com/dortania/OpenCore-Legacy-Patcher)

## License

MIT
