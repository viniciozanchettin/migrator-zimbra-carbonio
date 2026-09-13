#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/migration-data" "$work/secrets"
cp "$repo/migrate-zimbra-carbonio.sh" "$work/"
export TEST_WORK="$work" TMPDIR="$work/secrets" SCENARIO=ok
printf 'alice@example.com\t\t\t\t\nbob@example.com\t\t\t\t\nalice@example.com\t\t\t\t\n' > "$work/migration-data/accounts.tsv"
cp "$work/migration-data/accounts.tsv" "$work/original.tsv"
printf '%s\n' 'Source! secret $with "quotes"' > "$work/pass1"
printf '%s\n' 'Destination# secret % spaces' > "$work/pass2"
printf 'fixture CA\n' > "$work/ca.pem"
cat > "$work/bin/flock" <<'EOF'
#!/bin/bash
# Windows Git Bash lacks flock; exercise caller handling with this test double.
[[ "$SCENARIO" != locked ]]
EOF
cat > "$work/bin/imapsync" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = --version ]; then
    [[ "$SCENARIO" != broken ]] || exit 2
    echo '2.314-test'; exit 0
fi
phase=sync
user1='' user2='' pass1='' pass2='' admin1='' admin2='' tls1='' tls2='' ssl1=0 ssl2=0
for arg in "$@"; do
    case "$arg" in --password*|--delete*|--expunge*|--showpasswords|--debug*) exit 90 ;; esac
done
while [ "$#" -gt 0 ]; do
    case "$1" in
        --justlogin) phase=auth; shift ;;
        --dry) phase=dry; shift ;;
        --user1) user1="$2"; shift 2 ;; --user2) user2="$2"; shift 2 ;;
        --passfile1) pass1="$2"; shift 2 ;; --passfile2) pass2="$2"; shift 2 ;;
        --authuser1) admin1="$2"; shift 2 ;; --authuser2) admin2="$2"; shift 2 ;;
        --sslargs1) if [[ "$2" = SSL_verify_mode=* ]]; then tls1="${2#*=}"; fi; shift 2 ;;
        --sslargs2) if [[ "$2" = SSL_verify_mode=* ]]; then tls2="${2#*=}"; fi; shift 2 ;;
        --ssl1) ssl1=1; shift ;;
        --ssl2) ssl2=1; shift ;;
        --noreleasecheck|--nolog) shift ;;
        *) shift 2 ;;
    esac
done
[[ "$user1" = "$user2" && "$admin1" = admin@source.test && "$admin2" = admin@target.test ]]
[[ "$tls1" = "${EXPECT_VERIFY1:-1}" && "$tls2" = "${EXPECT_VERIFY2:-1}" ]]
[[ "$ssl1" = 1 && "$ssl2" = 1 ]]
cmp "$pass1" "$TEST_WORK/pass1"
cmp "$pass2" "$TEST_WORK/pass2"
printf '%s\t%s\n' "$phase" "$user1" >> "$TEST_WORK/calls"
if [[ "$SCENARIO" = interrupt ]]; then kill -TERM "$PPID"; sleep 2; exit 99; fi
if [[ "$SCENARIO" = auth-fail && "$phase" = auth && "$user1" = bob@example.com ]]; then exit 161; fi
if [[ "$SCENARIO" = copy-fail && "$phase" = sync && "$user1" = alice@example.com ]]; then exit 111; fi
echo 'Simulated IMAP operation complete'
EOF
cat > "$work/bin/docker" <<'EOF'
#!/bin/bash
set -euo pipefail
case "$1" in
    info) [[ "$SCENARIO" != docker-down ]]; exit ;;
    image) [[ "$SCENARIO" != no-image ]] || exit 1; echo sha256:fixture; exit 0 ;;
    stop) exit 0 ;;
    run) shift ;;
    *) exit 95 ;;
