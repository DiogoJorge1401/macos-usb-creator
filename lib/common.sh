#!/bin/bash

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
step()  { echo -e "\n${CYAN}══════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════════════${NC}\n"; }

browse_files() {
    local dir="${1:-.}"
    local extensions=("pkg" "dmg" "iso" "img")
    local pattern

    # Construir pattern de extensoes
    pattern=$(printf "|%s" "${extensions[@]}")
    pattern="${pattern:1}" # remover primeiro |

    while true; do
        dir="$(realpath "$dir")"

        echo ""
        echo -e "  ${BOLD}Diretorio: ${CYAN}$dir${NC}"
        echo -e "  ${DIM}Filtro: *.{${pattern}}${NC}"
        echo ""

        local items=()
        local index=0

        # Adicionar ".." para voltar
        if [ "$dir" != "/" ]; then
            index=$((index + 1))
            items+=("..")
            echo -e "  ${DIM}[$index]${NC}  ${YELLOW}../${NC}  (voltar)"
        fi

        # Listar subdiretorios
        while IFS= read -r -d '' entry; do
            index=$((index + 1))
            items+=("$entry")
            local name; name=$(basename "$entry")
            echo -e "  ${DIM}[$index]${NC}  ${YELLOW}${name}/${NC}"
        done < <(find "$dir" -maxdepth 1 -mindepth 1 -type d ! -name '.*' -print0 2>/dev/null | sort -z)

        # Listar arquivos filtrados
        while IFS= read -r -d '' entry; do
            index=$((index + 1))
            items+=("$entry")
            local name; name=$(basename "$entry")
            local size; size=$(du -h "$entry" 2>/dev/null | cut -f1)
            echo -e "  ${GREEN}[$index]${NC}  ${BOLD}${name}${NC}  ${DIM}(${size})${NC}"
        done < <(find "$dir" -maxdepth 1 -mindepth 1 -type f \( -iname "*.pkg" -o -iname "*.dmg" -o -iname "*.iso" -o -iname "*.img" \) -print0 2>/dev/null | sort -z)

        if [ $index -eq 0 ] || { [ $index -eq 1 ] && [ "${items[0]}" = ".." ]; }; then
            warn "Nenhum arquivo .pkg/.dmg/.iso/.img encontrado aqui."
        fi

        echo ""
        echo -e "  Digite o numero, ou ${RED}0${NC} para cancelar:"
        read -r nav_choice

        [ "$nav_choice" = "0" ] && return 1

        if ! [[ "$nav_choice" =~ ^[0-9]+$ ]] || [ "$nav_choice" -gt ${#items[@]} ] || [ "$nav_choice" -lt 1 ]; then
            warn "Opcao invalida"
            continue
        fi

        local selected="${items[$((nav_choice - 1))]}"

        if [ "$selected" = ".." ]; then
            dir="$(dirname "$dir")"
            continue
        fi

        if [ -d "$selected" ]; then
            dir="$selected"
            continue
        fi

        # Arquivo selecionado
        SELECTED_FILE="$selected"
        return 0
    done
}
