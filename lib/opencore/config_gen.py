#!/usr/bin/env python3
import plistlib, sys, os, uuid

model     = sys.argv[1]
kexts_dir = sys.argv[2]
out_file  = sys.argv[3]

kext_order = [
    "Lilu", "WhateverGreen", "VirtualSMC",
    "SMCBatteryManager", "SMCLightSensor", "SMCProcessor", "SMCSuperIO",
    "AirportBrcmFixup",
    "BlueToolFixup", "BrcmFirmwareData", "BrcmPatchRAM3", "BrcmBluetoothInjector",
    "RestrictEvents", "CryptexFixup",
]

min_max = {
    "BlueToolFixup":         ("21.0.0", ""),
    "BrcmBluetoothInjector": ("", "20.99.99"),
    "CryptexFixup":          ("23.0.0", ""),
}

def has_kext(name):
    return os.path.isdir(os.path.join(kexts_dir, name + ".kext"))

def exec_path(name):
    p = os.path.join(kexts_dir, name + ".kext", "Contents", "MacOS", name)
    return f"Contents/MacOS/{name}" if os.path.isfile(p) else ""

kext_entries = []
for name in kext_order:
    if not has_kext(name):
        continue
    mn, mx = min_max.get(name, ("", ""))
    kext_entries.append({
        "Arch": "x86_64", "BundlePath": f"{name}.kext", "Comment": "",
        "Enabled": True, "ExecutablePath": exec_path(name),
        "MaxKernel": mx, "MinKernel": mn, "PlistPath": "Contents/Info.plist",
    })

drivers = ["HfsPlus.efi", "OpenRuntime.efi", "ResetNvramEntry.efi"]
driver_entries = [{"Arguments": "", "Comment": "", "Enabled": True, "Path": d} for d in drivers]

