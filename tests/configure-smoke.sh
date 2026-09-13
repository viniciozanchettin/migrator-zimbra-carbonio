#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"
export CONFIG_TEST_WORK="$work"
cat > "$work/bin/id" <<'EOF'
#!/bin/bash
echo 0
EOF
cat > "$work/bin/su" <<'EOF'
#!/bin/bash
carbonio() {
    echo "$*" >> "$CONFIG_TEST_WORK/calls"
    case "$2" in
        mc|mcf)
            [[ ${FAIL_WRITE:-0} != 1 ]] || return 1
            echo "${*: -1}" > "$CONFIG_TEST_WORK/${@: -2:1}" ;;
        gc) echo "zimbraFileUploadMaxSizePerFile: $(cat "$CONFIG_TEST_WORK/zimbraFileUploadMaxSizePerFile" 2>/dev/null || echo 100)" ;;
        gacf)
            for attr in "${@:3}"; do
                echo "$attr: $(cat "$CONFIG_TEST_WORK/$attr" 2>/dev/null || echo 100)"
            done ;;
        *) return 2 ;;
    esac
}
export -f carbonio
bash -c "$4"
EOF
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"
bash -n "$repo/configure-carbonio.sh"
bash -n "$repo/menu.sh"
printf '2\n0\n' | bash "$repo/configure-carbonio.sh" --dry-run > "$work/dry"
test ! -e "$work/calls"
grep -q 'mc default zimbraFileUploadMaxSizePerFile 20971520' "$work/dry"
grep -q 'mcf zimbraMtaMaxMessageSize 31457280' "$work/dry"
printf '2\nn\n0\n' | bash "$repo/configure-carbonio.sh" > "$work/cancel"
! grep -Eq '^prov (mc|mcf) ' "$work/calls"
printf '2\ns\n0\n' | bash "$repo/configure-carbonio.sh" > "$work/apply"
grep -q 'gravados e confirmados' "$work/apply"
test "$(cat "$work/zimbraFileUploadMaxSizePerFile")" = 20971520
test "$(cat "$work/zimbraFileUploadMaxSize")" = 31457280
test "$(cat "$work/zimbraMtaMaxMessageSize")" = 31457280
if printf '2\ns\n' | FAIL_WRITE=1 bash "$repo/configure-carbonio.sh" > "$work/fail" 2>&1; then
    echo 'Falha de escrita deveria retornar erro.' >&2; exit 1
fi
printf '3\nabc\n25\n40\n0\n' | bash "$repo/configure-carbonio.sh" --dry-run > "$work/custom"
grep -q '26214400' "$work/custom"
grep -q '41943040' "$work/custom"
printf '3\n40\n20\n0\n' | bash "$repo/configure-carbonio.sh" --dry-run > "$work/invalid"
! grep -q '^carbonio prov' "$work/invalid"
printf '9\n2\n0\n0\n' | bash "$repo/menu.sh" > "$work/menu"
grep -q '\[DRY-RUN\]' "$work/menu"
echo 'OK: configuração, simulação, cancelamento, validação, falha e menu.'
