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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${MACOS_USB_WORKDIR:-/var/tmp/macos_usb_creator}"

# Source all lib files in dependency order
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/deps.sh"
source "$SCRIPT_DIR/lib/local_file.sh"
source "$SCRIPT_DIR/lib/recovery.sh"
source "$SCRIPT_DIR/lib/usb.sh"
source "$SCRIPT_DIR/lib/gibmacos.sh"
source "$SCRIPT_DIR/lib/opencore/efi_builder.sh"
source "$SCRIPT_DIR/lib/opencore/installer.sh"

cleanup() {
    [ -n "$LOOP_DEV" ] && sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
    [ -n "$EFI_MOUNT" ] && sudo umount "$EFI_MOUNT" 2>/dev/null || true
    [ -n "$HFS_MOUNT" ] && sudo umount "$HFS_MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

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

                # Perguntar modelo SMBIOS para OpenCore (kexts WiFi/BT)
                echo ""
                echo -e "  ${BOLD}Modelo do Mac (para kexts OpenCore):${NC}"
                echo -e "  ${GREEN}[1]${NC}  MacBookPro11,5  ${DIM}(MBP 2015 15\" dGPU)${NC}"
                echo -e "  ${GREEN}[2]${NC}  MacBookPro11,4  ${DIM}(MBP 2015 15\" iGPU)${NC}"
                echo -e "  ${GREEN}[3]${NC}  MacBookPro12,1  ${DIM}(MBP 2015 13\")${NC}"
                echo -e "  ${GREEN}[4]${NC}  Outro (digitar)"
                echo -e "  Escolha [1-4] (padrao: 1):"
                read -r _m
                case "$_m" in
                    2) SMBIOS_MODEL="MacBookPro11,4" ;;
                    3) SMBIOS_MODEL="MacBookPro12,1" ;;
                    4) echo -e "  Modelo:"; read -r SMBIOS_MODEL ;;
                    *) SMBIOS_MODEL="MacBookPro11,5" ;;
                esac
                info "Modelo: $SMBIOS_MODEL"
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

    # Para recovery: adicionar OpenCore EFI com kexts (WiFi, BT, SMC)
    if [ "$IS_RECOVERY" = true ] && [ -n "$SMBIOS_MODEL" ]; then
        step "Adicionando OpenCore EFI (kexts para WiFi/Bluetooth)"
        local _p1="${TARGET_DEV}1"
        [ -b "${TARGET_DEV}p1" ] && _p1="${TARGET_DEV}p1"
        EFI_MOUNT="$WORK_DIR/efi_recovery"
        mkdir -p "$EFI_MOUNT"
        mount "$_p1" "$EFI_MOUNT"
        build_opencore_efi "$EFI_MOUNT/EFI"
        generate_config_plist "$SMBIOS_MODEL" "$EFI_MOUNT/EFI/OC/Kexts" "$EFI_MOUNT/EFI/OC/config.plist"
        umount "$EFI_MOUNT" 2>/dev/null || true
    fi

    step "CONCLUIDO!"

    echo ""
    if [ "$IS_RECOVERY" = true ]; then
        info "USB de recovery do ${MACOS_NAME:-macOS} criado!"
        echo ""
        info "Para bootar no Mac:"
        info "  1. Conecte o USB no Mac"
        info "  2. Ligue segurando Option/Alt"
        info "  3. Selecione ${BOLD}EFI Boot${NC} (OpenCore — para ter WiFi)"
        info "  4. No picker: selecione a recovery do macOS"
        info "  5. Conecte ao WiFi e clique em Reinstalar macOS"
        warn "  APOS instalar: baixe OCLP para ativar GPU/WiFi permanentemente"
        warn "  OCLP: https://github.com/dortania/OpenCore-Legacy-Patcher/releases"
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
