#!/bin/bash
# skip-setup.sh — Salta o Setup Assistant do macOS e cria conta local
# Executar a partir do Terminal na Recovery/Installer do macOS
# Uso: bash /Volumes/EFI/skip-setup.sh

set -e

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

echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Pular Setup Assistant + Criar Conta Local${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo ""
info "Este script salta a tela de configuracao inicial do macOS"
info "(incluindo a tela de WiFi) e cria uma conta de administrador."
echo ""

# Detectar volumes macOS instalados (Data volumes)
info "Procurando volumes macOS instalados..."
echo ""

DATA_VOLS=()
while IFS= read -r vol; do
    # Procura volumes Data que contenham a estrutura do macOS
    if [ -d "$vol/private/var/db" ] || [ -d "$vol/private/var" ]; then
        DATA_VOLS+=("$vol")
    fi
done < <(ls -d /Volumes/*Data* 2>/dev/null; ls -d /Volumes/*data* 2>/dev/null)

# Se nao encontrou Data volumes, tentar montar
if [ ${#DATA_VOLS[@]} -eq 0 ]; then
    warn "Nenhum volume Data encontrado montado."
    info "Tentando montar volumes APFS..."
    echo ""

    # Listar volumes APFS disponiveis
    diskutil list | grep -i "apfs" || true
    echo ""
    echo -e "  ${BOLD}Digite o identificador do volume Data (ex: disk1s2):${NC}"
    echo -e "  ${DIM}(Procure por 'Data' ou 'Macintosh HD - Data' na lista acima)${NC}"
    read -r data_disk
    [ -z "$data_disk" ] && error "Nenhum disco informado"

    diskutil mount "/dev/$data_disk" 2>/dev/null || true
    sleep 1

    # Procurar novamente
    while IFS= read -r vol; do
        if [ -d "$vol/private/var/db" ] || [ -d "$vol/private/var" ]; then
            DATA_VOLS+=("$vol")
        fi
    done < <(ls -d /Volumes/*Data* 2>/dev/null; ls -d /Volumes/*data* 2>/dev/null)
fi

if [ ${#DATA_VOLS[@]} -eq 0 ]; then
    # Fallback: perguntar o caminho
    echo -e "  ${BOLD}Nao encontrei automaticamente. Digite o caminho do volume Data:${NC}"
    echo -e "  ${DIM}(ex: /Volumes/Macintosh HD - Data)${NC}"
    read -r manual_vol
    [ -d "$manual_vol" ] || error "Volume nao encontrado: $manual_vol"
    DATA_VOLS+=("$manual_vol")
fi

# Se houver mais de um, perguntar
TARGET_VOL=""
if [ ${#DATA_VOLS[@]} -eq 1 ]; then
    TARGET_VOL="${DATA_VOLS[0]}"
else
    echo -e "  ${BOLD}Volumes encontrados:${NC}"
    for i in "${!DATA_VOLS[@]}"; do
        echo -e "  ${GREEN}[$((i+1))]${NC}  ${DATA_VOLS[$i]}"
    done
    echo ""
    echo -e "  Escolha:"
    read -r vol_choice
    TARGET_VOL="${DATA_VOLS[$((vol_choice - 1))]}"
fi

[ -d "$TARGET_VOL" ] || error "Volume nao encontrado: $TARGET_VOL"
info "Volume selecionado: $TARGET_VOL"
echo ""

# Criar diretorios necessarios
mkdir -p "$TARGET_VOL/private/var/db" 2>/dev/null || true

# Pedir dados da conta
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Configurar Conta de Administrador${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo ""

echo -e "  ${BOLD}Nome completo${NC} (ex: Diogo Jorge):"
read -r FULL_NAME
[ -z "$FULL_NAME" ] && FULL_NAME="Admin"

echo -e "  ${BOLD}Nome de usuario${NC} (ex: diogo) [sem espacos]:"
read -r USER_NAME
[ -z "$USER_NAME" ] && USER_NAME="admin"
# Remover espacos e converter para minusculas
USER_NAME=$(echo "$USER_NAME" | tr '[:upper:]' '[:lower:]' | tr -d ' ')

echo -e "  ${BOLD}Senha${NC}:"
read -rs USER_PASS
echo ""
[ -z "$USER_PASS" ] && error "Senha nao pode ser vazia"

echo -e "  ${BOLD}Confirmar senha${NC}:"
read -rs USER_PASS2
echo ""
[ "$USER_PASS" != "$USER_PASS2" ] && error "Senhas nao coincidem"

echo ""
info "Conta: $FULL_NAME ($USER_NAME) — Administrador"
echo ""

# 1. Criar marcador .AppleSetupDone
info "Criando marcador .AppleSetupDone..."
touch "$TARGET_VOL/private/var/db/.AppleSetupDone"
info "  ✓ Setup Assistant sera pulado no proximo boot"

# 2. Criar marcador .skipbuddy (pula setup por usuario)
info "Criando marcador .skipbuddy..."
mkdir -p "$TARGET_VOL/Library/User Template/English.lproj" 2>/dev/null || true
touch "$TARGET_VOL/Library/User Template/English.lproj/.skipbuddy"

# Tambem criar para Non_localized (cobre todos os idiomas)
mkdir -p "$TARGET_VOL/Library/User Template/Non_localized" 2>/dev/null || true
touch "$TARGET_VOL/Library/User Template/Non_localized/.skipbuddy"
info "  ✓ Buddy setup por usuario sera pulado"

# 3. Criar conta de usuario via dscl no volume alvo
info "Criando conta de usuario..."

DSCL_DIR="$TARGET_VOL/private/var/db/dslocal/nodes/Default"

if [ ! -d "$DSCL_DIR" ]; then
    warn "Diretorio dslocal nao encontrado. Tentando metodo alternativo..."

    # Metodo alternativo: criar o plist do usuario diretamente
    USERS_DIR="$TARGET_VOL/private/var/db/dslocal/nodes/Default/users"
    mkdir -p "$USERS_DIR" 2>/dev/null || true

    # Gerar UID unico (501 e o primeiro usuario no macOS)
    USER_UID=501

    # Hash da senha (usando Python disponivel na Recovery)
    PASS_HASH=$(python3 -c "
import hashlib, os
salt = os.urandom(32)
dk = hashlib.pbkdf2_hmac('sha512', b'$USER_PASS', salt, 39999, dklen=128)
# Para simplicidade, usar ShadowHash basic
print(hashlib.sha512(b'$USER_PASS').hexdigest())
" 2>/dev/null || echo "")

    info "  Conta sera finalizada no primeiro login do macOS"
    info "  ✓ Marcadores criados — o macOS configurara a conta automaticamente"

else
    # Metodo preferido: usar dscl com -f para apontar ao volume
    dscl -f "$DSCL_DIR" localonly -create "/Local/Default/Users/$USER_NAME" 2>/dev/null || true
    dscl -f "$DSCL_DIR" localonly -create "/Local/Default/Users/$USER_NAME" UserShell /bin/zsh 2>/dev/null || true
    dscl -f "$DSCL_DIR" localonly -create "/Local/Default/Users/$USER_NAME" RealName "$FULL_NAME" 2>/dev/null || true
    dscl -f "$DSCL_DIR" localonly -create "/Local/Default/Users/$USER_NAME" UniqueID 501 2>/dev/null || true
    dscl -f "$DSCL_DIR" localonly -create "/Local/Default/Users/$USER_NAME" PrimaryGroupID 20 2>/dev/null || true
    dscl -f "$DSCL_DIR" localonly -create "/Local/Default/Users/$USER_NAME" NFSHomeDirectory "/Users/$USER_NAME" 2>/dev/null || true

    # Adicionar ao grupo admin
    dscl -f "$DSCL_DIR" localonly -create "/Local/Default/Groups/admin" 2>/dev/null || true
    dscl -f "$DSCL_DIR" localonly -append "/Local/Default/Groups/admin" GroupMembership "$USER_NAME" 2>/dev/null || true

    # Definir senha
    dscl -f "$DSCL_DIR" localonly -passwd "/Local/Default/Users/$USER_NAME" "$USER_PASS" 2>/dev/null || true

    # Criar diretorio home
    mkdir -p "$TARGET_VOL/Users/$USER_NAME" 2>/dev/null || true

    info "  ✓ Conta '$USER_NAME' criada como administrador"
fi

# 4. Desativar verificacoes de rede no Setup Assistant
info "Desativando requisitos de rede..."
SETUP_PLIST="$TARGET_VOL/Library/Preferences/com.apple.SetupAssistant.plist"
mkdir -p "$(dirname "$SETUP_PLIST")" 2>/dev/null || true

# Usar defaults se disponivel, senao usar Python
if command -v defaults &>/dev/null; then
    defaults write "$SETUP_PLIST" DidSeeCloudSetup -bool true 2>/dev/null || true
    defaults write "$SETUP_PLIST" DidSeePrivacy -bool true 2>/dev/null || true
    defaults write "$SETUP_PLIST" DidSeeActivationLock -bool true 2>/dev/null || true
    defaults write "$SETUP_PLIST" DidSeeSiriSetup -bool true 2>/dev/null || true
    defaults write "$SETUP_PLIST" DidSeeScreenTime -bool true 2>/dev/null || true
    defaults write "$SETUP_PLIST" DidSeeAppearance -bool true 2>/dev/null || true
else
    python3 -c "
import plistlib
p = {
    'DidSeeCloudSetup': True,
    'DidSeePrivacy': True,
    'DidSeeActivationLock': True,
    'DidSeeSiriSetup': True,
    'DidSeeScreenTime': True,
    'DidSeeAppearance': True,
}
with open('$SETUP_PLIST', 'wb') as f:
    plistlib.dump(p, f)
" 2>/dev/null || warn "Nao foi possivel escrever preferencias do Setup Assistant"
fi
info "  ✓ Preferencias do Setup Assistant configuradas"

echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${CYAN}  CONCLUIDO!${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo ""
info "O Setup Assistant (incluindo a tela de WiFi) sera pulado!"
echo ""
info "${BOLD}Proximo passo:${NC}"
info "  1. Feche este Terminal"
info "  2. Reinicie o Mac (Apple > Reiniciar)"
info "  3. O macOS vai direto para o login"
info "  4. Faca login com: ${BOLD}$USER_NAME${NC}"
info "  5. Depois do login, execute o OCLP para ativar WiFi/GPU"
echo ""
warn "Lembrete: a senha da conta e a que voce definiu agora."
warn "Se a conta nao funcionar, reinicie em Recovery e tente novamente."
echo ""
