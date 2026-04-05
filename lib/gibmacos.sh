#!/bin/bash

# Download direto do InstallAssistant.pkg dos servidores da Apple
# Sem dependencia do gibMacOS — usa o catalogo publico da Apple

SUCATALOG_URL="https://swscan.apple.com/content/catalogs/others/index-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog"

apple_fetch_installer_url() {
    local target_version="$1"  # ex: "14" para Sonoma, "15" para Sequoia

    info "Consultando catalogo da Apple..."
    local catalog_file="$WORK_DIR/sucatalog.plist"
    mkdir -p "$WORK_DIR"
    curl -s -f -L -o "$catalog_file" "$SUCATALOG_URL" \
        || error "Falha ao baixar catalogo da Apple. Verifique sua conexao."

    info "Procurando macOS $target_version no catalogo..."

    # Usa python3 para parsear o plist e encontrar o InstallAssistant.pkg
    # Retorna: versao|build|titulo|url
    local result
    result=$(python3 - "$catalog_file" "$target_version" <<'PYEOF'
import plistlib, sys, urllib.request, re

catalog_path = sys.argv[1]
target_ver = sys.argv[2]

with open(catalog_path, "rb") as f:
    catalog = plistlib.load(f)

products = catalog.get("Products", {})
found = []

for pid, pdata in products.items():
    emi = pdata.get("ExtendedMetaInfo", {})
    iapi = emi.get("InstallAssistantPackageIdentifiers", {})
    os_install = iapi.get("OSInstall", "")
    shared = iapi.get("SharedSupport", "")
    if os_install != "com.apple.mpkg.OSInstall" and \
       not shared.startswith("com.apple.pkg.InstallAssistant"):
        continue

    packages = pdata.get("Packages", [])
    pkg_url = None
    basedmg_url = ""
    total_size = 0
    for pkg in packages:
        url = pkg.get("URL", "")
        total_size += pkg.get("Size", 0)
        if url.endswith("InstallAssistant.pkg"):
            pkg_url = url
        elif url.endswith("BaseSystem.dmg"):
            basedmg_url = url
    if not pkg_url:
        continue

    # Buscar versao/build/titulo do distribution file
    dists = pdata.get("Distributions", {})
    dist_url = dists.get("English", dists.get("en", ""))
    version = build = title = ""
    if dist_url:
        try:
            with urllib.request.urlopen(dist_url, timeout=15) as resp:
                dist_text = resp.read().decode("utf-8", errors="replace")
            for vkey in ("macOSProductVersion", "VERSION"):
                tag = "<key>{}</key>".format(vkey)
                if tag in dist_text:
                    version = dist_text.split(tag)[1].split("<string>")[1].split("</string>")[0]
                    break
            for bkey in ("macOSProductBuildVersion", "BUILD"):
                tag = "<key>{}</key>".format(bkey)
                if tag in dist_text:
                    build = dist_text.split(tag)[1].split("<string>")[1].split("</string>")[0]
                    break
            m = re.search(r"<title>(.+?)</title>", dist_text)
            if m:
                title = m.group(1)
        except:
            pass

    if not version.startswith(target_ver):
        continue

    size_gb = round(total_size / (1024**3), 2)
    found.append((version, build, title, pkg_url, size_gb, basedmg_url))

if not found:
    sys.exit(1)

# Ordenar por versao (mais recente por ultimo) e pegar a ultima
found.sort(key=lambda x: [int(p) for p in x[0].split(".")])
best = found[-1]
print("{}|{}|{}|{}|{}|{}".format(*best))
PYEOF
    ) || error "Nenhum instalador macOS $target_version encontrado no catalogo"

    # Parsear resultado
    IFS='|' read -r _APPLE_VERSION _APPLE_BUILD _APPLE_TITLE _APPLE_URL _APPLE_SIZE _APPLE_BASEDMG_URL <<< "$result"
    rm -f "$catalog_file"
}

