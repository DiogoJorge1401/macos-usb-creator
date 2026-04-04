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
    echo -e "  ${GREEN}[1]${NC}  ${BOLD}Baixar da Apple via gibMacOS${NC}  ${DIM}(~13 GB — recomendado se nao tem o instalador)${NC}"
    echo -e "  ${GREEN}[2]${NC}  Usar arquivo .hfs existente"
    echo -e "  ${GREEN}[3]${NC}  Usar InstallAssistant.pkg local (extrai e converte)"
    echo -e "  ${GREEN}[4]${NC}  Navegar e selecionar arquivo"
    echo ""
    echo -e "  Escolha [1-4]:"
    read -r img_src

    INSTALLER_HFS=""
    case "$img_src" in
        1)
            echo ""
            echo -e "  ${BOLD}Versao do macOS:${NC}"
            echo ""
            echo -e "  ${GREEN}[1]${NC}  macOS Sonoma (14)    ${DIM}— recomendado para MBP 2013-2015${NC}"
            echo -e "  ${GREEN}[2]${NC}  macOS Sequoia (15)   ${DIM}— mais recente, suporte OCLP pode variar${NC}"
            echo -e "  ${GREEN}[3]${NC}  macOS Ventura (13)   ${DIM}— opcao mais estavel para hardware antigo${NC}"
            echo -e "  ${GREEN}[4]${NC}  Outra (modo interativo)${NC}"
            echo ""
            echo -e "  Escolha [1-4] (padrao: 1):"
            read -r ver_choice
            local macos_ver
            case "$ver_choice" in
                2) macos_ver="Sequoia" ;;
                3) macos_ver="Ventura" ;;
                4) macos_ver="" ;;
                *) macos_ver="Sonoma" ;;
            esac
            if [ -n "$macos_ver" ]; then
                gibmacos_download_and_convert "$macos_ver"
            else
                gibmacos_download "" "$WORK_DIR"
                # Converter o pkg baixado
                info "Extraindo SharedSupport.dmg de InstallAssistant.pkg..."
                mkdir -p "$WORK_DIR/pkg_ex"
                7z x "$GIBMACOS_PKG" -o"$WORK_DIR/pkg_ex" -y > /dev/null 2>&1 || true
                local shared_dmg
                shared_dmg=$(find "$WORK_DIR/pkg_ex" -name "SharedSupport.dmg" -type f | head -1)
                if [ -z "$shared_dmg" ]; then
                    bsdtar -xf "$GIBMACOS_PKG" -C "$WORK_DIR/pkg_ex" 2>/dev/null || true
                    shared_dmg=$(find "$WORK_DIR/pkg_ex" -name "SharedSupport.dmg" | head -1)
                fi
                [ -z "$shared_dmg" ] && error "Nao foi possivel extrair SharedSupport.dmg"
                info "Convertendo para HFS... (pode demorar)"
                dmg2img "$shared_dmg" "$WORK_DIR/installer.hfs" 2>&1 || error "Falha na conversao dmg2img"
                INSTALLER_HFS="$WORK_DIR/installer.hfs"
            fi
            ;;
        2)
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
        3)
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
        4)
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

    step "Incluindo ferramentas extras no pendrive"
    oc_download_oclp "$EFI_MOUNT"
    oc_copy_skip_setup "$EFI_MOUNT"

    info "Estrutura EFI final:"
    find "$EFI_MOUNT" -type f 2>/dev/null | sed "s|$EFI_MOUNT/||" | sort

    umount "$EFI_MOUNT" 2>/dev/null || true
    sync
    info "Sincronizado."

    step "CONCLUIDO!"
    echo ""
    info "USB com instalador offline do macOS + OpenCore + OCLP pronto!"
    echo ""
    info "${BOLD}Como usar:${NC}"
    info ""
    info "  ${BOLD}INSTALACAO:${NC}"
    info "  1. Conecte o USB no Mac"
    info "  2. Ligue segurando Option/Alt"
    info "  3. Selecione 'EFI Boot' ou 'OpenCore'"
    info "  4. No picker do OpenCore: selecione o instalador do macOS"
    info "  5. Abra o Disk Utility → formate o SSD como APFS + GUID"
    info "  6. Instale o macOS normalmente (SEM internet)"
    info ""
    info "  ${BOLD}PULAR SETUP ASSISTANT (sem WiFi):${NC}"
    info "  7. Quando o Mac reiniciar apos instalar, boot pelo USB de novo"
    info "  8. No picker: selecione 'macOS Base System' ou 'Recovery'"
    info "  9. No menu: Utilitarios → Terminal"
    info "  10. Execute:"
    info "      ${CYAN}diskutil mount /dev/disk0s1${NC}"
    info "      ${CYAN}bash /Volumes/EFI/skip-setup.sh${NC}"
    info "  11. Defina seu nome de usuario e senha"
    info "  12. Reinicie → o macOS vai direto para o login!"
    info ""
    info "  ${BOLD}ATIVAR WIFI/GPU (pos-instalacao):${NC}"
    info "  13. No Mac, abra o Terminal:"
    info "      ${CYAN}sudo diskutil mount /dev/disk2s1${NC}"
    info "      ${CYAN}cp /Volumes/EFI/OCLP/*.pkg ~/Desktop/${NC}"
    info "  14. Instale o OCLP → Post-Install Root Patch → Reinicie"
    echo ""
    warn "TUDO esta no pendrive: OpenCore, OCLP e skip-setup!"
    warn "Nenhuma conexao com internet necessaria em momento algum."
}
