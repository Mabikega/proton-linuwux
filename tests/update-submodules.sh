#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/source/.git" "$test_dir/bin" "$test_dir/state"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ ! -e "$TEST_STATE/first" ]]; then' \
    '    touch "$TEST_STATE/first"' \
    '    exit 1' \
    'fi' \
    'if [[ ! -e "$TEST_STATE/second" ]]; then' \
    '    touch "$TEST_STATE/second"' \
    '    exit 1' \
    'fi' \
    'printf "%s\\n" "$*" > "$TEST_STATE/success"' \
    > "$test_dir/bin/git"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\\n" "$*" >> "$TEST_STATE/sleeps"' \
    > "$test_dir/bin/sleep"
chmod +x "$test_dir/bin/git" "$test_dir/bin/sleep"

TEST_STATE="$test_dir/state" PATH="$test_dir/bin:/usr/bin:/bin" \
    "$project_dir/scripts/update-submodules.sh" "$test_dir/source" \
    > "$test_dir/stdout" 2> "$test_dir/stderr"

test -f "$test_dir/state/first"
test -f "$test_dir/state/second"
grep -Fxq -- \
    '-C '"$test_dir/source"' submodule update --init --force --filter=tree:0 --recursive' \
    "$test_dir/state/success"
grep -Fxq '10' "$test_dir/state/sleeps"
grep -Fxq 'Submodule checkout failed; retrying cached checkout' \
    "$test_dir/stderr"

mkdir "$test_dir/fail-bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$test_dir/fail-bin/git"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$test_dir/fail-bin/sleep"
chmod +x "$test_dir/fail-bin/git" "$test_dir/fail-bin/sleep"

if PATH="$test_dir/fail-bin:/usr/bin:/bin" \
    "$project_dir/scripts/update-submodules.sh" "$test_dir/source" \
    > "$test_dir/fail-stdout" 2> "$test_dir/fail-stderr"; then
    echo "Submodule checkout unexpectedly succeeded" >&2
    exit 1
fi
grep -Fxq 'Submodule checkout failed after all retries' \
    "$test_dir/fail-stderr"