esac
credentials=''
while [ "$1" != sha256:fixture ]; do
    case "$1" in
        --mount)
            mount="$2"
            if [[ "$mount" = *dst=/credentials,readonly ]]; then
                credentials="${mount#type=bind,src=}"
                credentials="${credentials%,dst=/credentials,readonly}"
            fi
            shift 2 ;;
        --rm|--pull=never) shift ;;
        *) shift 2 ;;
    esac
done
shift
[[ "$1" = imapsync ]]; shift
args=()
for arg in "$@"; do
    args+=("${arg//\/credentials/$credentials}")
done
exec "$TEST_WORK/bin/imapsync" "${args[@]}"
EOF
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"
base=(bash "$work/migrate-zimbra-carbonio.sh" migrate-mail
    --host1 source.test --host2 target.test --admin1 admin@source.test --admin2 admin@target.test
    --passfile1 "$work/pass1" --passfile2 "$work/pass2")
run_ok() { "${base[@]}" "$@" > "$work/output" 2>&1 || { cat "$work/output"; exit 1; }; }
run_fail() { if "${base[@]}" "$@" > "$work/output" 2>&1; then echo 'Unexpected success'; exit 1; fi; }
clean_secrets() { test "$(find "$work/secrets" -mindepth 1 | wc -l)" -eq 0; }
run_ok --check-tool
test ! -e "$work/calls"
run_ok --check-login
test "$(wc -l < "$work/calls")" -eq 2
test "$(grep -c '^auth' "$work/calls")" -eq 2
clean_secrets
: > "$work/calls"
run_ok --dry-run --cafile1 "$work/ca.pem"
test "$(grep -c '^auth' "$work/calls")" -eq 2
test "$(grep -c '^dry' "$work/calls")" -eq 2
: > "$work/calls"
run_ok --account bob@example.com
printf 'auth\tbob@example.com\nsync\tbob@example.com\n' > "$work/expected"
cmp "$work/calls" "$work/expected"
: > "$work/calls"
run_ok --engine docker --dry-run --cafile2 "$work/ca.pem"
test "$(wc -l < "$work/calls")" -eq 4
clean_secrets

for SCENARIO in auth-fail copy-fail; do
    export SCENARIO
    : > "$work/calls"
    run_fail
    if [ "$SCENARIO" = auth-fail ]; then
        test "$(wc -l < "$work/calls")" -eq 2
        test "$(grep -c '^auth' "$work/calls")" -eq 2
    else
        test "$(grep -c '^sync' "$work/calls")" -eq 2
    fi
    clean_secrets
done
for SCENARIO in broken locked; do
    export SCENARIO
    : > "$work/calls"
    run_fail
    test ! -s "$work/calls"
done
for SCENARIO in docker-down no-image; do
    export SCENARIO
    run_fail --engine docker
done
export SCENARIO=ok
export EXPECT_VERIFY2=0
run_ok --insecure2 --check-login
export EXPECT_VERIFY1=0
run_ok --engine docker --insecure1 --insecure2 --dry-run
export EXPECT_VERIFY2=1
run_ok --insecure1 --check-login
unset EXPECT_VERIFY1 EXPECT_VERIFY2
: > "$work/calls"
run_fail --account unknown@example.com
run_fail --dryrun
run_fail --host2 source.test
run_fail --port1 65536
run_fail --check-login --dry-run
run_fail --passfile1 "$work/absent-password"
run_fail --cafile2 "$work/absent-ca"
clean_secrets
printf 'zmprov help\n' > "$work/migration-data/accounts.tsv"
run_fail
cp "$work/original.tsv" "$work/migration-data/accounts.tsv"
test ! -s "$work/calls"
export SCENARIO=interrupt
run_fail
clean_secrets
cmp "$work/original.tsv" "$work/migration-data/accounts.tsv"
if grep -r -F -f "$work/pass1" "$work/migration-data/logs" "$work/output"; then exit 1; fi
if grep -r -F -f "$work/pass2" "$work/migration-data/logs" "$work/output"; then exit 1; fi
echo 'PASS: native/Docker invocation, preflight, dry-run, scope, failures, TLS, credentials, interruption and input validation'
