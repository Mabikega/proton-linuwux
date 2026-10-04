#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/wine/dlls/ntdll/unix"
source_file="$test_dir/wine/dlls/ntdll/unix/signal_x86_64.c"
cat > "$source_file" <<'SOURCE'
static BOOL handle_syscall_trap( ucontext_t *sigcontext, siginfo_t *siginfo )
{
    struct syscall_frame *frame = get_syscall_frame();
    return TRUE;
}

static void sigsys_handler( int signal, siginfo_t *siginfo, void *sigcontext )
{
    extern const void *__wine_syscall_dispatcher_prolog_end_ptr;
    static int n25_repaired;
    ucontext_t *ucontext = init_handler( sigcontext );
    struct syscall_frame *frame = get_syscall_frame();
}
SOURCE
cp "$source_file" "$test_dir/original.c"

patch --batch --forward --fuzz=0 -Np1 -d "$test_dir" \
    -i "$project_dir/patches/linuwux-sigsys.patch"
if sed -n '/static BOOL handle_syscall_trap/,/^}/p' "$source_file" \
    | grep -Fq TargetSysHandler; then
    echo "SIGSYS hook was inserted into the trap handler" >&2
    exit 1
fi
sed -n '/static void sigsys_handler/,/^}/p' "$source_file" \
    | grep -Fq TargetSysHandler

# Fail closed when the upstream function context changes.
cp "$test_dir/original.c" "$source_file"
sed -i 's/static void sigsys_handler/static void renamed_handler/' "$source_file"
if patch --dry-run --batch --forward --fuzz=0 -Np1 -d "$test_dir" \
    -i "$project_dir/patches/linuwux-sigsys.patch" \
    > "$test_dir/stdout" 2> "$test_dir/stderr"; then
    echo "SIGSYS patch accepted an unrelated function" >&2
    exit 1
fi
