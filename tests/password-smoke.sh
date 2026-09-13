#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/migration-data"
cp "$repo/migrate-zimbra-carbonio.sh" "$work/"
export TEST_WORK="$work"

cat > "$work/bin/id" <<'EOF'
#!/bin/bash
if [ "${1:-}" = '-u' ]; then echo 0; fi
exit 0
EOF
cat > "$work/bin/su" <<'EOF'
#!/bin/bash
set -eu
[[ "$1" = '-' && "$2" = zextras && "$3" = '-c' ]]
carbonio()
{
    [[ "$1" = prov ]]
    case "$2" in
        ga) [[ "$3" != missing@example.com ]] ;;
        sp)
            # Each generated password must be on disk BEFORE its application.
            grep -F -- "\"$3\";\"$4\";\"PENDENTE\"" "$TEST_WORK"/migration-data/senhas-*.csv >/dev/null || return 88
            printf '%s\t%s\n' "$3" "$4" >> "$TEST_WORK/calls.tsv"
            # Simulate a provider that echoes secrets, including on failure.
            printf 'provider output: %s\n' "$4"
            printf 'provider error: %s\n' "$4" >&2
            [[ "$3" != rejected@example.com ]] ;;
        *) return 89 ;;
    esac
}
export -f carbonio
bash -c "$4"
EOF
chmod +x "$work/bin/id" "$work/bin/su"
export PATH="$work/bin:$PATH"

fixture()
{
    printf 'alice@example.com\tAlice\t\t\t\nrejected@example.com\t\t\t\t\nmissing@example.com\t\t\t\t\nalice@example.com\tAlice\t\t\t\n' > "$work/migration-data/accounts.tsv"
}
fixture
cp "$work/migration-data/accounts.tsv" "$work/accounts-original.tsv"

if bash "$work/migrate-zimbra-carbonio.sh" reset-passwords --dry-run > "$work/dry-output" 2>&1; then
    echo 'ERROR: missing account must make dry-run fail' >&2; exit 1
fi
test ! -e "$work/calls.tsv"
test "$(find "$work/migration-data" -name 'senhas-*.csv' | wc -l)" -eq 0

if bash -x "$work/migrate-zimbra-carbonio.sh" reset-passwords > "$work/output" 2>&1; then
    echo 'ERROR: partial failure must return nonzero' >&2; exit 1
fi
csv=("$work"/migration-data/senhas-*.csv)
test "${#csv[@]}" -eq 1
test "$(wc -l < "${csv[0]}")" -eq 4
test "$(wc -l < "$work/calls.tsv")" -eq 2
grep -q ';"ALTERADA"' "${csv[0]}"
grep -q ';"FALHA_ALTERACAO"' "${csv[0]}"
grep -q ';"FALHA_CONSULTA"' "${csv[0]}"
cmp "$work/accounts-original.tsv" "$work/migration-data/accounts.tsv"

while IFS=$'\t' read -r account password; do
    test "${#password}" -eq 9
    [[ "$password" =~ ^[a-zA-Z][a-zA-Z0-9!@#%*_-]*$ ]]
    [[ "$password" =~ [A-Z] && "$password" =~ [a-z] && "$password" =~ [0-9] && "$password" =~ [!@#%*_-] ]]
    grep -F -- "\"$account\";\"$password\";" "${csv[0]}" >/dev/null
    if grep -F -- "$password" "$work/output" "$work"/migration-data/logs/* >/dev/null; then
        echo 'ERROR: password leaked into terminal or log' >&2; exit 1
    fi
done < "$work/calls.tsv"
cp "${csv[0]}" "$work/first.csv"

# A second successful execution creates another CSV and preserves the first.
printf 'alice@example.com\t\t\t\t\n' > "$work/migration-data/accounts.tsv"
bash "$work/migrate-zimbra-carbonio.sh" reset-passwords > "$work/second-output" 2>&1
cmp "$work/first.csv" "${csv[0]}"
test "$(find "$work/migration-data" -name 'senhas-*.csv' | wc -l)" -eq 2
bash "$work/migrate-zimbra-carbonio.sh" reset-passwords --dry-run > "$work/dry-success" 2>&1
test "$(wc -l < "$work/calls.tsv")" -eq 3

# Invalid input and unknown flags must never cause password changes.
printf 'invalid help output\n' > "$work/migration-data/accounts.tsv"
if bash "$work/migrate-zimbra-carbonio.sh" reset-passwords > "$work/invalid-output" 2>&1; then exit 1; fi
fixture
if bash "$work/migrate-zimbra-carbonio.sh" reset-passwords --dryrun > "$work/invalid-flag" 2>&1; then exit 1; fi
test "$(wc -l < "$work/calls.tsv")" -eq 3
test "$(find "$work/migration-data" -name 'senhas-*.csv' | wc -l)" -eq 2
echo 'PASS: password rules, scope, deduplication, CSV persistence, failures, dry-run and no secret logging'
