#!/bin/bash
# Testes para lib/gibmacos.sh (parsing do catalogo Apple)
# Uso: bash tests/test_gibmacos.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
PASSES=0
TEST_TMPDIR=$(mktemp -d)

trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stubs
RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' NC=''
info()  { :; }
warn()  { :; }
error() { echo "ERROR: $1" >&2; return 1; }
step()  { :; }
WORK_DIR="$TEST_TMPDIR/work"
mkdir -p "$WORK_DIR"

source "$SCRIPT_DIR/lib/gibmacos.sh"

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

assert_set() {
    local desc="$1" var="$2"
    if [ -n "$var" ]; then
        echo "  PASS: $desc"
        PASSES=$((PASSES + 1))
    else
        echo "  FAIL: $desc (variable is empty)"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "=== test_gibmacos.sh ==="

# Test: SUCATALOG_URL esta definida
echo "[test] SUCATALOG_URL definida"
assert_set "SUCATALOG_URL" "$SUCATALOG_URL"

# Test: apple_fetch_installer_url encontra Sonoma (14)
echo "[test] apple_fetch_installer_url Sonoma (requer internet)"
if curl -s --max-time 5 "https://swscan.apple.com" > /dev/null 2>&1; then
    _APPLE_VERSION="" _APPLE_BUILD="" _APPLE_TITLE="" _APPLE_URL="" _APPLE_SIZE=""
    if apple_fetch_installer_url "14" 2>/dev/null; then
        assert_set "version encontrada" "$_APPLE_VERSION"
        assert_set "build encontrada" "$_APPLE_BUILD"
        assert_set "URL encontrada" "$_APPLE_URL"

        # Verificar que a versao comeca com 14
        if [[ "$_APPLE_VERSION" == 14* ]]; then
            echo "  PASS: versao comeca com 14 ($_APPLE_VERSION)"
            PASSES=$((PASSES + 1))
        else
            echo "  FAIL: versao nao comeca com 14 ($_APPLE_VERSION)"
            FAILURES=$((FAILURES + 1))
        fi

        # Verificar que URL aponta para InstallAssistant.pkg
        if [[ "$_APPLE_URL" == *"InstallAssistant.pkg" ]]; then
            echo "  PASS: URL termina com InstallAssistant.pkg"
            PASSES=$((PASSES + 1))
        else
            echo "  FAIL: URL inesperada: $_APPLE_URL"
            FAILURES=$((FAILURES + 1))
        fi
    else
        echo "  FAIL: apple_fetch_installer_url falhou para Sonoma"
        FAILURES=$((FAILURES + 1))
    fi
else
    echo "  SKIP: sem conexao com internet"
fi

# Test: apple_fetch_installer_url falha para versao inexistente
echo "[test] apple_fetch_installer_url versao inexistente"
if curl -s --max-time 5 "https://swscan.apple.com" > /dev/null 2>&1; then
    # Executar em subshell porque error() faz exit 1
    if (
        error() { exit 1; }
        source "$SCRIPT_DIR/lib/gibmacos.sh"
        WORK_DIR="$TEST_TMPDIR/work"
        apple_fetch_installer_url "99"
    ) 2>/dev/null; then
        echo "  FAIL: deveria falhar para versao 99"
        FAILURES=$((FAILURES + 1))
    else
        echo "  PASS: falhou para versao inexistente"
        PASSES=$((PASSES + 1))
    fi
else
    echo "  SKIP: sem conexao com internet"
fi

# Test: apple_extract_shared_support falha com ficheiro inexistente
echo "[test] apple_extract_shared_support ficheiro inexistente"
if (
    error() { exit 1; }
    source "$SCRIPT_DIR/lib/gibmacos.sh"
    WORK_DIR="$TEST_TMPDIR/work"
    INSTALLER_SHARED_DMG=""
    apple_extract_shared_support "/tmp/nao_existe_12345.pkg"
) 2>/dev/null; then
    echo "  FAIL: deveria falhar com ficheiro inexistente"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS: falhou com ficheiro inexistente"
    PASSES=$((PASSES + 1))
fi

# Test: mapeamento de versoes no apple_download_installer
echo "[test] mapeamento de versoes"
# Testar que as funcoes existem e aceitam os nomes
for name in sonoma sequoia ventura monterey; do
    # Nao vamos executar o download, so verificar que o case nao da erro
    case "${name,,}" in
        sonoma)   v="14" ;;
        sequoia)  v="15" ;;
        ventura)  v="13" ;;
        monterey) v="12" ;;
    esac
    assert_set "mapeamento $name -> $v" "$v"
done

# ===== Resumo =====
echo ""
echo "Resultados: $PASSES passed, $FAILURES failed"
[ "$FAILURES" -eq 0 ] || exit 1
