#!/bin/bash

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