apple_download_installer() {
    local macos_name="$1"  # ex: "Sonoma", "Sequoia", "Ventura"

    # Mapear nome para versao
    local target_version
    case "${macos_name,,}" in
        sonoma)   target_version="14" ;;
        sequoia)  target_version="15" ;;
        ventura)  target_version="13" ;;
        monterey) target_version="12" ;;
        tahoe)    target_version="26" ;;
        *)        error "Versao desconhecida: $macos_name" ;;
    esac

    apple_fetch_installer_url "$target_version"

    step "Baixando $_APPLE_TITLE $_APPLE_VERSION ($_APPLE_BUILD)"
    info "Tamanho: ${_APPLE_SIZE} GB"
    info "Direto dos servidores da Apple"
    echo ""

    local pkg_file="$WORK_DIR/InstallAssistant.pkg"
    # Tamanho minimo esperado: 10 GB em bytes (qualquer instalador macOS moderno)
    local min_size=10737418240

    # Verificar se ja existe em cache com tamanho valido
    if [ -f "$pkg_file" ]; then
        local cached_size; cached_size=$(stat -c%s "$pkg_file" 2>/dev/null || echo 0)
        if [ "$cached_size" -gt "$min_size" ] 2>/dev/null; then
            info "InstallAssistant.pkg encontrado em cache ($(du -h "$pkg_file" | cut -f1))"
            APPLE_PKG="$pkg_file"
            # Ainda precisa baixar BaseSystem.dmg se disponivel
            if [ -n "$_APPLE_BASEDMG_URL" ]; then
                local base_file="$WORK_DIR/BaseSystem.dmg"
                if [ -f "$base_file" ] && [ "$(stat -c%s "$base_file" 2>/dev/null || echo 0)" -gt 1048576 ]; then
                    info "BaseSystem.dmg encontrado em cache ($(du -h "$base_file" | cut -f1))"
                else
                    info "Baixando BaseSystem.dmg (~500 MB)..."
                    curl -L -f --progress-bar -C - -o "$base_file" "$_APPLE_BASEDMG_URL" \
                        || warn "Falha ao baixar BaseSystem.dmg; sera extraido do pkg"
                fi
                [ -f "$base_file" ] && INSTALLER_BASE_DMG="$base_file"
            fi
            return 0
        else
            warn "InstallAssistant.pkg em cache esta incompleto ($(du -h "$pkg_file" | cut -f1))"
            info "Baixando novamente..."
            rm -f "$pkg_file"
        fi
    fi

    # Download com retry automatico e retomada
    local max_retries=10
    local attempt=0
    local dl_ok=false

    while [ "$attempt" -lt "$max_retries" ]; do
        attempt=$((attempt + 1))
        if [ "$attempt" -gt 1 ]; then
            local partial; partial=$(du -h "$pkg_file" 2>/dev/null | cut -f1)
            warn "Conexao interrompida (tentativa $attempt/$max_retries). Retomando de ${partial:-0}..."
            sleep 2
        fi
        if curl -L -f --progress-bar -C - -o "$pkg_file" "$_APPLE_URL"; then
            dl_ok=true
            break
        fi
    done

    [ "$dl_ok" = true ] || error "Download falhou apos $max_retries tentativas. Verifique sua conexao."

    # Validar tamanho apos download
    local final_size; final_size=$(stat -c%s "$pkg_file" 2>/dev/null || echo 0)
    if [ "$final_size" -lt "$min_size" ] 2>/dev/null; then
        rm -f "$pkg_file"
        error "Download incompleto ($(du -h "$pkg_file" 2>/dev/null | cut -f1)). Tente novamente."
    fi

    info "  ✓ Download completo ($(du -h "$pkg_file" | cut -f1))"
    APPLE_PKG="$pkg_file"

    # Baixar BaseSystem.dmg separadamente (necessario para instalacao offline no Linux)
    if [ -n "$_APPLE_BASEDMG_URL" ]; then
        local base_file="$WORK_DIR/BaseSystem.dmg"
        if [ -f "$base_file" ] && [ "$(stat -c%s "$base_file" 2>/dev/null || echo 0)" -gt 1048576 ]; then
            info "BaseSystem.dmg encontrado em cache ($(du -h "$base_file" | cut -f1))"
        else
            info "Baixando BaseSystem.dmg (~500 MB)..."
            curl -L -f --progress-bar -C - -o "$base_file" "$_APPLE_BASEDMG_URL" \
                || warn "Falha ao baixar BaseSystem.dmg; sera extraido do pkg"
        fi
        [ -f "$base_file" ] && INSTALLER_BASE_DMG="$base_file"
    fi
}

