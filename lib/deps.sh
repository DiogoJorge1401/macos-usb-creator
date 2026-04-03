#!/bin/bash

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
