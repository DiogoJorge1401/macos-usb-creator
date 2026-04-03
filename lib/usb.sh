#!/bin/bash

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
