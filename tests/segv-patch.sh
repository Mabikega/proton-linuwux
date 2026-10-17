#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/wine/dlls/ntdll/unix"
source_file="$test_dir/wine/dlls/ntdll/unix/signal_x86_64.c"
cat > "$source_file" <<'SOURCE'
static void segv_handler( int signal, siginfo_t *siginfo, void *sigcontext )
{
    ucontext_t *ucontext = sigcontext;
    EXCEPTION_RECORD rec = { 0 };
    struct xcontext context;
    void *steamclient_addr = NULL;

    /* New upstream CPUID handling invalidated the old patch context. */
    if (handle_cpuid_fault( ucontext )) return;
    init_handler( sigcontext );
}

static void trap_handler( int signal, siginfo_t *siginfo, void *sigcontext )
{
    ucontext_t *ucontext = init_handler( sigcontext );
    EXCEPTION_RECORD rec = { 0 };
    struct xcontext context;

    if (handle_syscall_trap( ucontext, siginfo )) return;
}
SOURCE
cp "$source_file" "$test_dir/original.c"
patch --batch --forward --fuzz=0 -Np1 -d "$test_dir" \
    -i "$project_dir/patches/linuwux-segv.patch"
sed -n '/static void segv_handler/,/^}/p' "$source_file" \
    | grep -Fq TargetSysHandler
if sed -n '/static void trap_handler/,/^}/p' "$source_file" \
    | grep -Fq TargetSysHandler; then
    echo "CPUID hook was inserted into the trap handler" >&2
    exit 1
fi
grep -Fq 'if (handle_cpuid_fault( ucontext )) return;' "$source_file"
cp "$test_dir/original.c" "$source_file"
sed -i 's/static void segv_handler/static void renamed_handler/' "$source_file"
if patch --dry-run --batch --forward --fuzz=0 -Np1 -d "$test_dir" \
    -i "$project_dir/patches/linuwux-segv.patch" > /dev/null 2>&1; then
    echo "CPUID patch accepted an unrelated function" >&2
    exit 1
fi
