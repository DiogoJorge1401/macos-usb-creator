#!/bin/bash
set -e

#====================================================
# macos-usb-creator.sh
#
# Cria USB bootavel do macOS no Linux.
# Suporta arquivo local (.pkg/.dmg/.iso/.img) ou
# download direto da Apple via macrecovery (OpenCore).
#
# Uso: sudo ./macos-usb-creator.sh [arquivo]
#
# Baseado no guia OpenCore:
# https://dortania.github.io/OpenCore-Install-Guide/installer-guide/linux-install.html
#====================================================

VERSION="1.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[AVISO]${NC} $1"; }
error() { echo -e "${RED}[ERRO]${NC} $1"; exit 1; }
step()  { echo -e "\n${CYAN}══════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════════════${NC}\n"; }

WORK_DIR="${MACOS_USB_WORKDIR:-/tmp/macos_usb_creator}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cleanup() {
    [ -n "$LOOP_DEV" ] && sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
    [ -n "$EFI_MOUNT" ] && sudo umount "$EFI_MOUNT" 2>/dev/null || true
    [ -n "$HFS_MOUNT" ] && sudo umount "$HFS_MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

# ══════════════════════════════════════════════
# Utilidades
# ══════════════════════════════════════════════

check_root() {
    [ "$(id -u)" -eq 0 ] || error "Execute com sudo: sudo $0"
}

install_deps() {
    local missing=()

    for cmd in python3 git dmg2img sgdisk mkfs.vfat bsdtar; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    [ ${#missing[@]} -eq 0 ] && { info "Dependencias OK"; return 0; }

    warn "Faltando: ${missing[*]}"

    if command -v pacman &>/dev/null; then
        pacman -S --needed --noconfirm python git gptfdisk dosfstools libarchive 2>/dev/null || true
        if ! command -v dmg2img &>/dev/null; then
            local real_user; real_user=$(logname 2>/dev/null || echo "$SUDO_USER")
            [ -n "$real_user" ] || error "Nao foi possivel detectar usuario. Instale dmg2img manualmente."
            sudo -u "$real_user" yay -S --needed --noconfirm dmg2img 2>/dev/null || \
            sudo -u "$real_user" paru -S --needed --noconfirm dmg2img 2>/dev/null || \
                error "Instale dmg2img manualmente via AUR"
        fi
    elif command -v apt &>/dev/null; then
        apt install -y python3 git dmg2img gdisk dosfstools libarchive-tools
    elif command -v dnf &>/dev/null; then
        dnf install -y python3 git dmg2img gdisk dosfstools bsdtar
    else
        error "Gerenciador de pacotes nao suportado. Instale: ${missing[*]}"
    fi

    for cmd in python3 git dmg2img sgdisk mkfs.vfat; do
        command -v "$cmd" &>/dev/null || error "$cmd nao encontrado apos instalacao"
    done

    info "Dependencias OK"
}

# ══════════════════════════════════════════════
# Navegador de arquivos interativo
# ══════════════════════════════════════════════

browse_files() {
    local dir="${1:-.}"
    local extensions=("pkg" "dmg" "iso" "img")
    local pattern

    # Construir pattern de extensoes
    pattern=$(printf "|%s" "${extensions[@]}")
    pattern="${pattern:1}" # remover primeiro |

    while true; do
        dir="$(realpath "$dir")"

        echo ""
        echo -e "  ${BOLD}Diretorio: ${CYAN}$dir${NC}"
        echo -e "  ${DIM}Filtro: *.{${pattern}}${NC}"
        echo ""

        local items=()
        local index=0

        # Adicionar ".." para voltar
        if [ "$dir" != "/" ]; then
            index=$((index + 1))
            items+=("..")
            echo -e "  ${DIM}[$index]${NC}  ${YELLOW}../${NC}  (voltar)"
        fi

        # Listar subdiretorios
        while IFS= read -r -d '' entry; do
            index=$((index + 1))
            items+=("$entry")
            local name; name=$(basename "$entry")
            echo -e "  ${DIM}[$index]${NC}  ${YELLOW}${name}/${NC}"
        done < <(find "$dir" -maxdepth 1 -mindepth 1 -type d ! -name '.*' -print0 2>/dev/null | sort -z)

        # Listar arquivos filtrados
        while IFS= read -r -d '' entry; do
            index=$((index + 1))
            items+=("$entry")
            local name; name=$(basename "$entry")
            local size; size=$(du -h "$entry" 2>/dev/null | cut -f1)
            echo -e "  ${GREEN}[$index]${NC}  ${BOLD}${name}${NC}  ${DIM}(${size})${NC}"
        done < <(find "$dir" -maxdepth 1 -mindepth 1 -type f \( -iname "*.pkg" -o -iname "*.dmg" -o -iname "*.iso" -o -iname "*.img" \) -print0 2>/dev/null | sort -z)

        if [ $index -eq 0 ] || { [ $index -eq 1 ] && [ "${items[0]}" = ".." ]; }; then
            warn "Nenhum arquivo .pkg/.dmg/.iso/.img encontrado aqui."
        fi

        echo ""
        echo -e "  Digite o numero, ou ${RED}0${NC} para cancelar:"
        read -r nav_choice

        [ "$nav_choice" = "0" ] && return 1

        if ! [[ "$nav_choice" =~ ^[0-9]+$ ]] || [ "$nav_choice" -gt ${#items[@]} ] || [ "$nav_choice" -lt 1 ]; then
            warn "Opcao invalida"
            continue
        fi

        local selected="${items[$((nav_choice - 1))]}"

        if [ "$selected" = ".." ]; then
            dir="$(dirname "$dir")"
            continue
        fi

        if [ -d "$selected" ]; then
            dir="$selected"
            continue
        fi

        # Arquivo selecionado
        SELECTED_FILE="$selected"
        return 0
    done
}

# ══════════════════════════════════════════════
# Processamento de arquivos locais
# ══════════════════════════════════════════════

process_local_file() {
    local file="$1"
    local ext="${file##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    info "Processando: $(basename "$file") ($(du -h "$file" | cut -f1))"

    case "$ext" in
        dmg)
            DMG_FILE="$file"
            ;;
        img)
            IMG_FILE="$file"
            ;;
        iso)
            IMG_FILE="$file"
            ;;
        pkg)
            process_pkg "$file"
            ;;
        *)
            error "Formato nao suportado: .$ext"
            ;;
    esac
}

