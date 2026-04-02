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
        info "Criando tabela GPT (EFI + Recovery)..."
        sgdisk --zap-all "$TARGET_DEV" 2>&1
        sgdisk --new=1:0:+200M -t 1:0700 "$TARGET_DEV" 2>&1
        sgdisk --new=2:0:0 -t 2:af00 "$TARGET_DEV" 2>&1

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

        # Copiar recovery na particao EFI
        info "Copiando arquivos de recovery na EFI..."
        EFI_MOUNT="$WORK_DIR/efi_mount"
        mkdir -p "$EFI_MOUNT"
        mount "$p1" "$EFI_MOUNT"
        mkdir -p "$EFI_MOUNT/com.apple.recovery.boot"
        cp "$DMG_FILE" "$EFI_MOUNT/com.apple.recovery.boot/" 2>/dev/null || true
        [ -f "$CHUNKLIST" ] && cp "$CHUNKLIST" "$EFI_MOUNT/com.apple.recovery.boot/" 2>/dev/null || true
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
        echo ""
        echo -e "  Escolha [1-2]:"
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
