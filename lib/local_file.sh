#!/bin/bash

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