apple_extract_shared_support() {
    local pkg_file="$1"

    [ -f "$pkg_file" ] || error "InstallAssistant.pkg nao encontrado"

    step "Extraindo instalador"

    info "Extraindo SharedSupport.dmg do pkg..."
    mkdir -p "$WORK_DIR/pkg_ex"
    rm -rf "$WORK_DIR/pkg_ex/"*

    bsdtar -xf "$pkg_file" -C "$WORK_DIR/pkg_ex" 2>/dev/null || true

    INSTALLER_SHARED_DMG=$(find "$WORK_DIR/pkg_ex" -name "SharedSupport.dmg" -type f | head -1)

    [ -z "$INSTALLER_SHARED_DMG" ] && error "Nao foi possivel extrair SharedSupport.dmg"
    info "  ✓ SharedSupport.dmg extraido ($(du -h "$INSTALLER_SHARED_DMG" | cut -f1))"

    # Tambem procurar BaseSystem.dmg na extracao do pkg (se nao foi baixado separadamente)
    if [ -z "$INSTALLER_BASE_DMG" ]; then
        local found_base
        found_base=$(find "$WORK_DIR/pkg_ex" -name "BaseSystem.dmg" -type f 2>/dev/null | head -1)
        if [ -n "$found_base" ]; then
            INSTALLER_BASE_DMG="$found_base"
            info "  ✓ BaseSystem.dmg encontrado no pkg ($(du -h "$found_base" | cut -f1))"
        fi
    fi
}

apple_download_and_extract() {
    local macos_name="$1"
    apple_download_installer "$macos_name"
    apple_extract_shared_support "$APPLE_PKG"
}