process_pkg() {
    local pkg_file="$1"

    info "Extraindo conteudo do .pkg..."

    # Verificar conteudo com bsdtar
    if command -v bsdtar &>/dev/null; then
        info "Conteudo do .pkg:"
        bsdtar -tvf "$pkg_file" 2>&1 || true

        # Tentar extrair SharedSupport.dmg ou BaseSystem.dmg
        for name in BaseSystem.dmg SharedSupport.dmg; do
            if bsdtar -tvf "$pkg_file" 2>/dev/null | grep -q "$name"; then
                info "Extraindo $name..."
                bsdtar -xvf "$pkg_file" -C "$WORK_DIR" "$name" 2>&1 || true

                if [ -f "$WORK_DIR/$name" ]; then
                    info "$name extraido: $(du -h "$WORK_DIR/$name" | cut -f1)"
                    DMG_FILE="$WORK_DIR/$name"
                    return 0
                fi
            fi
        done
    fi

    # Fallback: tentar 7z
    if command -v 7z &>/dev/null; then
        info "Tentando extrair com 7z..."
        7z x "$pkg_file" -o"$WORK_DIR/pkg_extracted" 2>/dev/null || true

        local found
        found=$(find "$WORK_DIR/pkg_extracted" -name "*.dmg" -type f 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            DMG_FILE="$found"
            return 0
        fi
    fi

    error "Nao foi possivel extrair .dmg do .pkg"
}

# ══════════════════════════════════════════════
# Converter DMG para IMG gravavel
# ══════════════════════════════════════════════

prepare_image() {
    # Se ja temos IMG, usar direto
    if [ -n "$IMG_FILE" ]; then
        info "Usando imagem: $(basename "$IMG_FILE")"
        FLASH_IMAGE="$IMG_FILE"
        return 0
    fi

    [ -n "$DMG_FILE" ] || error "Nenhum arquivo .dmg disponivel"

    info "Convertendo $(basename "$DMG_FILE") para .img..."
    dmg2img "$DMG_FILE" "$WORK_DIR/macOS.img" 2>&1 || error "Falha no dmg2img"

    FLASH_IMAGE="$WORK_DIR/macOS.img"
    info "Imagem pronta: $(du -h "$FLASH_IMAGE" | cut -f1)"
}

# ══════════════════════════════════════════════
# Download via macrecovery (OpenCore)
# ══════════════════════════════════════════════

download_recovery() {
    step "Baixar macrecovery.py (OpenCore)"

    if [ -f "$WORK_DIR/macrecovery/macrecovery.py" ]; then
        info "macrecovery.py ja existe."
    else
        info "Clonando macrecovery do OpenCorePkg..."
        rm -rf "$WORK_DIR/opencore_tmp"
        git clone --depth 1 --filter=blob:none --sparse \
            https://github.com/acidanthera/OpenCorePkg.git "$WORK_DIR/opencore_tmp" 2>&1
        cd "$WORK_DIR/opencore_tmp"
        git sparse-checkout set Utilities/macrecovery 2>&1
        mkdir -p "$WORK_DIR/macrecovery"
        cp -r Utilities/macrecovery/* "$WORK_DIR/macrecovery/"
        cd "$WORK_DIR"
        rm -rf "$WORK_DIR/opencore_tmp"
        info "macrecovery.py pronto."
    fi

    step "Escolher versao do macOS"

    echo -e "  ${BOLD}Qual versao do macOS?${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC}  macOS Sequoia     (15)   ${DIM}— mais recente${NC}"
    echo -e "  ${GREEN}[2]${NC}  macOS Sonoma      (14)"
    echo -e "  ${GREEN}[3]${NC}  macOS Ventura     (13)"
    echo -e "  ${GREEN}[4]${NC}  macOS Monterey    (12)"
    echo -e "  ${GREEN}[5]${NC}  macOS Big Sur     (11)"
    echo -e "  ${GREEN}[6]${NC}  macOS Catalina    (10.15)"
    echo -e "  ${GREEN}[7]${NC}  macOS Mojave      (10.14)"
    echo -e "  ${GREEN}[8]${NC}  macOS High Sierra (10.13)"
    echo ""
    echo -e "  Escolha [1-8] (padrao: 1):"
    read -r ver
    ver=${ver:-1}

    case "$ver" in
        1) BOARD="Mac-937A206F2EE63C01"; MACOS_NAME="macOS Sequoia" ;;
        2) BOARD="Mac-827FAC58A8FDFA22"; MACOS_NAME="macOS Sonoma" ;;
        3) BOARD="Mac-4B682C642B45593E"; MACOS_NAME="macOS Ventura" ;;
        4) BOARD="Mac-FFE5EF870D7BA81A"; MACOS_NAME="macOS Monterey" ;;
        5) BOARD="Mac-42FD25EABCABB274"; MACOS_NAME="macOS Big Sur" ;;
        6) BOARD="Mac-00BE6ED71E35EB86"; MACOS_NAME="macOS Catalina" ;;
        7) BOARD="Mac-7BA5B2DFE22DDD8C"; MACOS_NAME="macOS Mojave" ;;
        8) BOARD="Mac-7BA5B2D9E42DDD94"; MACOS_NAME="macOS High Sierra" ;;
        *) error "Opcao invalida: $ver" ;;
    esac

    info "Selecionado: $MACOS_NAME"

    step "Baixando BaseSystem.dmg da Apple"

    RECOVERY_DIR="$WORK_DIR/recovery"
    mkdir -p "$RECOVERY_DIR"

    info "Baixando recovery do $MACOS_NAME..."
    info "Pode demorar dependendo da conexao..."
    echo ""

    cd "$WORK_DIR/macrecovery"
    python3 macrecovery.py -b "$BOARD" -m 00000000000000000 -o "$RECOVERY_DIR" download 2>&1
    echo ""

    # Encontrar o arquivo baixado
    if [ -f "$RECOVERY_DIR/BaseSystem.dmg" ]; then
        DMG_FILE="$RECOVERY_DIR/BaseSystem.dmg"
        CHUNKLIST="$RECOVERY_DIR/BaseSystem.chunklist"
    elif [ -f "$RECOVERY_DIR/RecoveryImage.dmg" ]; then
        DMG_FILE="$RECOVERY_DIR/RecoveryImage.dmg"
        CHUNKLIST="$RECOVERY_DIR/RecoveryImage.chunklist"
    else
        info "Conteudo do diretorio:"
        ls -lah "$RECOVERY_DIR/" 2>/dev/null || true
        error "Nenhuma imagem baixada. Verifique sua conexao."
    fi

    IS_RECOVERY=true
    info "Baixado: $(basename "$DMG_FILE") ($(du -h "$DMG_FILE" | cut -f1))"
}

# ══════════════════════════════════════════════
# Selecionar e validar pendrive
# ══════════════════════════════════════════════

select_usb() {
    info "Dispositivos removiveis (USB) detectados:"
    echo ""
    echo -e "  ${YELLOW}NUM   DISPOSITIVO   TAMANHO   MODELO${NC}"
    echo "  ─────────────────────────────────────────────────"

    DEVICES=()
    local idx=0
    while IFS= read -r line; do
        local dev size model removable transport
        dev=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        model=$(echo "$line" | awk '{$1=""; $2=""; print}' | sed 's/^ *//')
        removable=$(cat /sys/block/"$(basename "$dev")"/removable 2>/dev/null || echo "0")
        transport=$(udevadm info --query=property --name="$dev" 2>/dev/null | grep "ID_BUS=usb" || true)

        if [ "$removable" = "1" ] || [ -n "$transport" ]; then
            idx=$((idx + 1))
            DEVICES+=("$dev")
            echo -e "  ${GREEN}[$idx]${NC} $dev   $size   $model"
        fi
    done < <(lsblk -dno NAME,SIZE,MODEL -e 7,11 | grep -v "^$" | awk '{print "/dev/"$0}')

    echo ""

    if [ ${#DEVICES[@]} -eq 0 ]; then
        warn "Nenhum pendrive detectado!"
        lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL -e 7,11
        error "Conecte o pendrive e rode novamente."
    fi

    echo -e "  Digite o numero do pendrive, ou ${RED}0${NC} para cancelar:"
    read -r choice

    [ "$choice" = "0" ] || [ -z "$choice" ] && { info "Cancelado."; exit 0; }

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -gt ${#DEVICES[@]} ] || [ "$choice" -lt 1 ]; then
        error "Opcao invalida: $choice"
    fi

    TARGET_DEV="${DEVICES[$((choice - 1))]}"
    TARGET_SIZE=$(lsblk -dno SIZE "$TARGET_DEV" 2>/dev/null)
    TARGET_MODEL=$(lsblk -dno MODEL "$TARGET_DEV" 2>/dev/null)

    echo ""
    warn "========================================="
    warn "  TODOS OS DADOS SERAO APAGADOS!"
    warn "========================================="
    echo ""
    echo -e "  Dispositivo: ${RED}$TARGET_DEV${NC}"
    echo -e "  Tamanho:     $TARGET_SIZE"
    echo -e "  Modelo:      $TARGET_MODEL"
    echo ""
    echo -e "  Digite ${RED}SIM${NC} (maiusculo) para confirmar:"
    read -r confirm

    [ "$confirm" = "SIM" ] || { info "Cancelado."; exit 0; }
}

# ══════════════════════════════════════════════
# Gravar no pendrive
# ══════════════════════════════════════════════

flash_usb() {
    step "Formatando e gravando no pendrive"

    # Desmontar
    info "Desmontando particoes de $TARGET_DEV..."
    for part in "${TARGET_DEV}"*; do
        umount "$part" 2>/dev/null || true
    done

    if [ "$IS_RECOVERY" = true ]; then
        # Metodo OpenCore: GPT com 2 particoes
        info "Limpando tabela de particoes..."
        sgdisk --zap-all "$TARGET_DEV" 2>&1 || true
        # Recriar GPT limpa apos o zap
        info "Criando nova tabela GPT..."
        sgdisk --clear "$TARGET_DEV" 2>&1 || error "Falha ao criar tabela GPT"
        info "Criando particoes (EFI + Recovery)..."
        sgdisk --new=1:0:+200M -t 1:0700 "$TARGET_DEV" 2>&1 || error "Falha ao criar particao EFI"
        sgdisk --new=2:0:0 -t 2:af00 "$TARGET_DEV" 2>&1 || error "Falha ao criar particao Recovery"
        info "Tabela de particoes:"
        sgdisk -p "$TARGET_DEV" 2>&1

        sleep 2
        partprobe "$TARGET_DEV" 2>/dev/null || true
        sleep 1

        # Detectar particoes
        local p1="${TARGET_DEV}1" p2="${TARGET_DEV}2"
        [ -b "$p1" ] || { p1="${TARGET_DEV}p1"; p2="${TARGET_DEV}p2"; }
        [ -b "$p1" ] || error "Particao 1 nao encontrada"
        [ -b "$p2" ] || error "Particao 2 nao encontrada"

        info "Formatando $p1 como FAT32..."
        mkfs.vfat -F 32 -n "OPENCORE" "$p1" 2>&1

        info "Gravando recovery em $p2..."
        info "Listando particoes do DMG:"
        dmg2img -l "$DMG_FILE" 2>&1 || true
        echo ""

        # Tentar gravar com diferentes numeros de particao
        dmg2img -p 4 "$DMG_FILE" "$p2" 2>&1 || \
        dmg2img -p 3 "$DMG_FILE" "$p2" 2>&1 || \
        dmg2img -p 2 "$DMG_FILE" "$p2" 2>&1 || \
        dmg2img -p 0 "$DMG_FILE" "$p2" 2>&1 || \
        error "Falha ao gravar com dmg2img"

        # Copiar apenas o chunklist na EFI (o DMG ja foi gravado na particao 2)
        # O BaseSystem.dmg e muito grande (~753MB) para a EFI (200MB)
        info "Configurando particao EFI..."
        EFI_MOUNT="$WORK_DIR/efi_mount"
        mkdir -p "$EFI_MOUNT"
        mount "$p1" "$EFI_MOUNT"
        mkdir -p "$EFI_MOUNT/com.apple.recovery.boot"
        [ -f "$CHUNKLIST" ] && cp "$CHUNKLIST" "$EFI_MOUNT/com.apple.recovery.boot/" 2>/dev/null || true
        info "Particao EFI pronta (copie seu OpenCore EFI aqui depois)"
        info "Conteudo da EFI:"
        find "$EFI_MOUNT" -type f 2>/dev/null || true
        umount "$EFI_MOUNT" 2>/dev/null || true
    else
        # Metodo direto: dd da imagem
        info "Gravando imagem em $TARGET_DEV com dd..."
        info "Pode demorar varios minutos..."
        echo ""

        if [ -n "$FLASH_IMAGE" ]; then
            dd if="$FLASH_IMAGE" of="$TARGET_DEV" bs=4M status=progress conv=fsync 2>&1
        elif [ -n "$DMG_FILE" ]; then
            info "Convertendo e gravando..."
            dmg2img "$DMG_FILE" "$WORK_DIR/temp.img" 2>&1
            dd if="$WORK_DIR/temp.img" of="$TARGET_DEV" bs=4M status=progress conv=fsync 2>&1
            rm -f "$WORK_DIR/temp.img"
        fi
    fi

    echo ""
    info "Sincronizando..."
    sync

    info "Resultado:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "$TARGET_DEV" 2>/dev/null || true
}

# ══════════════════════════════════════════════
# Instalador Offline Completo com OpenCore
# ══════════════════════════════════════════════

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
    oc_fetch_kexts "acidanthera/AirportBrcmFixup" "RELEASE.zip" "$kdir"
    oc_fetch_kexts "acidanthera/BrcmPatchRAM"     "RELEASE.zip" "$kdir"
    oc_fetch_kexts "acidanthera/RestrictEvents"   "RELEASE.zip" "$kdir"
    oc_fetch_kexts "acidanthera/CryptexFixup"     "RELEASE.zip" "$kdir"

    info "Kexts instalados:"
    ls "$kdir/" 2>/dev/null || true
}

generate_config_plist() {
    local model="$1" kexts_dir="$2" out_file="$3"
    info "Gerando config.plist para $model..."

    SMBIOS_MODEL="$model" OC_KEXTS_DIR="$kexts_dir" OC_CONFIG_OUT="$out_file" \
    python3 << 'PYEOF'
import plistlib, os, uuid

model     = os.environ["SMBIOS_MODEL"]
kexts_dir = os.environ["OC_KEXTS_DIR"]
out_file  = os.environ["OC_CONFIG_OUT"]

kext_order = [
    "Lilu", "WhateverGreen", "VirtualSMC",
    "SMCBatteryManager", "SMCLightSensor", "SMCProcessor", "SMCSuperIO",
    "AirportBrcmFixup",
    "BrcmFirmwareData", "BrcmPatchRAM3", "BrcmBluetoothInjector",
    "RestrictEvents", "CryptexFixup",
]

min_max = {
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
                "UIScale": bytes([1]),
            },
            "7C436110-AB2A-4BBB-A880-FE41995C9F82": {
                "boot-args": "-v keepsyms=1 amfi_get_out_of_my_way=0x01 brcmfx-driver=2 revpatch=sbvmm,asset -wegnoegpu igfxonln=1",
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
            "GopBurstMode": False, "GopPassThrough": "Disabled",
            "IgnoreTextInGraphics": False, "InitialMode": "Auto",
            "ProvideConsoleGop": True, "ReconnectGraphicsOnConnect": False,
            "ReconnectOnResChange": False, "ReplaceTabWithSpace": False,
            "Resolution": "Max", "SanitiseClearScreen": False,
            "TextRenderer": "BuiltinGraphics", "UIScale": -1, "UgaPassThrough": False,
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
PYEOF
}

create_offline_installer() {
    step "Instalador Offline Completo (OpenCore + macOS sem internet)"

    echo -e "  ${BOLD}Modelo do Mac:${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC}  MacBookPro11,5  ${DIM}(MBP 2015 15\" dGPU AMD R9 M370X)${NC}"
    echo -e "  ${GREEN}[2]${NC}  MacBookPro11,4  ${DIM}(MBP 2015 15\" so iGPU Intel Iris)${NC}"
    echo -e "  ${GREEN}[3]${NC}  MacBookPro12,1  ${DIM}(MBP 2015 13\")${NC}"
    echo -e "  ${GREEN}[4]${NC}  Outro (digitar)${NC}"
    echo ""
    echo -e "  Escolha [1-4] (padrao: 1):"
    read -r model_choice
    case "$model_choice" in
        2) SMBIOS_MODEL="MacBookPro11,4" ;;
        3) SMBIOS_MODEL="MacBookPro12,1" ;;
        4) echo -e "  Modelo (ex: MacBookPro11,5):"; read -r SMBIOS_MODEL ;;
        *) SMBIOS_MODEL="MacBookPro11,5" ;;
    esac
    info "Modelo SMBIOS: $SMBIOS_MODEL"

    step "Selecionar imagem do instalador"
    echo -e "  ${BOLD}Fonte:${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC}  Usar arquivo .hfs existente"
    echo -e "  ${GREEN}[2]${NC}  Usar InstallAssistant.pkg (extrai e converte)"
    echo -e "  ${GREEN}[3]${NC}  Navegar e selecionar arquivo"
    echo ""
    echo -e "  Escolha [1-3]:"
    read -r img_src

    INSTALLER_HFS=""
    case "$img_src" in
        1)
            # Busca no diretorio atual, no diretorio pai e no home do usuario
            local search_roots=("$(pwd)" "$(dirname "$(pwd)")" "/home" "/root" "/tmp")
            mapfile -t hfs_files < <(
                for r in "${search_roots[@]}"; do
                    find "$r" -maxdepth 5 -name "*.hfs" -type f 2>/dev/null
                done | sort -u
            )
            if [ ${#hfs_files[@]} -eq 0 ]; then
                error "Nenhum .hfs encontrado abaixo de $(pwd)"
            fi
            echo ""
            echo -e "  ${BOLD}Arquivos .hfs encontrados:${NC}"
            for i in "${!hfs_files[@]}"; do
                echo -e "  ${GREEN}[$((i+1))]${NC}  ${hfs_files[$i]}  ${DIM}($(du -h "${hfs_files[$i]}" | cut -f1))${NC}"
            done
            echo ""
            echo -e "  Escolha:"
            read -r hfs_ch
            INSTALLER_HFS="${hfs_files[$((hfs_ch - 1))]}"
            ;;
        2)
            local pkg_file
            pkg_file=$(find "$(pwd)" -maxdepth 3 -name "InstallAssistant.pkg" -type f 2>/dev/null | head -1)
            [ -z "$pkg_file" ] && error "InstallAssistant.pkg nao encontrado em $(pwd)"
            info "Extraindo SharedSupport.dmg de $(basename "$pkg_file")..."
            mkdir -p "$WORK_DIR/pkg_ex"
            7z x "$pkg_file" -o"$WORK_DIR/pkg_ex" -y > /dev/null 2>&1 || true
            local shared_dmg
            shared_dmg=$(find "$WORK_DIR/pkg_ex" -name "SharedSupport.dmg" -type f | head -1)
            if [ -z "$shared_dmg" ]; then
                bsdtar -xf "$pkg_file" -C "$WORK_DIR/pkg_ex" 2>/dev/null || true
                shared_dmg=$(find "$WORK_DIR/pkg_ex" -name "SharedSupport.dmg" | head -1)
            fi
            [ -z "$shared_dmg" ] && error "Nao foi possivel extrair SharedSupport.dmg"
            info "Convertendo para HFS... (pode demorar)"
            dmg2img "$shared_dmg" "$WORK_DIR/installer.hfs" 2>&1 || error "Falha na conversao dmg2img"
            INSTALLER_HFS="$WORK_DIR/installer.hfs"
            ;;
        3)
            step "Selecionar arquivo do instalador"
            if browse_files "$(pwd)"; then
                INSTALLER_HFS="$SELECTED_FILE"
            else
                error "Nenhum arquivo selecionado."
            fi
            ;;
        *)
            error "Opcao invalida"
            ;;
    esac

    [ -f "$INSTALLER_HFS" ] || error "Arquivo do instalador nao encontrado: ${INSTALLER_HFS:-vazio}"
    info "Instalador: $INSTALLER_HFS ($(du -h "$INSTALLER_HFS" | cut -f1))"

    step "Selecionar pendrive"
    select_usb

    step "Particionando pendrive"
    info "Desmontando $TARGET_DEV..."
    for part in "${TARGET_DEV}"*; do
        umount "$part" 2>/dev/null || true
    done

    sgdisk --zap-all "$TARGET_DEV" 2>&1 || true
    sgdisk --clear   "$TARGET_DEV" 2>&1 || error "Falha ao criar GPT"
    sgdisk --new=1:0:+300M -t 1:ef00 -c 1:"EFI"          "$TARGET_DEV" 2>&1 || error "Falha ao criar EFI"
    sgdisk --new=2:0:0     -t 2:af00 -c 2:"macOSInstaller" "$TARGET_DEV" 2>&1 || error "Falha ao criar particao"
    sgdisk -p "$TARGET_DEV" 2>&1

    sleep 2; partprobe "$TARGET_DEV" 2>/dev/null || true; sleep 1

    local p1="${TARGET_DEV}1" p2="${TARGET_DEV}2"
    [ -b "$p1" ] || { p1="${TARGET_DEV}p1"; p2="${TARGET_DEV}p2"; }
    [ -b "$p1" ] || error "Particao EFI nao encontrada"
    [ -b "$p2" ] || error "Particao do instalador nao encontrada"

    info "Formatando $p1 como FAT32 (EFI)..."
    mkfs.vfat -F 32 -n "EFI" "$p1" 2>&1

    step "Gravando instalador no pendrive"
    info "Gravando $(basename "$INSTALLER_HFS") → $p2"
    info "Isso pode demorar varios minutos..."
    dd if="$INSTALLER_HFS" of="$p2" bs=4M status=progress conv=fsync 2>&1 \
        || error "Falha ao gravar imagem do instalador"

    step "Configurando OpenCore na EFI"
    EFI_MOUNT="$WORK_DIR/efi_offline"
    mkdir -p "$EFI_MOUNT"
    mount "$p1" "$EFI_MOUNT"

    build_opencore_efi "$EFI_MOUNT/EFI"
    generate_config_plist "$SMBIOS_MODEL" "$EFI_MOUNT/EFI/OC/Kexts" "$EFI_MOUNT/EFI/OC/config.plist"

    info "Estrutura EFI final:"
    find "$EFI_MOUNT" -type f 2>/dev/null | sed "s|$EFI_MOUNT/||" | sort

    umount "$EFI_MOUNT" 2>/dev/null || true
    sync
    info "Sincronizado."

    step "CONCLUIDO!"
    echo ""
    info "USB com instalador offline do macOS + OpenCore pronto!"
    echo ""
    info "${BOLD}Como usar:${NC}"
    info "  1. Conecte o USB no Mac"
    info "  2. Ligue segurando Option/Alt"
    info "  3. Selecione 'EFI Boot' ou 'OpenCore'"
    info "  4. No picker do OpenCore: selecione o instalador do macOS"
    info "  5. Instale o macOS normalmente (SEM internet)"
    info "  6. Apos reiniciar no macOS instalado: baixe o OCLP e aplique patches"
    echo ""
    warn "IMPORTANTE: apos a instalacao, rode o OpenCore Legacy Patcher"
    warn "para ativar GPU, WiFi e outros recursos do $SMBIOS_MODEL"
    warn "OCLP: https://github.com/dortania/OpenCore-Legacy-Patcher/releases"
}

