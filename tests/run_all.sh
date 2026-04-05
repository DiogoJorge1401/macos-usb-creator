#!/bin/bash
# Runner de todos os testes
# Uso: bash tests/run_all.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_FAIL=0

echo ""
echo "========================================"
echo "  macos-usb-creator — Test Suite"
echo "========================================"
echo ""

for test_file in "$SCRIPT_DIR"/test_*.sh; do
    echo "--- $(basename "$test_file") ---"
    if bash "$test_file"; then
        echo ""
    else
        echo "  ^^^ FALHAS ACIMA ^^^"
        echo ""
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
done

echo "========================================"
if [ "$TOTAL_FAIL" -eq 0 ]; then
    echo "  TODOS OS TESTES PASSARAM"
else
    echo "  $TOTAL_FAIL suite(s) com falhas"
fi
echo "========================================"

exit "$TOTAL_FAIL"
