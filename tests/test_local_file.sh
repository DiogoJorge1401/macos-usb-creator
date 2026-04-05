#!/bin/bash
# Testes para lib/local_file.sh
# Uso: bash tests/test_local_file.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
PASSES=0
TEST_TMPDIR=$(mktemp -d)

trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stubs minimos
RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' NC=''
info()  { :; }
warn()  { :; }
error() { echo "ERROR: $1" >&2; return 1; }
step()  { :; }
WORK_DIR="$TEST_TMPDIR/work"
mkdir -p "$WORK_DIR"

source "$SCRIPT_DIR/lib/local_file.sh"

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

# ===== Testes =====

echo "=== test_local_file.sh ==="

# Test: process_local_file com .dmg seta DMG_FILE
echo "[test] process_local_file .dmg"
DMG_FILE="" IMG_FILE=""
touch "$TEST_TMPDIR/test.dmg"
process_local_file "$TEST_TMPDIR/test.dmg"
assert_eq "DMG_FILE setado para .dmg" "$TEST_TMPDIR/test.dmg" "$DMG_FILE"
assert_eq "IMG_FILE vazio para .dmg" "" "$IMG_FILE"

# Test: process_local_file com .img seta IMG_FILE
echo "[test] process_local_file .img"
DMG_FILE="" IMG_FILE=""
touch "$TEST_TMPDIR/test.img"
process_local_file "$TEST_TMPDIR/test.img"
assert_eq "IMG_FILE setado para .img" "$TEST_TMPDIR/test.img" "$IMG_FILE"
assert_eq "DMG_FILE vazio para .img" "" "$DMG_FILE"

# Test: process_local_file com .iso seta IMG_FILE
echo "[test] process_local_file .iso"
DMG_FILE="" IMG_FILE=""
touch "$TEST_TMPDIR/test.iso"
process_local_file "$TEST_TMPDIR/test.iso"
assert_eq "IMG_FILE setado para .iso" "$TEST_TMPDIR/test.iso" "$IMG_FILE"

# Test: process_local_file com extensao maiuscula
echo "[test] process_local_file .DMG (case insensitive)"
DMG_FILE="" IMG_FILE=""
touch "$TEST_TMPDIR/test.DMG"
process_local_file "$TEST_TMPDIR/test.DMG"
assert_eq "DMG_FILE setado para .DMG" "$TEST_TMPDIR/test.DMG" "$DMG_FILE"

# Test: process_local_file com extensao desconhecida retorna erro
echo "[test] process_local_file extensao desconhecida"
DMG_FILE="" IMG_FILE=""
touch "$TEST_TMPDIR/test.txt"
if process_local_file "$TEST_TMPDIR/test.txt" 2>/dev/null; then
    echo "  FAIL: deveria dar erro para .txt"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS: erro retornado para .txt"
    PASSES=$((PASSES + 1))
fi

# Test: prepare_image com IMG_FILE definido usa direto
echo "[test] prepare_image com IMG_FILE"
IMG_FILE="$TEST_TMPDIR/test.img"
DMG_FILE=""
FLASH_IMAGE=""
prepare_image
assert_eq "FLASH_IMAGE igual a IMG_FILE" "$TEST_TMPDIR/test.img" "$FLASH_IMAGE"

# Test: prepare_image sem DMG nem IMG falha
echo "[test] prepare_image sem nada"
# Executar em subshell porque error() faz exit 1
if (
    error() { exit 1; }
    IMG_FILE="" DMG_FILE="" FLASH_IMAGE=""
    source "$SCRIPT_DIR/lib/local_file.sh"
    prepare_image
) 2>/dev/null; then
    echo "  FAIL: deveria dar erro sem DMG_FILE"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS: erro retornado sem DMG_FILE"
    PASSES=$((PASSES + 1))
fi

# ===== Resumo =====
echo ""
echo "Resultados: $PASSES passed, $FAILURES failed"
[ "$FAILURES" -eq 0 ] || exit 1
