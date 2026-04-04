#!/bin/bash

oc_get_asset_url() {
    local repo="$1" pattern="$2"
    curl -s "https://api.github.com/repos/$repo/releases/latest" | \
        python3 -c "
import sys,json
r=json.load(sys.stdin)
for a in r.get('assets',[]):
    n=a['name']
    if '$pattern' in n:
        print(a['browser_download_url'])
        break
" 2>/dev/null
}

oc_download_cache() {
    # Usa variavel global _OC_CACHE para evitar poluir stdout com mensagens [INFO]
    local url="$1"
    local fname; fname=$(basename "$url")
    _OC_CACHE="$WORK_DIR/oc_cache/$fname"
    mkdir -p "$WORK_DIR/oc_cache"
    if [ ! -f "$_OC_CACHE" ]; then
        info "Baixando $fname..."
        curl -L --progress-bar -o "$_OC_CACHE" "$url" || error "Falha ao baixar $url"
    else
        info "$fname (cache)"
    fi
}

oc_fetch_kexts() {
    local repo="$1" pattern="$2" dest_kexts="$3"
    local url; url=$(oc_get_asset_url "$repo" "$pattern")
    [ -z "$url" ] && { warn "Nao encontrou '$pattern' em $repo"; return 0; }
    oc_download_cache "$url"
    local cache="$_OC_CACHE"
    local extract_dir="$WORK_DIR/oc_extract/$(echo "$repo" | tr '/' '_')"
    rm -rf "$extract_dir"; mkdir -p "$extract_dir"
    7z x "$cache" -o"$extract_dir" -y > /dev/null 2>&1 || true
    local found=0
    while IFS= read -r -d '' k; do
        cp -r "$k" "$dest_kexts/"
        info "  ✓ $(basename "$k")"
        found=$((found + 1))
    done < <(find "$extract_dir" -name "*.kext" -type d -print0 2>/dev/null)
    [ $found -eq 0 ] && warn "Nenhum .kext encontrado em $repo"
}

build_opencore_efi() {
    local efi_dir="$1"
    step "Baixando OpenCore e kexts"
    mkdir -p "$efi_dir/BOOT" "$efi_dir/OC/Drivers" \
             "$efi_dir/OC/Kexts" "$efi_dir/OC/ACPI" \
             "$efi_dir/OC/Tools" "$efi_dir/OC/Resources"

    # OpenCorePkg
    info "Baixando OpenCorePkg..."
    local oc_url; oc_url=$(oc_get_asset_url "acidanthera/OpenCorePkg" "RELEASE.zip")
    [ -z "$oc_url" ] && error "Nao encontrou OpenCorePkg RELEASE.zip"
    oc_download_cache "$oc_url"
    local oc_cache="$_OC_CACHE"
    local oc_ex="$WORK_DIR/oc_extract/OpenCorePkg"
    rm -rf "$oc_ex"; mkdir -p "$oc_ex"
    7z x "$oc_cache" -o"$oc_ex" -y > /dev/null 2>&1 || true

    local bootx64; bootx64=$(find "$oc_ex" -name "BOOTx64.efi" | head -1)
    [ -f "$bootx64" ] && cp "$bootx64" "$efi_dir/BOOT/" && info "  ✓ BOOTx64.efi"
    local oc_efi; oc_efi=$(find "$oc_ex" -path "*/OC/OpenCore.efi" | head -1)
    [ -f "$oc_efi" ] && cp "$oc_efi" "$efi_dir/OC/" && info "  ✓ OpenCore.efi"
    for drv in OpenRuntime.efi ResetNvramEntry.efi; do
        local f; f=$(find "$oc_ex" -name "$drv" | head -1)
        [ -f "$f" ] && cp "$f" "$efi_dir/OC/Drivers/" && info "  ✓ $drv"
    done

    # HfsPlus.efi (necessario para ler particoes HFS+ do instalador)
    info "Baixando HfsPlus.efi..."
    curl -L --progress-bar -o "$efi_dir/OC/Drivers/HfsPlus.efi" \
        "https://github.com/acidanthera/OcBinaryData/raw/master/Drivers/HfsPlus.efi" \
        && info "  ✓ HfsPlus.efi" || warn "Nao foi possivel baixar HfsPlus.efi"

    # Kexts
    info "Baixando kexts..."
    local kdir="$efi_dir/OC/Kexts"
    oc_fetch_kexts "acidanthera/Lilu"             "RELEASE.zip" "$kdir"
    oc_fetch_kexts "acidanthera/WhateverGreen"    "RELEASE.zip" "$kdir"
    oc_fetch_kexts "acidanthera/VirtualSMC"       "RELEASE.zip" "$kdir"
    oc_fetch_kexts "acidanthera/AppleALC"         "RELEASE.zip" "$kdir"
    oc_fetch_kexts "acidanthera/AirportBrcmFixup" "RELEASE.zip" "$kdir"
    oc_fetch_kexts "acidanthera/BrcmPatchRAM"     "RELEASE.zip" "$kdir"
    oc_fetch_kexts "acidanthera/RestrictEvents"   "RELEASE.zip" "$kdir"
    oc_fetch_kexts "acidanthera/CryptexFixup"     "RELEASE.zip" "$kdir"

    info "Kexts instalados:"
    ls "$kdir/" 2>/dev/null || true
}

oc_download_oclp() {
    local dest="$1"
    info "Baixando OpenCore Legacy Patcher..."
    # OCLP 2.3.0+ so disponibiliza .pkg; versoes anteriores tinham GUI.app.zip
    local url; url=$(oc_get_asset_url "dortania/OpenCore-Legacy-Patcher" "OpenCore-Patcher.pkg")
    if [ -z "$url" ]; then
        url=$(oc_get_asset_url "dortania/OpenCore-Legacy-Patcher" "GUI.app.zip")
    fi
    if [ -z "$url" ]; then
        warn "Nao foi possivel encontrar OCLP para download"
        return 0
    fi
    oc_download_cache "$url"
    local cache="$_OC_CACHE"
    mkdir -p "$dest/OCLP"
    cp "$cache" "$dest/OCLP/"
    info "  ✓ OCLP salvo em OCLP/$(basename "$cache")"
    info "    Apos instalar o macOS, copie e execute o OCLP para ativar WiFi/GPU"
}

oc_copy_skip_setup() {
    local dest="$1"
    local script_src="$SCRIPT_DIR/resources/skip-setup.sh"
    if [ -f "$script_src" ]; then
        cp "$script_src" "$dest/skip-setup.sh"
        chmod +x "$dest/skip-setup.sh"
        info "  ✓ skip-setup.sh copiado para a raiz do EFI"
    else
        warn "skip-setup.sh nao encontrado em resources/"
    fi
}

generate_config_plist() {
    local model="$1" kexts_dir="$2" out_file="$3"
    info "Gerando config.plist para $model..."
    python3 "$SCRIPT_DIR/lib/opencore/config_gen.py" "$model" "$kexts_dir" "$out_file"
}
