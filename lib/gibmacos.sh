#!/bin/bash

GIBMACOS_DIR="$WORK_DIR/gibMacOS"
GIBMACOS_REPO="https://github.com/corpnewt/gibMacOS"

gibmacos_clone() {
    if [ -d "$GIBMACOS_DIR" ] && [ -f "$GIBMACOS_DIR/gibMacOS.py" ]; then
        info "gibMacOS ja existe (cache)"
        return 0
    fi
    info "Clonando gibMacOS..."
    rm -rf "$GIBMACOS_DIR"
    git clone --depth 1 "$GIBMACOS_REPO" "$GIBMACOS_DIR" 2>&1 \
        || error "Falha ao clonar gibMacOS"
    info "  ✓ gibMacOS clonado"
}

gibmacos_list_versions() {
    # Executa gibMacOS em modo lista e filtra versoes do macOS
    python3 "$GIBMACOS_DIR/gibMacOS.py" --no-interactive --list-products 2>/dev/null \
        | grep -iE "InstallAssistant|macOS" || true
}

gibmacos_download() {
    local version_name="$1"  # ex: "Sonoma", "Sequoia", "Ventura"
    local dest_dir="$2"

    gibmacos_clone

    step "Baixando macOS $version_name via gibMacOS"
    info "Isto pode demorar bastante (~13 GB)..."
    info "O download vem direto dos servidores da Apple."
    echo ""

    # gibMacOS baixa para uma subpasta em macOS Downloads/
    # Usar modo nao-interativo com filtro de versao
    cd "$GIBMACOS_DIR"

    # Tentar modo nao-interativo primeiro
    local download_ok=false

    # gibMacOS aceita argumentos posicionais para selecionar versao
    # O modo mais confiavel e o interativo, mas vamos tentar automatizar
    if python3 gibMacOS.py --no-interactive \
        --version "$version_name" \
        --only-installer \
        2>&1; then
        download_ok=true
    fi

    # Se o modo nao-interativo falhou, tentar com argumentos alternativos
    if [ "$download_ok" = false ]; then
        info "Modo automatico nao disponivel. Iniciando modo interativo..."
        info ""
        info "${BOLD}Instrucoes:${NC}"
        info "  1. Selecione a versao do macOS ${BOLD}$version_name${NC}"
        info "  2. O gibMacOS vai baixar o InstallAssistant.pkg"
        info "  3. Aguarde o download completar"
        info ""
        python3 gibMacOS.py 2>&1 || warn "gibMacOS retornou com erro"
    fi

    cd "$OLDPWD"

    # Procurar o InstallAssistant.pkg baixado
    local pkg_file
    pkg_file=$(find "$GIBMACOS_DIR/macOS Downloads" -name "InstallAssistant.pkg" -type f 2>/dev/null \
        | head -1)

    if [ -z "$pkg_file" ]; then
        # Tentar procurar em subdiretorios com o nome da versao
        pkg_file=$(find "$GIBMACOS_DIR" -name "InstallAssistant.pkg" -type f 2>/dev/null \
            | head -1)
    fi

    if [ -z "$pkg_file" ]; then
        error "InstallAssistant.pkg nao encontrado apos download. Verifique a conexao."
    fi

    local pkg_size; pkg_size=$(du -h "$pkg_file" | cut -f1)
    info "  ✓ InstallAssistant.pkg encontrado ($pkg_size)"
    info "    $pkg_file"

    # Copiar/mover para destino se especificado
    if [ -n "$dest_dir" ] && [ "$dest_dir" != "$(dirname "$pkg_file")" ]; then
        mkdir -p "$dest_dir"
        mv "$pkg_file" "$dest_dir/"
        pkg_file="$dest_dir/InstallAssistant.pkg"
    fi

    # Exportar caminho para uso externo
    GIBMACOS_PKG="$pkg_file"
}

gibmacos_download_and_convert() {
    local version_name="$1"

    gibmacos_download "$version_name" "$WORK_DIR"

    [ -f "$GIBMACOS_PKG" ] || error "InstallAssistant.pkg nao encontrado"

    step "Extraindo e convertendo instalador"

    info "Extraindo SharedSupport.dmg de InstallAssistant.pkg..."
    mkdir -p "$WORK_DIR/pkg_ex"
    7z x "$GIBMACOS_PKG" -o"$WORK_DIR/pkg_ex" -y > /dev/null 2>&1 || true

    local shared_dmg
    shared_dmg=$(find "$WORK_DIR/pkg_ex" -name "SharedSupport.dmg" -type f | head -1)

    if [ -z "$shared_dmg" ]; then
        info "Tentando com bsdtar..."
        bsdtar -xf "$GIBMACOS_PKG" -C "$WORK_DIR/pkg_ex" 2>/dev/null || true
        shared_dmg=$(find "$WORK_DIR/pkg_ex" -name "SharedSupport.dmg" | head -1)
    fi

    [ -z "$shared_dmg" ] && error "Nao foi possivel extrair SharedSupport.dmg"

    info "Convertendo SharedSupport.dmg para HFS... (pode demorar)"
    dmg2img "$shared_dmg" "$WORK_DIR/installer.hfs" 2>&1 \
        || error "Falha na conversao dmg2img"

    INSTALLER_HFS="$WORK_DIR/installer.hfs"
    local hfs_size; hfs_size=$(du -h "$INSTALLER_HFS" | cut -f1)
    info "  ✓ Instalador convertido ($hfs_size)"
}