config = {
    "ACPI": {"Add": [], "Delete": [], "Patch": [], "Quirks": {
        "FadtEnableReset": False, "NormalizeHeaders": False,
        "RebaseRegions": False, "ResetHwSig": False,
        "ResetLogoStatus": True, "SyncTableIds": False,
    }},
    "Booter": {"MmioWhitelist": [], "Patch": [], "Quirks": {
        "AllowRelocationBlock": True, "AvoidRuntimeDefrag": True,
        "DevirtualiseMmio": False, "DisableSingleUser": False,
        "DisableVariableWrite": False, "DiscardHibernateMap": False,
        "EnableSafeModeSlide": True, "EnableWriteUnprotector": False,
        "ForceBooterSignature": False, "ForceExitBootServices": False,
        "ProtectMemoryRegions": False, "ProtectSecureBoot": False,
        "ProtectUefiServices": False, "ProvideCustomSlide": True,
        "ProvideMaxSlide": 0, "RebuildAppleMemoryMap": True,
        "ResizeAppleGpuBars": -1, "SetupVirtualMap": True,
        "SignalAppleOS": False, "SyncRuntimePermissions": True,
    }},
    "DeviceProperties": {"Add": {}, "Delete": {}},
    "Kernel": {
        "Add": kext_entries, "Block": [], "Force": [], "Patch": [],
        "Emulate": {"Cpuid1Data": bytes(16), "Cpuid1Mask": bytes(16),
                    "DummyPowerManagement": False, "MaxKernel": "", "MinKernel": ""},
        "Quirks": {
            "AppleCpuPmCfgLock": False, "AppleXcpmCfgLock": True,
            "AppleXcpmExtraMsrs": False, "AppleXcpmForceBoost": False,
            "CustomPciSerialDevice": False, "CustomSMBIOSGuid": False,
            "DisableIoMapper": True, "DisableIoMapperMapping": False,
            "DisableLinkeditJettison": True, "DisableRtcChecksum": False,
            "ExtendBTFeatureFlags": False, "ExternalDiskIcons": False,
            "ForceAquantiaEthernet": False, "ForceSecureBootScheme": False,
            "IncreasePciBarSize": False, "LapicKernelPanic": False,
            "LegacyCommpage": False, "PanicNoKextDump": True,
            "PowerTimeoutKernelPanic": True, "ProvideCurrentCpuInfo": False,
            "SetApfsTrimTimeout": -1, "ThirdPartyDrives": False,
            "XhciPortLimit": True,
        },
        "Scheme": {"CustomKernel": False, "FuzzyMatch": True,
                   "KernelArch": "x86_64", "KernelCache": "Auto"},
    },
    "Misc": {
        "BlessOverride": [], "Entries": [], "Tools": [],
        "Boot": {
            "ConsoleAttributes": 0, "HibernateMode": "None",
            "HideAuxiliary": False, "LauncherOption": "Disabled",
            "LauncherPath": "Default", "PickerAttributes": 17,
            "PickerAudioAssist": False, "PickerMode": "Builtin",
            "PickerVariant": "Auto", "PollAppleHotKeys": True,
            "ShowPicker": True, "TakeoffDelay": 0, "Timeout": 5,
        },
        "Debug": {
            "AppleDebug": False, "ApplePanic": False,
            "DisableWatchDog": True, "DisplayDelay": 0,
            "DisplayLevel": 2147483650, "LogModules": "*",
            "SerialInit": False, "SysReport": False, "Target": 3,
        },
        "Security": {
            "AllowSetDefault": True, "ApECID": 0, "AuthRestart": False,
            "BlacklistAppleUpdate": True, "DmgLoading": "Any",
            "EnablePassword": False, "ExposeSensitiveData": 6,
            "HaltLevel": 2147483648, "Hibernate": 0,
            "PasswordHash": bytes(0), "PasswordSalt": bytes(0),
            "ScanPolicy": 0, "SecureBootModel": "Disabled", "Vault": "Optional",
        },
        "Serial": {"Init": False, "Override": False},
    },
    "NVRAM": {
        "Add": {
            "4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14": {
                "DefaultBackgroundColor": bytes.fromhex("00000000"),
                "UIScale": bytes([2]),
            },
            "7C436110-AB2A-4BBB-A880-FE41995C9F82": {
                "boot-args": "-v keepsyms=1 amfi_get_out_of_my_way=0x01 brcmfx-driver=2 revpatch=sbvmm,asset -wegnoegpu",
                "csr-active-config": bytes.fromhex("03080000"),
                "prev-lang:kbd": "en-US:0",
                "run-efi-updater": "No",
                "SystemAudioVolume": bytes([0x46]),
            },
        },
        "Delete": {
            "4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14": [],
            "7C436110-AB2A-4BBB-A880-FE41995C9F82": ["csr-active-config", "boot-args", "prev-lang:kbd"],
        },
        "LegacyOverwrite": False, "LegacySchema": {}, "WriteFlash": True,
    },
    "PlatformInfo": {
        "Automatic": True, "CustomMemory": False,
        "Generic": {
            "AdviseFeatures": False, "MaxBIOSVersion": False,
            "MLB": "C02634902GPHYAQ1H", "ProcessorType": 0,
            "ROM": bytes.fromhex("112233445566"), "SpoofVendor": True,
            "SystemMemoryStatus": "Auto", "SystemProductName": model,
            "SystemSerialNumber": "C02TQ0KSFVH3",
            "SystemUUID": str(uuid.uuid4()).upper(),
            "UpdateSMBIOSMode": "Create",
        },
        "UpdateDataHub": True, "UpdateNVRAM": True, "UpdateSMBIOS": True,
    },
    "UEFI": {
        "APFS": {
            "EnableJumpstart": True, "GlobalConnect": False, "HideVerbose": True,
            "JumpstartHotPlug": False, "MinDate": -1, "MinVersion": -1,
        },
        "Audio": {
            "AudioCodec": 0, "AudioDevice": "", "AudioOutMask": -1,
            "AudioSupport": False, "DisconnectHda": False, "MaximumGainDBm": 0,
            "MinimumAssistGainDBm": -128, "MinimumAudibleGainDBm": -55,
            "PlayChime": "Disabled", "ResetTrafficClass": False, "SetupDelay": 0,
        },
        "ConnectDrivers": True,
        "Drivers": driver_entries,
        "Input": {
            "KeyFiltering": False, "KeyForgetThreshold": 5, "KeyMergeThreshold": 2,
            "KeySupport": True, "KeySupportMode": "Auto", "KeySwap": False,
            "PointerSupport": False, "PointerSupportMode": "ASUS", "TimerResolution": 50000,
        },
        "Output": {
            "ClearScreenOnModeSwitch": False, "ConsoleMode": "",
            "DirectGopRendering": False, "ForceResolution": False,
            "GopBurstMode": False, "GopPassThrough": "Apple",
            "IgnoreTextInGraphics": False, "InitialMode": "Auto",
            "ProvideConsoleGop": True, "ReconnectGraphicsOnConnect": False,
            "ReconnectOnResChange": False, "ReplaceTabWithSpace": False,
            "Resolution": "Max", "SanitiseClearScreen": False,
            "TextRenderer": "BuiltinGraphics", "UIScale": 2, "UgaPassThrough": False,
        },
        "ProtocolOverrides": {
            "AppleAudio": False, "AppleBootBeep": False, "AppleDebugLog": False,
            "AppleEg2Info": False, "AppleFramebufferInfo": False,
            "AppleImageConversion": False, "AppleImg4Verification": False,
            "AppleKeyMap": False, "AppleRtcRam": False, "AppleSecureBoot": False,
            "AppleSmcIo": False, "AppleUserInterfaceTheme": False,
            "DataHub": False, "DeviceProperties": False, "FirmwareVolume": False,
            "HashServices": False, "OSInfo": False, "PciIo": False,
            "UnicodeCollation": False,
        },
        "Quirks": {
            "ActivateHpetSupport": False, "DisableSecurityPolicy": False,
            "EnableVectorAcceleration": True, "EnableVmx": False,
            "ExitBootServicesDelay": 0, "ForceOcWriteFlash": False,
            "ForgeUefiSupport": False, "IgnoreInvalidFlexRatio": False,
            "ReleaseUsbOwnership": False, "ReloadOptionRoms": False,
            "RequestBootVarRouting": True, "ResizeGpuBars": -1,
            "ResizeUserspaceWCBar": -1, "TscSyncTimeout": 0,
            "UnblockFsConnect": False,
        },
        "ReservedMemory": [],
    },
}

with open(out_file, "wb") as f:
    plistlib.dump(config, f, fmt=plistlib.FMT_XML)
print(f"  ✓ config.plist gerado para {model}")
print(f"    Kexts carregados: {len(kext_entries)}")
for e in kext_entries:
    mn = f" [min:{e['MinKernel']}]" if e['MinKernel'] else ""
    mx = f" [max:{e['MaxKernel']}]" if e['MaxKernel'] else ""
    print(f"    - {e['BundlePath']}{mn}{mx}")
