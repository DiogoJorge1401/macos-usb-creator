#!/bin/bash
# Testes para lib/deps.sh e lib/common.sh
# Uso: bash tests/test_deps.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
PASSES=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        PASSES=$((PASSES + 1))
    else
        echo "  FAIL: $desc (expected='$expected', actual='$actual')"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "=== test_deps.sh ==="

# Test: common.sh carrega sem erro
echo "[test] common.sh carrega"
if source "$SCRIPT_DIR/lib/common.sh" 2>/dev/null; then
    echo "  PASS: common.sh carregado"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: common.sh falhou ao carregar"
    FAILURES=$((FAILURES + 1))
fi

# Test: funcoes de log definidas
echo "[test] funcoes de log existem"
for fn in info warn error step; do
    if declare -f "$fn" > /dev/null 2>&1; then
        echo "  PASS: $fn() definida"
        PASSES=$((PASSES + 1))
    else
        echo "  FAIL: $fn() nao definida"
        FAILURES=$((FAILURES + 1))
    fi
done

# Test: browse_files definida
echo "[test] browse_files() definida"
if declare -f browse_files > /dev/null 2>&1; then
    echo "  PASS: browse_files() definida"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: browse_files() nao definida"
    FAILURES=$((FAILURES + 1))
fi

# Test: deps.sh carrega
echo "[test] deps.sh carrega"
# Override error para nao dar exit
error() { echo "ERROR: $1" >&2; return 1; }
if source "$SCRIPT_DIR/lib/deps.sh" 2>/dev/null; then
    echo "  PASS: deps.sh carregado"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: deps.sh falhou ao carregar"
    FAILURES=$((FAILURES + 1))
fi

# Test: check_root falha sem root
echo "[test] check_root sem root"
if [ "$(id -u)" -ne 0 ]; then
    if check_root 2>/dev/null; then
        echo "  FAIL: check_root deveria falhar sem root"
        FAILURES=$((FAILURES + 1))
    else
        echo "  PASS: check_root falha sem root"
        PASSES=$((PASSES + 1))
    fi
else
    echo "  SKIP: rodando como root"
fi

# Test: dependencias essenciais estao instaladas
echo "[test] dependencias instaladas"
for cmd in python3 git bsdtar; do
    if command -v "$cmd" &>/dev/null; then
        echo "  PASS: $cmd instalado"
        PASSES=$((PASSES + 1))
    else
        echo "  FAIL: $cmd nao encontrado"
        FAILURES=$((FAILURES + 1))
    fi
done

# Test: todos os source files existem
echo "[test] arquivos source existem"
for f in lib/common.sh lib/deps.sh lib/local_file.sh lib/recovery.sh lib/usb.sh lib/gibmacos.sh lib/opencore/efi_builder.sh lib/opencore/installer.sh lib/opencore/config_gen.py; do
    if [ -f "$SCRIPT_DIR/$f" ]; then
        echo "  PASS: $f existe"
        PASSES=$((PASSES + 1))
    else
        echo "  FAIL: $f nao encontrado"
        FAILURES=$((FAILURES + 1))
    fi
done

# Test: macos-usb-creator.sh e executavel
echo "[test] macos-usb-creator.sh executavel"
if [ -x "$SCRIPT_DIR/macos-usb-creator.sh" ]; then
    echo "  PASS: script executavel"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: script nao executavel"
    FAILURES=$((FAILURES + 1))
fi

# Test: nenhum source file tem erros de sintaxe bash
echo "[test] sintaxe bash valida"
for f in lib/common.sh lib/deps.sh lib/local_file.sh lib/recovery.sh lib/usb.sh lib/gibmacos.sh lib/opencore/efi_builder.sh lib/opencore/installer.sh macos-usb-creator.sh; do
    if bash -n "$SCRIPT_DIR/$f" 2>/dev/null; then
        echo "  PASS: $f sintaxe OK"
        PASSES=$((PASSES + 1))
    else
        echo "  FAIL: $f erro de sintaxe"
        FAILURES=$((FAILURES + 1))
    fi
done

# Test: config_gen.py sintaxe Python valida
echo "[test] sintaxe Python valida"
if python3 -m py_compile "$SCRIPT_DIR/lib/opencore/config_gen.py" 2>/dev/null; then
    echo "  PASS: config_gen.py sintaxe OK"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: config_gen.py erro de sintaxe"
    FAILURES=$((FAILURES + 1))
fi

# ===== Resumo =====
echo ""
echo "Resultados: $PASSES passed, $FAILURES failed"
[ "$FAILURES" -eq 0 ] || exit 1
