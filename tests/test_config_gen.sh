#!/bin/bash
# Testes para lib/opencore/config_gen.py
# Uso: bash tests/test_config_gen.sh

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

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $desc"
        PASSES=$((PASSES + 1))
    else
        echo "  FAIL: $desc (not found: '$needle')"
        FAILURES=$((FAILURES + 1))
    fi
}

# ===== Setup: criar estrutura fake de kexts =====
KEXTS_DIR="$TEST_TMPDIR/Kexts"
mkdir -p "$KEXTS_DIR"

# Criar kexts fake com estrutura minima
for kext in Lilu VirtualSMC WhateverGreen AppleALC AirportBrcmFixup BlueToolFixup BrcmFirmwareData BrcmPatchRAM3 RestrictEvents CryptexFixup; do
    mkdir -p "$KEXTS_DIR/$kext.kext/Contents/MacOS"
    touch "$KEXTS_DIR/$kext.kext/Contents/MacOS/$kext"
    cat > "$KEXTS_DIR/$kext.kext/Contents/Info.plist" <<PLIST
<?xml version="1.0"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.test.$kext</string></dict></plist>
PLIST
done

echo "=== test_config_gen.sh ==="

# Test: gera config.plist valido para MacBookPro11,5
echo "[test] config_gen.py MacBookPro11,5"
OUT="$TEST_TMPDIR/config.plist"
python3 "$SCRIPT_DIR/lib/opencore/config_gen.py" "MacBookPro11,5" "$KEXTS_DIR" "$OUT" > /dev/null 2>&1
if [ -f "$OUT" ]; then
    echo "  PASS: config.plist criado"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: config.plist nao criado"
    FAILURES=$((FAILURES + 1))
fi

# Test: config.plist e XML plist valido
echo "[test] config.plist e XML valido"
content=$(cat "$OUT")
assert_contains "header XML plist" '<?xml version' "$content"
assert_contains "plist tag" '<plist version' "$content"

# Test: modelo correto no plist
echo "[test] modelo SMBIOS no plist"
assert_contains "SystemProductName" "MacBookPro11,5" "$content"

# Test: kexts estao listados
echo "[test] kexts listados"
assert_contains "Lilu.kext" "Lilu.kext" "$content"
assert_contains "VirtualSMC.kext" "VirtualSMC.kext" "$content"
assert_contains "AirportBrcmFixup.kext" "AirportBrcmFixup.kext" "$content"
assert_contains "CryptexFixup.kext" "CryptexFixup.kext" "$content"

# Test: drivers listados
echo "[test] drivers listados"
assert_contains "HfsPlus.efi" "HfsPlus.efi" "$content"
assert_contains "OpenRuntime.efi" "OpenRuntime.efi" "$content"

# Test: quirks criticos
echo "[test] quirks criticos"
assert_contains "AvoidRuntimeDefrag" "AvoidRuntimeDefrag" "$content"
assert_contains "DisableIoMapper" "DisableIoMapper" "$content"
assert_contains "SecureBootModel Disabled" "Disabled" "$content"
assert_contains "ScanPolicy" "ScanPolicy" "$content"

# Test: BlueToolFixup tem MinKernel 21.0.0
echo "[test] BlueToolFixup MinKernel"
assert_contains "MinKernel 21.0.0" "21.0.0" "$content"

# Test: CryptexFixup tem MinKernel 23.0.0
echo "[test] CryptexFixup MinKernel"
assert_contains "MinKernel 23.0.0" "23.0.0" "$content"

# Test: gera para modelo diferente
echo "[test] config_gen.py MacBookPro12,1"
OUT2="$TEST_TMPDIR/config2.plist"
python3 "$SCRIPT_DIR/lib/opencore/config_gen.py" "MacBookPro12,1" "$KEXTS_DIR" "$OUT2" > /dev/null 2>&1
content2=$(cat "$OUT2")
assert_contains "MacBookPro12,1 no plist" "MacBookPro12,1" "$content2"

# Test: gera com diretorio de kexts vazio (sem kexts)
echo "[test] config_gen.py sem kexts"
EMPTY_KEXTS="$TEST_TMPDIR/empty_kexts"
mkdir -p "$EMPTY_KEXTS"
OUT3="$TEST_TMPDIR/config3.plist"
python3 "$SCRIPT_DIR/lib/opencore/config_gen.py" "MacBookPro11,5" "$EMPTY_KEXTS" "$OUT3" > /dev/null 2>&1
if [ -f "$OUT3" ]; then
    echo "  PASS: config.plist gerado sem kexts"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: falhou sem kexts"
    FAILURES=$((FAILURES + 1))
fi

# Test: python3 plistlib consegue ler o plist gerado
echo "[test] plist parseavel por python"
if python3 -c "import plistlib; plistlib.load(open('$OUT', 'rb'))" 2>/dev/null; then
    echo "  PASS: plist parseavel"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: plist nao parseavel"
    FAILURES=$((FAILURES + 1))
fi

# Test: UUID e valido
echo "[test] SystemUUID formato valido"
uuid_val=$(python3 -c "
import plistlib
with open('$OUT', 'rb') as f:
    c = plistlib.load(f)
print(c['PlatformInfo']['Generic']['SystemUUID'])
" 2>/dev/null)
if echo "$uuid_val" | grep -qE '^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$'; then
    echo "  PASS: UUID valido ($uuid_val)"
    PASSES=$((PASSES + 1))
else
    echo "  FAIL: UUID invalido ($uuid_val)"
    FAILURES=$((FAILURES + 1))
fi

# ===== Resumo =====
echo ""
echo "Resultados: $PASSES passed, $FAILURES failed"
[ "$FAILURES" -eq 0 ] || exit 1