# ══════════════════════════════════════════════
# Menu principal
# ══════════════════════════════════════════════

main() {
    echo ""
    echo -e "  ${BOLD}${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "  ${BOLD}${CYAN}║     macOS USB Creator para Linux       ║${NC}"
    echo -e "  ${BOLD}${CYAN}║              v${VERSION}                    ║${NC}"
    echo -e "  ${BOLD}${CYAN}╚════════════════════════════════════════╝${NC}"
    echo ""

    check_root

    step "Verificando dependencias"
    install_deps

    mkdir -p "$WORK_DIR"

    # Se passou arquivo como argumento
    if [ -n "$1" ] && [ -f "$1" ]; then
        step "Usando arquivo: $(basename "$1")"
        process_local_file "$1"
    else
        step "Origem da imagem"

        echo -e "  ${GREEN}[1]${NC}  ${BOLD}Baixar da Apple${NC}  ${DIM}(BaseSystem via macrecovery)${NC}"
        echo -e "  ${GREEN}[2]${NC}  ${BOLD}Usar arquivo local${NC}  ${DIM}(.pkg / .dmg / .iso / .img)${NC}"
        echo -e "  ${GREEN}[3]${NC}  ${BOLD}Instalador offline completo${NC}  ${DIM}(OpenCore + instalador sem internet — MBP 2013-2015)${NC}"
        echo ""
        echo -e "  Escolha [1-3]:"
        read -r source_choice

        case "$source_choice" in
            1)
                IS_RECOVERY=true
                download_recovery
                ;;
            2)
                IS_RECOVERY=false
                step "Selecionar arquivo"
                if browse_files "$(pwd)"; then
                    process_local_file "$SELECTED_FILE"
                else
                    error "Nenhum arquivo selecionado."
                fi
                ;;
            3)
                create_offline_installer
                exit 0
                ;;
            *)
                error "Opcao invalida"
                ;;
        esac
    fi

    # Preparar imagem se necessario (para arquivos locais nao-recovery)
    if [ "$IS_RECOVERY" != true ] && [ -z "$FLASH_IMAGE" ]; then
        step "Preparando imagem"
        prepare_image
    fi

    step "Selecionar pendrive"
    select_usb

    flash_usb

    step "CONCLUIDO!"

    echo ""
    if [ "$IS_RECOVERY" = true ]; then
        info "USB de recovery do ${MACOS_NAME:-macOS} criado!"
        echo ""
        info "Para bootar no Mac:"
        info "  1. Conecte o USB no Mac"
        info "  2. Ligue segurando Option/Alt"
        info "  3. Selecione o disco de recovery"
        info "  4. O Mac baixara o restante pela internet"
    else
        info "Imagem gravada no USB com sucesso!"
        echo ""
        info "Para bootar:"
        info "  1. Conecte o USB no computador"
        info "  2. Selecione boot pelo USB na BIOS/EFI"
    fi

    echo ""

    # Limpeza
    echo -e "Remover arquivos temporarios em $WORK_DIR? (s/n)"
    read -r resp
    if [[ "$resp" =~ ^[sS]$ ]]; then
        rm -rf "$WORK_DIR"
        info "Temporarios removidos."
    fi

    info "Pode remover o pendrive com seguranca."
}

main "$@"
