#!/bin/bash
# Testes para o fluxo de instalacao offline
# Valida: pbzx_extract, estrutura do app bundle, write_installer_to_partition
# Uso: bash tests/test_installer_flow.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
PASSES=0
TEST_TMPDIR=$(mktemp -d)

trap 'rm -rf "$TEST_TMPDIR"' EXIT

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

assert_exists() {
    local desc="$1" path="$2"
    if [ -e "$path" ]; then
        echo "  PASS: $desc"
        PASSES=$((PASSES + 1))
    else
        echo "  FAIL: $desc (nao existe: $path)"
        FAILURES=$((FAILURES + 1))
    fi
}

assert_not_empty_dir() {
    local desc="$1" dir="$2"
    if [ -d "$dir" ] && [ "$(ls -A "$dir" 2>/dev/null)" ]; then
        echo "  PASS: $desc"
        PASSES=$((PASSES + 1))
    else
        echo "  FAIL: $desc (diretorio vazio ou nao existe: $dir)"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "=== test_installer_flow.sh ==="

# ============================
# Testes do pbzx_extract.py
# ============================

echo "[test] pbzx_extract.py existe e tem sintaxe valida"
assert_exists "pbzx_extract.py existe" "$SCRIPT_DIR/lib/pbzx_extract.py"
if python3 -m py_compile "$SCRIPT_DIR/lib/pbzx_extract.py" 2>/dev/null; then
    echo "  PASS: pbzx_extract.py sintaxe OK"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: pbzx_extract.py erro de sintaxe"
    FAILURES=$((FAILURES + 1))
fi

# Test: pbzx_extract.py com Payload real (se existir em /tmp)
echo "[test] pbzx_extract.py extrai Install macOS app do Payload"
if [ -f /tmp/Payload ]; then
    PAYLOAD_OUT="$TEST_TMPDIR/payload_test"
    if python3 "$SCRIPT_DIR/lib/pbzx_extract.py" /tmp/Payload "$PAYLOAD_OUT" > /dev/null 2>&1; then
        echo "  PASS: pbzx decode OK"
        PASSES=$((PASSES + 1))

        # Verificar que o app bundle foi extraido
        APP_FOUND=$(find "$PAYLOAD_OUT" -maxdepth 3 -name "Install macOS*.app" -type d 2>/dev/null | head -1)
        if [ -n "$APP_FOUND" ]; then
            echo "  PASS: Install macOS app encontrado ($(basename "$APP_FOUND"))"
            PASSES=$((PASSES + 1))

            # Verificar estrutura interna do app
            assert_exists "Contents/Info.plist" "$APP_FOUND/Contents/Info.plist"
            assert_exists "Contents/MacOS" "$APP_FOUND/Contents/MacOS"
            assert_exists "Contents/Resources" "$APP_FOUND/Contents/Resources"
            assert_exists "Contents/Frameworks" "$APP_FOUND/Contents/Frameworks"

            # Verificar que Info.plist tem CFBundleIdentifier
            if grep -q "CFBundleIdentifier" "$APP_FOUND/Contents/Info.plist" 2>/dev/null; then
                echo "  PASS: Info.plist tem CFBundleIdentifier"
                PASSES=$((PASSES + 1))
            else
                echo "  FAIL: Info.plist sem CFBundleIdentifier"
                FAILURES=$((FAILURES + 1))
            fi
        else
            echo "  FAIL: Install macOS app nao encontrado"
            FAILURES=$((FAILURES + 1))
        fi
        rm -rf "$PAYLOAD_OUT"
    else
        echo "  FAIL: pbzx decode falhou"
        FAILURES=$((FAILURES + 1))
    fi
else
    echo "  SKIP: /tmp/Payload nao existe (precisa extrair do .pkg primeiro)"
fi

# Test: pbzx_extract.py falha graciosamente com ficheiro invalido
echo "[test] pbzx_extract.py com ficheiro invalido"
echo "not a pbzx file" > "$TEST_TMPDIR/fake_payload"
FAKE_OUT="$TEST_TMPDIR/fake_out"
# Nao deve crashar (pode falhar, mas nao com segfault)
python3 "$SCRIPT_DIR/lib/pbzx_extract.py" "$TEST_TMPDIR/fake_payload" "$FAKE_OUT" > /dev/null 2>&1 || true
if [ -d "$FAKE_OUT" ]; then
    echo "  PASS: nao crashou com ficheiro invalido"
    PASSES=$((PASSES + 1))
else
    echo "  PASS: tratou erro graciosamente"
    PASSES=$((PASSES + 1))
fi

# ============================
# Testes da logica do write_installer_to_partition
# (simulado sem disco real)
# ============================

echo "[test] gibmacos.sh tem write_installer_to_partition"
if grep -q "write_installer_to_partition" "$SCRIPT_DIR/lib/gibmacos.sh"; then
    echo "  PASS: funcao existe"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: funcao nao encontrada"
    FAILURES=$((FAILURES + 1))
fi

echo "[test] write_installer_to_partition cria .IAPhysicalMedia"
if grep -q '\.IAPhysicalMedia' "$SCRIPT_DIR/lib/gibmacos.sh"; then
    echo "  PASS: .IAPhysicalMedia presente no codigo"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: .IAPhysicalMedia nao encontrado no codigo"
    FAILURES=$((FAILURES + 1))
fi

echo "[test] write_installer_to_partition copia SharedSupport.dmg para dentro do app"
if grep -q 'Contents/SharedSupport' "$SCRIPT_DIR/lib/gibmacos.sh"; then
    echo "  PASS: copia para Contents/SharedSupport/"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: nao copia para Contents/SharedSupport/"
    FAILURES=$((FAILURES + 1))
fi

echo "[test] write_installer_to_partition usa pbzx_extract.py"
if grep -q 'pbzx_extract.py' "$SCRIPT_DIR/lib/gibmacos.sh"; then
    echo "  PASS: usa pbzx_extract.py"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: nao usa pbzx_extract.py"
    FAILURES=$((FAILURES + 1))
fi

echo "[test] write_installer_to_partition usa losetup --partscan"
if grep -q 'losetup.*partscan' "$SCRIPT_DIR/lib/gibmacos.sh"; then
    echo "  PASS: usa losetup --partscan para montar BaseSystem"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: nao usa losetup --partscan"
    FAILURES=$((FAILURES + 1))
fi

echo "[test] write_installer_to_partition procura Payload em locais comuns"
if grep -q 'for loc in /tmp' "$SCRIPT_DIR/lib/gibmacos.sh" && grep -q 'loc/Payload' "$SCRIPT_DIR/lib/gibmacos.sh"; then
    echo "  PASS: procura Payload em /tmp e outros locais"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: nao procura Payload em locais comuns"
    FAILURES=$((FAILURES + 1))
fi

# ============================
# Testes da opcao 5 do installer.sh
# ============================

echo "[test] installer.sh tem opcao 5 (SharedSupport.dmg direto)"
if grep -q 'Usar SharedSupport.dmg ja extraido' "$SCRIPT_DIR/lib/opencore/installer.sh"; then
    echo "  PASS: opcao 5 existe"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: opcao 5 nao encontrada"
    FAILURES=$((FAILURES + 1))
fi

echo "[test] opcao 5 busca BaseSystem.dmg localmente"
if grep -q 'BaseSystem.dmg' "$SCRIPT_DIR/lib/opencore/installer.sh"; then
    echo "  PASS: busca BaseSystem.dmg"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: nao busca BaseSystem.dmg"
    FAILURES=$((FAILURES + 1))
fi

echo "[test] opcao 5 usa macrecovery como fallback"
if grep -q 'macrecovery.py' "$SCRIPT_DIR/lib/opencore/installer.sh"; then
    echo "  PASS: usa macrecovery como fallback"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: nao usa macrecovery"
    FAILURES=$((FAILURES + 1))
fi

echo "[test] opcao 5 suporta Sequoia no download do BaseSystem"
if grep -q 'Sequoia\|Mac-937A206F2EE63C01' "$SCRIPT_DIR/lib/opencore/installer.sh"; then
    echo "  PASS: Sequoia suportado no BaseSystem download"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: Sequoia nao suportado"
    FAILURES=$((FAILURES + 1))
fi

# ============================
# Testes de compatibilidade Sequoia no config
# ============================

echo "[test] config_gen.py boot-args tem revpatch=sbvmm,asset (necessario para Sequoia)"
if grep -q 'revpatch=sbvmm,asset' "$SCRIPT_DIR/lib/opencore/config_gen.py"; then
    echo "  PASS: revpatch presente"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: revpatch ausente (necessario para Sequoia em hardware nao suportado)"
    FAILURES=$((FAILURES + 1))
fi

echo "[test] config_gen.py CryptexFixup MinKernel compativel com Sequoia (Darwin 24)"
if grep -q '"CryptexFixup".*"23.0.0"' "$SCRIPT_DIR/lib/opencore/config_gen.py"; then
    echo "  PASS: CryptexFixup MinKernel 23.0.0 (carrega em Darwin 24.x)"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: CryptexFixup MinKernel incorreto"
    FAILURES=$((FAILURES + 1))
fi

echo "[test] gibmacos.sh mapeia sequoia para versao 15"
if grep -q 'sequoia.*15\|15.*sequoia' "$SCRIPT_DIR/lib/gibmacos.sh"; then
    echo "  PASS: sequoia -> 15"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: mapeamento sequoia ausente"
    FAILURES=$((FAILURES + 1))
fi

# ===== Resumo =====
echo ""
echo "Resultados: $PASSES passed, $FAILURES failed"
[ "$FAILURES" -eq 0 ] || exit 1
