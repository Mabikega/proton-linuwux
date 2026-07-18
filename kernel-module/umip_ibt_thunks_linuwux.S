/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Local retpoline for calls to sealed private functions on x86 IBT kernels.
 *
 * This is the same annotated sequence used by arch/x86/lib/retpoline.S, under
 * a module-specific name so the module loader does not mistake it for one of
 * the compiler-generated core retpolines that it is responsible for patching.
 */

#include <linux/linkage.h>

#include <asm/nospec-branch.h>
#include <asm/unwind_hints.h>

	.section .text..__x86.indirect_thunk, "ax"

	.macro UMIP_POLINE reg
	ANNOTATE_INTRA_FUNCTION_CALL
	call .Ldo_rop_\@
	int3
.Ldo_rop_\@:
	mov %\reg, (%_ASM_SP)
	UNWIND_HINT_FUNC
	.endm

	.align RETPOLINE_THUNK_SIZE
SYM_FUNC_START(umip_linuwux_indirect_thunk_r10)
	UNWIND_HINT_UNDEFINED
	ANNOTATE_NOENDBR
	UMIP_POLINE r10
	RET
SYM_FUNC_END(umip_linuwux_indirect_thunk_r10)
