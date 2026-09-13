#!/bin/bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"
cp "$repo/migrate-zimbra-carbonio.sh" "$work/"

cat > "$work/bin/id" <<'EOF'
#!/bin/bash
if [ "${1:-}" = '-u' ]; then echo 0; fi
exit 0
EOF
cat > "$work/bin/su" <<'EOF'
#!/bin/bash
set -eu
[[ "$1" = '-' && "$2" = zimbra && "$3" = '-c' ]]
case "$4" in
    'zmprov gad') echo example.com ;;
    'zmprov -l gaa')
        case "$SCENARIO" in
            failure) echo 'getAllAccounts can only be used with zmprov -l'; exit 1 ;;
            help) echo '  -a/--account {name} account name to auth as' ;;
            empty) ;;
            *) printf '%s\n' alice@example.com bob@example.com ;;
        esac ;;
    'zmprov gadl') ;;
    'zmprov ga '*)
        case "$4" in
            *' givenName') echo 'givenName: Test' ;;
            *' sn') echo 'sn: User' ;;
            *' displayName') echo 'displayName: Test User' ;;
        esac ;;
    *) echo "Unexpected command: $4" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/id" "$work/bin/su"
export PATH="$work/bin:$PATH"
export SCENARIO=success
bash "$work/migrate-zimbra-carbonio.sh" export > "$work/output" 2>&1
# Preserve the empty fifth field in the actual expected TSV.
printf 'alice@example.com\tTest\tUser\tTest User\t\nbob@example.com\tTest\tUser\tTest User\t\n' > "$work/expected"
cmp "$work/expected" "$work/migration-data/accounts.tsv"
for SCENARIO in failure help; do
    export SCENARIO
    if bash "$work/migrate-zimbra-carbonio.sh" export > "$work/output" 2>&1; then
        echo "ERROR: accepted $SCENARIO output" >&2
        exit 1
    fi
    cmp "$work/expected" "$work/migration-data/accounts.tsv"
done
export SCENARIO=empty
bash "$work/migrate-zimbra-carbonio.sh" export > "$work/output" 2>&1
test ! -s "$work/migration-data/accounts.tsv"
echo 'PASS: LDAP listing, TSV export, failed listing, help output, preservation and empty listing'
