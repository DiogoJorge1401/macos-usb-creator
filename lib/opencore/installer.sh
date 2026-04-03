#!/bin/bash

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