# Extrai BaseSystem.dmg de dentro do SharedSupport.dmg e grava no pendrive
# junto com SharedSupport.dmg para instalacao offline
write_installer_to_partition() {
    local partition="$1"
    local shared_dmg="$2"
    local base_dmg="${3:-$INSTALLER_BASE_DMG}"

    # Se ja temos BaseSystem.dmg (baixado separadamente ou extraido do pkg), usar direto
    if [ -n "$base_dmg" ] && [ -f "$base_dmg" ]; then
        info "Usando BaseSystem.dmg pre-existente ($(du -h "$base_dmg" | cut -f1))"
    else
        # Tentar extrair BaseSystem.dmg de SharedSupport.dmg (fallback)
        info "Extraindo BaseSystem.dmg de SharedSupport.dmg..."
        local ss_dir="$WORK_DIR/ss_extract"
        local inner_dir="$WORK_DIR/ss_inner"
        base_dmg=""

        # === Metodo 1: bsdtar direto ===
        mkdir -p "$ss_dir"
        bsdtar -xf "$shared_dmg" -C "$ss_dir" 2>/dev/null || true
        base_dmg=$(find "$ss_dir" -name "BaseSystem.dmg" -type f 2>/dev/null | head -1)

        # === Metodo 2: bsdtar recursivo nas particoes internas ===
        if [ -z "$base_dmg" ]; then
            info "Extraindo particoes internas do DMG..."
            mkdir -p "$inner_dir"
            for img in "$ss_dir"/*; do
                [ -f "$img" ] || continue
                local fsize; fsize=$(stat -c%s "$img" 2>/dev/null || echo 0)
                [ "$fsize" -lt 1048576 ] && continue
                local bname; bname=$(basename "$img")
                info "  Extraindo particao: $bname ($(du -h "$img" | cut -f1))..."
                bsdtar -xf "$img" -C "$inner_dir/$bname.d" 2>/dev/null || mkdir -p "$inner_dir/$bname.d"
            done
            base_dmg=$(find "$inner_dir" -name "BaseSystem.dmg" -type f 2>/dev/null | head -1)
        fi

        # === Metodo 3: dmg2img + loop mount ===
        if [ -z "$base_dmg" ]; then
            info "bsdtar nao conseguiu extrair; tentando dmg2img + mount..."
            local raw_ss="$WORK_DIR/shared_raw.img"
            local ss_mnt="$WORK_DIR/ss_mnt"
            mkdir -p "$ss_mnt"

            if dmg2img "$shared_dmg" "$raw_ss" > /dev/null 2>&1 && [ -f "$raw_ss" ]; then
                if mount -o loop,ro -t hfsplus "$raw_ss" "$ss_mnt" 2>/dev/null; then
                    base_dmg=$(find "$ss_mnt" -name "BaseSystem.dmg" -type f 2>/dev/null | head -1)
                    if [ -n "$base_dmg" ]; then
                        cp "$base_dmg" "$WORK_DIR/BaseSystem.dmg"
                        base_dmg="$WORK_DIR/BaseSystem.dmg"
                    fi
                    umount "$ss_mnt" 2>/dev/null || true
                fi

                if [ -z "$base_dmg" ] && command -v apfs-fuse &>/dev/null; then
                    info "Tentando montar APFS com apfs-fuse..."
                    local apfs_offset
                    apfs_offset=$(python3 -c "
import subprocess, re
out = subprocess.check_output(['fdisk', '-l', '$raw_ss'], text=True, stderr=subprocess.DEVNULL)
for line in out.splitlines():
    if 'Apple APFS' in line:
        parts = line.split()
        print(int(parts[1]) * 512)
        break
" 2>/dev/null || echo "")
                    if [ -n "$apfs_offset" ]; then
                        local loop_dev
                        loop_dev=$(losetup --find --show --offset "$apfs_offset" "$raw_ss" 2>/dev/null || echo "")
                        if [ -n "$loop_dev" ]; then
                            apfs-fuse -o allow_other "$loop_dev" "$ss_mnt" 2>/dev/null || true
                            base_dmg=$(find "$ss_mnt" -name "BaseSystem.dmg" -type f 2>/dev/null | head -1)
                            if [ -n "$base_dmg" ]; then
                                cp "$base_dmg" "$WORK_DIR/BaseSystem.dmg"
                                base_dmg="$WORK_DIR/BaseSystem.dmg"
                            fi
                            umount "$ss_mnt" 2>/dev/null || fusermount -u "$ss_mnt" 2>/dev/null || true
                            losetup -d "$loop_dev" 2>/dev/null || true
                        fi
                    fi
                fi
                rm -f "$raw_ss"
            fi
        fi

        if [ -z "$base_dmg" ]; then
            warn "Conteudo extraido do SharedSupport.dmg:"
            find "$ss_dir" "$inner_dir" -type f 2>/dev/null | head -30 | while read -r f; do
                echo "    $(du -h "$f" | cut -f1)  $f"
            done
            error "BaseSystem.dmg nao encontrado. Tente baixar novamente (opcao 1) para que o BaseSystem.dmg seja baixado separadamente da Apple."
        fi
    fi
    info "  ✓ BaseSystem.dmg ($(du -h "$base_dmg" | cut -f1))"

    # Converter BaseSystem.dmg para raw HFS (formato antigo, dmg2img suporta)
    info "Convertendo BaseSystem.dmg..."
    dmg2img "$base_dmg" "$WORK_DIR/base.raw" 2>&1 || error "Falha ao converter BaseSystem.dmg"
    info "  ✓ BaseSystem convertido ($(du -h "$WORK_DIR/base.raw" | cut -f1))"

    # Formatar particao destino como HFS+
    info "Formatando particao como HFS+..."
    mkfs.hfsplus -v "macOS Base System" "$partition" 2>&1 || error "Falha ao formatar HFS+"

    # Montar particao destino
    local inst_mnt="$WORK_DIR/installer_mnt"
    mkdir -p "$inst_mnt"
    modprobe hfsplus 2>/dev/null || true
    mount -t hfsplus -o force,rw "$partition" "$inst_mnt" \
        || error "Falha ao montar particao HFS+. Verifique se o modulo hfsplus esta disponivel."

    # Montar BaseSystem raw e copiar conteudo
    # O base.raw tem multiplas particoes — precisamos encontrar a HFS+
    local base_mnt="$WORK_DIR/base_mnt"
    mkdir -p "$base_mnt"
    local base_copied=false

    # Metodo 1: montar direto (funciona se dmg2img gerou imagem simples)
    if mount -o loop,ro -t hfsplus "$WORK_DIR/base.raw" "$base_mnt" 2>/dev/null; then
        info "Copiando sistema base..."
        cp -a "$base_mnt/." "$inst_mnt/" 2>/dev/null || true
        umount "$base_mnt"
        base_copied=true
    fi

    # Metodo 2: usar losetup com scan de particoes para encontrar a HFS+
    if [ "$base_copied" = false ]; then
        info "Imagem tem multiplas particoes, procurando HFS+..."
        local loop_dev
        loop_dev=$(losetup --find --show --partscan "$WORK_DIR/base.raw" 2>/dev/null || echo "")
        if [ -n "$loop_dev" ]; then
            # Listar particoes do loop
            local parts
            parts=$(lsblk -rno NAME,FSTYPE "$loop_dev" 2>/dev/null | grep -i "hfsplus" | head -1 | awk '{print $1}')
            if [ -n "$parts" ]; then
                info "Particao HFS+ encontrada: /dev/$parts"
                if mount -o ro -t hfsplus "/dev/$parts" "$base_mnt" 2>/dev/null; then
                    info "Copiando sistema base..."
                    cp -a "$base_mnt/." "$inst_mnt/" 2>/dev/null || true
                    umount "$base_mnt"
                    base_copied=true
                fi
            fi

            # Se nao achou por fstype, tentar cada particao
            if [ "$base_copied" = false ]; then
                for p in "${loop_dev}p"*; do
                    [ -b "$p" ] || continue
                    if mount -o ro -t hfsplus "$p" "$base_mnt" 2>/dev/null; then
                        # Verificar se tem conteudo de macOS
                        if [ -d "$base_mnt/System" ] || [ -d "$base_mnt/usr" ] || ls "$base_mnt"/*.app 2>/dev/null | grep -q .; then
                            info "Particao macOS encontrada: $p"
                            info "Copiando sistema base..."
                            cp -a "$base_mnt/." "$inst_mnt/" 2>/dev/null || true
                            umount "$base_mnt"
                            base_copied=true
                            break
                        fi
                        umount "$base_mnt" 2>/dev/null || true
                    fi
                done
            fi

            losetup -d "$loop_dev" 2>/dev/null || true
        fi
    fi

    # Metodo 3: dmg2img por particao individual
    if [ "$base_copied" = false ]; then
        info "Tentando extrair particoes individuais com dmg2img..."
        local nparts
        nparts=$(dmg2img -l "$base_dmg" 2>/dev/null | grep -c "partition" || echo "0")
        for pnum in $(seq 0 "$((nparts > 0 ? nparts - 1 : 7))"); do
            local praw="$WORK_DIR/base_p${pnum}.raw"
            dmg2img -p "$pnum" "$base_dmg" "$praw" > /dev/null 2>&1 || continue
            [ -f "$praw" ] || continue
            local psize; psize=$(stat -c%s "$praw" 2>/dev/null || echo 0)
            [ "$psize" -lt 1048576 ] && { rm -f "$praw"; continue; }

            if mount -o loop,ro -t hfsplus "$praw" "$base_mnt" 2>/dev/null; then
                if [ -d "$base_mnt/System" ] || [ -d "$base_mnt/usr" ] || ls "$base_mnt"/*.app 2>/dev/null | grep -q .; then
                    info "Particao $pnum tem conteudo macOS"
                    info "Copiando sistema base..."
                    cp -a "$base_mnt/." "$inst_mnt/" 2>/dev/null || true
                    umount "$base_mnt"
                    rm -f "$praw"
                    base_copied=true
                    break
                fi
                umount "$base_mnt" 2>/dev/null || true
            fi
            rm -f "$praw"
        done
    fi

    if [ "$base_copied" = false ]; then
        umount "$inst_mnt" 2>/dev/null || true
        error "Nao foi possivel montar BaseSystem.dmg. Tente com outro metodo."
    fi

    # Extrair Payload do .pkg para obter Install macOS app bundle
    # macOS precisa do app bundle para reconhecer como instalador offline
    local payload_file=""
    local app_name=""

    # Procurar Payload em locais comuns
    for loc in /tmp "$WORK_DIR/pkg_ex" "$WORK_DIR"; do
        [ -f "$loc/Payload" ] && { payload_file="$loc/Payload"; break; }
    done

    # Se nao encontrou, tentar extrair do .pkg
    if [ -z "$payload_file" ]; then
        local pkg_file=""
        for loc in "$(pwd)" "$WORK_DIR" /tmp "$HOME"; do
            [ -f "$loc/InstallAssistant.pkg" ] && { pkg_file="$loc/InstallAssistant.pkg"; break; }
        done
        if [ -n "$pkg_file" ]; then
            info "Extraindo Payload do .pkg..."
            bsdtar -xf "$pkg_file" -C "$WORK_DIR" Payload 2>/dev/null || true
            [ -f "$WORK_DIR/Payload" ] && payload_file="$WORK_DIR/Payload"
        fi
    fi

    if [ -n "$payload_file" ]; then
        info "Extraindo Install macOS app do Payload (pbzx)..."
        local payload_out="$WORK_DIR/payload_extracted"
        rm -rf "$payload_out"
        python3 "$SCRIPT_DIR/lib/pbzx_extract.py" "$payload_file" "$payload_out" 2>&1 || true

        # Encontrar o .app
        app_name=$(find "$payload_out" -maxdepth 3 -name "Install macOS*.app" -type d 2>/dev/null | head -1)
        if [ -n "$app_name" ]; then
            local app_basename; app_basename=$(basename "$app_name")
            info "Encontrado: $app_basename"

            # Copiar app bundle para o pendrive
            info "Copiando $app_basename para o pendrive..."
            cp -a "$app_name" "$inst_mnt/" 2>/dev/null || true

            # Criar SharedSupport dentro do app e copiar o SharedSupport.dmg
            local ss_dest="$inst_mnt/$app_basename/Contents/SharedSupport"
            mkdir -p "$ss_dest"
            info "Copiando SharedSupport.dmg para $app_basename/Contents/SharedSupport/ ($(du -h "$shared_dmg" | cut -f1), pode demorar)..."
            cp "$shared_dmg" "$ss_dest/SharedSupport.dmg" 2>&1 \
                || error "Falha ao copiar SharedSupport.dmg (espaco insuficiente no pendrive?)"

            # Criar marcador .IAPhysicalMedia (indica que e um media de instalacao)
            touch "$inst_mnt/.IAPhysicalMedia"
            info "  ✓ Marcador .IAPhysicalMedia criado"
        else
            warn "App bundle nao encontrado no Payload; copiando SharedSupport.dmg na raiz"
            info "Copiando SharedSupport.dmg para o pendrive... ($(du -h "$shared_dmg" | cut -f1), pode demorar)"
            cp "$shared_dmg" "$inst_mnt/SharedSupport.dmg" 2>&1 \
                || error "Falha ao copiar SharedSupport.dmg (espaco insuficiente no pendrive?)"
        fi

        rm -rf "$payload_out"
    else
        warn "Payload nao encontrado; copiando SharedSupport.dmg na raiz (pode precisar de internet)"
        info "Copiando SharedSupport.dmg para o pendrive... ($(du -h "$shared_dmg" | cut -f1), pode demorar)"
        cp "$shared_dmg" "$inst_mnt/SharedSupport.dmg" 2>&1 \
            || error "Falha ao copiar SharedSupport.dmg (espaco insuficiente no pendrive?)"
    fi

    sync
    umount "$inst_mnt"

    # Limpar temporarios
    rm -f "$WORK_DIR/base.raw"
    rm -rf "$ss_dir" "$WORK_DIR/ss_inner"

    info "  ✓ Instalador gravado no pendrive"
}
