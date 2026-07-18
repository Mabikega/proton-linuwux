// SPDX-License-Identifier: GPL-2.0
/*
 * Compatibility module for x86 kernels whose UMIP emulator returns a zero
 * descriptor-table limit for SGDT and SIDT.
 *
 * The helper that constructs the result, emulate_umip_insn(), is private and
 * commonly inlined.  Probing a general function such as _copy_to_user() would
 * work around that, but it would also add overhead to unrelated user copies.
 *
 * This module probes only fixup_umip_exception().  It snapshots the user
 * registers when the fixup starts and, after a successful fixup, queues task
 * work for the same process.  Task work runs before that process returns to
 * user mode, in a context where decoding the instruction and accessing its
 * user-memory operand may sleep.  Only a recognized zero-limit dummy GDT or
 * IDT descriptor is changed.
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/atomic.h>
#include <linux/errno.h>
#include <linux/gfp.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/module.h>
#include <linux/overflow.h>
#include <linux/ratelimit.h>
#include <linux/rcupdate.h>
#include <linux/sched.h>
#include <linux/sched/task_stack.h>
#include <linux/slab.h>
#include <linux/task_work.h>
#include <linux/types.h>
#include <linux/uaccess.h>
#include <linux/wait.h>

#include <asm/cpufeature.h>
#include <asm/desc_defs.h>
#include <asm/insn-eval.h>
#include <asm/insn.h>
#include <asm/ptrace.h>
#include <asm/segment.h>

/* Dummy descriptor-table addresses used by the upstream UMIP emulator. */
#define UMIP_DUMMY_GDT_BASE_32 0xfffe0000U
#define UMIP_DUMMY_IDT_BASE_32 0xffff0000U
#define UMIP_DUMMY_GDT_BASE_64 0xfffffffffffe0000ULL
#define UMIP_DUMMY_IDT_BASE_64 0xffffffffffff0000ULL

#define UMIP_RESULT_SIZE_32 6U
#define UMIP_RESULT_SIZE_64 10U

/* An N-byte descriptor table has the inclusive limit N - 1. */
#define UMIP_GDT_LIMIT ((u16)(GDT_SIZE - 1))
#define UMIP_IDT_LIMIT ((u16)((IDT_ENTRIES * sizeof(gate_desc)) - 1))

enum umip_instruction {
	UMIP_NOT_RELEVANT,
	UMIP_SGDT,
	UMIP_SIDT,
};

/*
 * These helpers are declared in kernel headers but are not exported to normal
 * modules on many kernels.  At load time, temporary kprobes resolve their
 * addresses.  The target kernel's own declarations define the ABI against
 * which this module is compiled.
 */
typedef void __user *(*umip_get_addr_t)(struct insn *insn,
					struct pt_regs *regs);
typedef int (*umip_get_modrm_t)(struct insn *insn);
typedef unsigned long (*umip_get_seg_base_t)(struct pt_regs *regs,
					      int seg_reg_idx);
typedef int (*umip_get_code_seg_params_t)(struct pt_regs *regs);
typedef void (*umip_insn_init_t)(struct insn *insn, const void *kaddr,
				 int buf_len, int x86_64);
typedef int (*umip_get_length_t)(struct insn *insn);

/*
 * The third task_work_add() parameter changed type across kernel releases.
 * typeof() preserves the exact target-header function type.  The value 1 has
 * consistently meant "notify on return to user mode" (true/TWA_RESUME).
 */
#define UMIP_TASK_WORK_NOTIFY 1

struct umip_kernel_api {
	umip_get_addr_t get_addr;
	umip_get_modrm_t get_modrm;
	umip_get_seg_base_t get_seg_base;
	umip_get_code_seg_params_t get_code_seg_params;
	umip_insn_init_t insn_init;
	umip_get_length_t get_length;
	typeof(task_work_add) *task_work_add;
};

static struct umip_kernel_api kernel_api;

/* Per-invocation data comes from the kretprobe's preallocated instance pool. */
struct umip_fixup_call {
	struct pt_regs *live_regs;
	struct pt_regs saved_regs;
};

/*
 * A queued object owns the register snapshot until its task-work callback has
 * completed.  It is allocated with GFP_ATOMIC because a kretprobe handler may
 * not sleep.
 */
struct umip_deferred_work {
	struct callback_head callback;
	struct pt_regs saved_regs;
	unsigned long completed_ip;
};

static atomic_t pending_work = ATOMIC_INIT(0);
static DECLARE_WAIT_QUEUE_HEAD(pending_work_wait);

static atomic64_t adjusted_sgdt = ATOMIC64_INIT(0);
static atomic64_t adjusted_sidt = ATOMIC64_INIT(0);
static atomic64_t already_correct = ATOMIC64_INIT(0);
static atomic64_t deferred_failures = ATOMIC64_INIT(0);
static atomic64_t queue_failures = ATOMIC64_INIT(0);

#ifdef CONFIG_X86_KERNEL_IBT
/*
 * IBT may seal private functions that core kernel code never calls through a
 * pointer.  A return-based retpoline can safely reach the verified address
 * after that sealed entry: IBT constrains indirect CALL/JMP, not RET.
 *
 * The assembly thunk expects its target in r10.  This bridge also models the
 * normal x86-64 function-call clobbers so the compiler cannot retain live
 * values in registers that the target is allowed to change.
 */
static __always_inline unsigned long
umip_private_call(unsigned long target, unsigned long arg1,
		  unsigned long arg2, unsigned long arg3, unsigned long arg4)
{
	register unsigned long target_reg asm("r10") = target;
	register unsigned long arg1_reg asm("rdi") = arg1;
	register unsigned long arg2_reg asm("rsi") = arg2;
	register unsigned long arg3_reg asm("rdx") = arg3;
	register unsigned long arg4_reg asm("rcx") = arg4;
	unsigned long result;

	asm volatile("call umip_linuwux_indirect_thunk_r10"
		     : "=a" (result), "+r" (target_reg), "+r" (arg1_reg),
		       "+r" (arg2_reg), "+r" (arg3_reg), "+r" (arg4_reg)
		     :
		     : "r8", "r9", "r11", "memory", "cc");

	return result;
}

#define UMIP_PRIVATE_CALL1(function, arg1) \
	umip_private_call((unsigned long)(function), (unsigned long)(arg1), \
			  0, 0, 0)
#define UMIP_PRIVATE_CALL2(function, arg1, arg2) \
	umip_private_call((unsigned long)(function), (unsigned long)(arg1), \
			  (unsigned long)(arg2), 0, 0)
#define UMIP_PRIVATE_CALL3(function, arg1, arg2, arg3) \
	umip_private_call((unsigned long)(function), (unsigned long)(arg1), \
			  (unsigned long)(arg2), (unsigned long)(arg3), 0)
#define UMIP_PRIVATE_CALL4(function, arg1, arg2, arg3, arg4) \
	umip_private_call((unsigned long)(function), (unsigned long)(arg1), \
			  (unsigned long)(arg2), (unsigned long)(arg3), \
			  (unsigned long)(arg4))
#else
#define UMIP_PRIVATE_CALL1(function, arg1) \
	((function)(arg1))
#define UMIP_PRIVATE_CALL2(function, arg1, arg2) \
	((function)(arg1, arg2))
#define UMIP_PRIVATE_CALL3(function, arg1, arg2, arg3) \
	((function)(arg1, arg2, arg3))
#define UMIP_PRIVATE_CALL4(function, arg1, arg2, arg3, arg4) \
	((function)(arg1, arg2, arg3, arg4))
#endif

/*
 * With Intel Indirect Branch Tracking enabled, x86 kprobes deliberately skip
 * the four-byte entry marker.  That marker is either ENDBR or the poison NOP
 * installed when objtool determines that core kernel code has no indirect
 * calls to the function.  Accept only one of those verified layouts.
 *
 * Keep the instruction constants local instead of depending on asm/ibt.h,
 * which did not exist on older kernels supported by this module.
 */
#ifdef CONFIG_X86_KERNEL_IBT
#ifdef CONFIG_X86_64
#define UMIP_ENDBR_INSN 0xfa1e0ff3U /* ENDBR64, little endian */
#else
#define UMIP_ENDBR_INSN 0xfb1e0ff3U /* ENDBR32, little endian */
#endif
#define UMIP_ENDBR_POISON 0xd6401f0fU
#define UMIP_ENDBR_SIZE 4UL

static int umip_validate_callable_address(const char *name,
					  unsigned long address)
{
	u32 instruction;

	/* Accept kernels whose kprobe implementation preserves the entry. */
	instruction = READ_ONCE(*(const u32 *)address);
	if (instruction == UMIP_ENDBR_INSN)
		return 0;

	/* Current x86 kprobes place probe.addr after either entry marker. */
	instruction = READ_ONCE(*(const u32 *)(address - UMIP_ENDBR_SIZE));
	if (instruction == UMIP_ENDBR_INSN ||
	    instruction == UMIP_ENDBR_POISON)
		return 0;

	pr_err("%s() has no recognized IBT entry; refusing to load\n", name);
	return -ENOEXEC;
}
#else
static int umip_validate_callable_address(const char *name,
					  unsigned long address)
{
	return 0;
}
#endif

/* Resolve one non-exported core-kernel function without retaining a probe. */
static int umip_resolve_function(const char *name, unsigned long *address)
{
	struct kprobe probe = {
		.symbol_name = name,
	};
	int ret;

	ret = register_kprobe(&probe);
	if (ret)
		return ret;

	/* Save the resolved address before unregistering the temporary probe. */
	*address = (unsigned long)probe.addr;
	unregister_kprobe(&probe);

	return umip_validate_callable_address(name, *address);
}

static int umip_resolve_required(const char *name, unsigned long *address)
{
	int ret;

	ret = umip_resolve_function(name, address);
	if (ret)
		pr_err("cannot resolve %s() (%d); refusing to load\n", name, ret);

	return ret;
}

static int umip_resolve_kernel_api(void)
{
	unsigned long address;
	int ret;

	ret = umip_resolve_required("insn_get_addr_ref", &address);
	if (ret)
		return ret;
	kernel_api.get_addr = (umip_get_addr_t)address;

	ret = umip_resolve_required("insn_get_modrm", &address);
	if (ret)
		return ret;
	kernel_api.get_modrm = (umip_get_modrm_t)address;

	ret = umip_resolve_required("insn_get_seg_base", &address);
	if (ret)
		return ret;
	kernel_api.get_seg_base = (umip_get_seg_base_t)address;

	ret = umip_resolve_required("insn_get_code_seg_params", &address);
	if (ret)
		return ret;
	kernel_api.get_code_seg_params = (umip_get_code_seg_params_t)address;

	ret = umip_resolve_required("insn_init", &address);
	if (ret)
		return ret;
	kernel_api.insn_init = (umip_insn_init_t)address;

	ret = umip_resolve_required("insn_get_length", &address);
	if (ret)
		return ret;
	kernel_api.get_length = (umip_get_length_t)address;

	ret = umip_resolve_required("task_work_add", &address);
	if (ret)
		return ret;
	kernel_api.task_work_add = (typeof(kernel_api.task_work_add))address;

	return 0;
}

/* Obtain fixup_umip_exception()'s first C argument on both x86 ABIs. */
static __always_inline struct pt_regs *
umip_get_user_regs(const struct pt_regs *probe_regs)
{
#ifdef CONFIG_X86_64
	return (struct pt_regs *)probe_regs->di;
#else
	return (struct pt_regs *)probe_regs->ax;
#endif
}

/* The exception register frame must be entirely on the current task's stack. */
static bool umip_user_regs_are_safe(const struct pt_regs *regs)
{
	return regs && object_is_on_stack(regs) &&
		object_is_on_stack((const unsigned char *)regs + sizeof(*regs) - 1);
}

/* Identify only memory-form SGDT and SIDT after the kernel decoder ran. */
static enum umip_instruction umip_identify_instruction(struct insn *insn)
{
	if ((int)UMIP_PRIVATE_CALL1(kernel_api.get_modrm, insn))
		return UMIP_NOT_RELEVANT;

	if (!insn->modrm.nbytes || insn->opcode.nbytes < 2 ||
	    insn->opcode.bytes[0] != 0x0f || insn->opcode.bytes[1] != 0x01 ||
	    X86_MODRM_MOD(insn->modrm.value) == 3)
		return UMIP_NOT_RELEVANT;

	switch (X86_MODRM_REG(insn->modrm.value)) {
	case 0:
		return UMIP_SGDT;
	case 1:
		return UMIP_SIDT;
	default:
		return UMIP_NOT_RELEVANT;
	}
}

/*
 * Match the complete dummy descriptor before changing its limit.  This also
 * makes the module harmless on a vendor kernel with a different dummy base.
 */
static bool umip_expected_limit(const unsigned char *result, size_t size,
				u16 *expected_limit,
				enum umip_instruction instruction)
{
	if (size == UMIP_RESULT_SIZE_32) {
		u32 base;

		memcpy(&base, result + sizeof(u16), sizeof(base));
		if (instruction == UMIP_SGDT && base == UMIP_DUMMY_GDT_BASE_32)
			*expected_limit = UMIP_GDT_LIMIT;
		else if (instruction == UMIP_SIDT &&
			 base == UMIP_DUMMY_IDT_BASE_32)
			*expected_limit = UMIP_IDT_LIMIT;
		else
			return false;
	} else if (size == UMIP_RESULT_SIZE_64) {
		u64 base;

		memcpy(&base, result + sizeof(u16), sizeof(base));
		if (instruction == UMIP_SGDT && base == UMIP_DUMMY_GDT_BASE_64)
			*expected_limit = UMIP_GDT_LIMIT;
		else if (instruction == UMIP_SIDT &&
			 base == UMIP_DUMMY_IDT_BASE_64)
			*expected_limit = UMIP_IDT_LIMIT;
		else
			return false;
	} else {
		return false;
	}

	return true;
}

static void umip_record_failure(const char *reason)
{
	atomic64_inc(&deferred_failures);
	pr_warn_ratelimited("%s; leaving the UMIP result unchanged\n", reason);
}

/*
 * Fetch and decode using the low-level helpers that have existed since UMIP
 * emulation was introduced.  Keeping these two small operations here avoids a
 * dependency on newer convenience helpers whose names changed over time.
 */
static int umip_fetch_instruction(struct pt_regs *regs,
				  unsigned char buf[MAX_INSN_SIZE])
{
	unsigned long linear_ip = regs->ip;
	unsigned long segment_base;
	size_t not_copied;

	if (!user_64bit_mode(regs)) {
		segment_base = UMIP_PRIVATE_CALL2(kernel_api.get_seg_base, regs,
						 INAT_SEG_REG_CS);
		if (segment_base == -1UL ||
		    check_add_overflow(linear_ip, segment_base, &linear_ip))
			return -EINVAL;
	}

	not_copied = copy_from_user(buf, (void __user *)linear_ip,
				    MAX_INSN_SIZE);
	return MAX_INSN_SIZE - not_copied;
}

static bool umip_decode_instruction(struct insn *insn, struct pt_regs *regs,
				    unsigned char buf[MAX_INSN_SIZE],
				    int fetched)
{
	int segment_parameters;

	(void)UMIP_PRIVATE_CALL4(kernel_api.insn_init, insn, buf, fetched,
				 user_64bit_mode(regs));
	segment_parameters = (int)UMIP_PRIVATE_CALL1(
		kernel_api.get_code_seg_params, regs);
	if (segment_parameters < 0)
		return false;

	insn->addr_bytes = INSN_CODE_SEG_ADDR_SZ(segment_parameters);
	insn->opnd_bytes = INSN_CODE_SEG_OPND_SZ(segment_parameters);
	if ((int)UMIP_PRIVATE_CALL1(kernel_api.get_length, insn))
		return false;

	return fetched >= insn->length;
}

/*
 * Decode the saved fault and correct the user operand.  Task work executes in
 * the affected process before it resumes user mode, so normal fault-handling
 * user-access helpers are safe here.
 */
static void umip_adjust_user_result(struct umip_deferred_work *work)
{
	unsigned char insn_buf[MAX_INSN_SIZE];
	unsigned char result[UMIP_RESULT_SIZE_64];
	unsigned long expected_ip;
	enum umip_instruction instruction;
	void __user *user_result;
	struct insn insn;
	size_t result_size;
	u16 current_limit;
	u16 expected_limit;
	int fetched;

	fetched = umip_fetch_instruction(&work->saved_regs, insn_buf);
	if (fetched <= 0)
		return;

	if (!umip_decode_instruction(&insn, &work->saved_regs, insn_buf,
				     fetched))
		return;

	instruction = umip_identify_instruction(&insn);
	if (instruction == UMIP_NOT_RELEVANT)
		return;

	if (check_add_overflow(work->saved_regs.ip, (unsigned long)insn.length,
			       &expected_ip) || expected_ip != work->completed_ip) {
		umip_record_failure("the saved instruction length did not match");
		return;
	}

	user_result = (void __user *)UMIP_PRIVATE_CALL2(kernel_api.get_addr,
						      &insn, &work->saved_regs);
	if ((unsigned long)user_result == -1UL) {
		umip_record_failure("the SGDT/SIDT destination could not be decoded");
		return;
	}

	result_size = user_64bit_mode(&work->saved_regs) ?
		UMIP_RESULT_SIZE_64 : UMIP_RESULT_SIZE_32;
	if (copy_from_user(result, user_result, result_size)) {
		umip_record_failure("the SGDT/SIDT result could not be read");
		return;
	}

	if (!umip_expected_limit(result, result_size, &expected_limit,
				 instruction)) {
		umip_record_failure("the SGDT/SIDT dummy descriptor was unexpected");
		return;
	}

	memcpy(&current_limit, result, sizeof(current_limit));
	if (current_limit == expected_limit) {
		atomic64_inc(&already_correct);
		return;
	}

	if (current_limit != 0) {
		umip_record_failure("the SGDT/SIDT limit was neither zero nor expected");
		return;
	}

	if (put_user(expected_limit, (u16 __user *)user_result)) {
		umip_record_failure("the corrected SGDT/SIDT limit could not be written");
		return;
	}

	if (instruction == UMIP_SGDT)
		atomic64_inc(&adjusted_sgdt);
	else
		atomic64_inc(&adjusted_sidt);
}

static void umip_task_work(struct callback_head *callback)
{
	struct umip_deferred_work *work;

	work = container_of(callback, struct umip_deferred_work, callback);
	umip_adjust_user_result(work);
	kfree(work);

	/*
	 * Module exit waits for this count and then an RCU-tasks grace period,
	 * ensuring that no callback can still be executing module text.
	 */
	if (atomic_dec_and_test(&pending_work))
		wake_up_all(&pending_work_wait);
}

/* Snapshot the user register frame before the kernel changes its instruction pointer. */
static int umip_fixup_entry(struct kretprobe_instance *instance,
			    struct pt_regs *probe_regs)
{
	struct umip_fixup_call *call = (void *)instance->data;
	struct pt_regs *user_regs = umip_get_user_regs(probe_regs);

	if (unlikely(!umip_user_regs_are_safe(user_regs))) {
		pr_warn_ratelimited("unexpected fixup_umip_exception() argument; "
				    "skipping this invocation\n");
		return 1;
	}

	call->live_regs = user_regs;
	memcpy(&call->saved_regs, user_regs, sizeof(call->saved_regs));
	return 0;
}

/* Queue correction only after a successful fixup that advanced the user IP. */
static int umip_fixup_return(struct kretprobe_instance *instance,
			     struct pt_regs *probe_regs)
{
	struct umip_fixup_call *call = (void *)instance->data;
	struct umip_deferred_work *work;
	unsigned long completed_ip;
	int ret;

	if (!regs_return_value(probe_regs))
		return 0;

	if (unlikely(!umip_user_regs_are_safe(call->live_regs))) {
		pr_warn_ratelimited("the saved exception frame was no longer safe; "
				    "skipping this invocation\n");
		return 0;
	}

	completed_ip = READ_ONCE(call->live_regs->ip);
	if (completed_ip == call->saved_regs.ip)
		return 0;

	work = kmalloc(sizeof(*work), GFP_ATOMIC | __GFP_NOWARN);
	if (!work) {
		atomic64_inc(&queue_failures);
		pr_warn_ratelimited("cannot allocate deferred work; "
				    "leaving the UMIP result unchanged\n");
		return 0;
	}

	init_task_work(&work->callback, umip_task_work);
	memcpy(&work->saved_regs, &call->saved_regs, sizeof(work->saved_regs));
	work->completed_ip = completed_ip;

	ret = (int)UMIP_PRIVATE_CALL3(kernel_api.task_work_add, current,
				      &work->callback, UMIP_TASK_WORK_NOTIFY);
	if (ret) {
		kfree(work);
		atomic64_inc(&queue_failures);
		pr_warn_ratelimited("cannot queue deferred work (%d); "
				    "leaving the UMIP result unchanged\n", ret);
	} else {
		/* The current task cannot run this callback before we return. */
		atomic_inc(&pending_work);
	}

	return 0;
}

static struct kretprobe fixup_probe = {
	.kp.symbol_name = "fixup_umip_exception",
	.entry_handler = umip_fixup_entry,
	.handler = umip_fixup_return,
	.data_size = sizeof(struct umip_fixup_call),
	/* Zero selects the kernel's CPU-count-based default instance pool. */
	.maxactive = 0,
};

static int __init umip_limit_fix_linuwux_init(void)
{
	int ret;

	BUILD_BUG_ON(GDT_SIZE == 0 || GDT_SIZE > 0x10000UL);
	BUILD_BUG_ON((IDT_ENTRIES * sizeof(gate_desc)) == 0);
	BUILD_BUG_ON((IDT_ENTRIES * sizeof(gate_desc)) > 0x10000UL);

#ifndef CONFIG_KPROBES
	pr_err("CONFIG_KPROBES is disabled; refusing to load\n");
	return -EOPNOTSUPP;
#elif !defined(CONFIG_X86_UMIP)
	pr_info("CONFIG_X86_UMIP is disabled; nothing to do\n");
	return -EOPNOTSUPP;
#else
	if (!boot_cpu_has(X86_FEATURE_UMIP)) {
		pr_info("the boot CPU does not advertise UMIP; nothing to do\n");
		return -ENODEV;
	}

	ret = umip_resolve_kernel_api();
	if (ret)
		return ret;

	ret = register_kretprobe(&fixup_probe);
	if (ret) {
		pr_err("cannot probe fixup_umip_exception() (%d); "
		       "refusing to load\n", ret);
		return ret;
	}

	pr_info("active: SGDT limit=%u, SIDT limit=%u; no user-copy probe\n",
		(unsigned int)UMIP_GDT_LIMIT, (unsigned int)UMIP_IDT_LIMIT);
	return 0;
#endif
}

static void __exit umip_limit_fix_linuwux_exit(void)
{
	/* Stop new callbacks, then drain callbacks already queued by probe returns. */
	unregister_kretprobe(&fixup_probe);
	wait_event(pending_work_wait, atomic_read(&pending_work) == 0);

	/* A task grace period closes the small gap after a callback decrements. */
	synchronize_rcu_tasks();

	pr_info("stopped: adjusted SGDT=%lld SIDT=%lld, already-correct=%lld, deferred-failures=%lld, queue-failures=%lld, missed=%d\n",
		(long long)atomic64_read(&adjusted_sgdt),
		(long long)atomic64_read(&adjusted_sidt),
		(long long)atomic64_read(&already_correct),
		(long long)atomic64_read(&deferred_failures),
		(long long)atomic64_read(&queue_failures), fixup_probe.nmissed);
}

module_init(umip_limit_fix_linuwux_init);
module_exit(umip_limit_fix_linuwux_exit);

MODULE_DESCRIPTION("LinUwUx adjustment for x86 UMIP-emulated SGDT/SIDT limits");
MODULE_VERSION("1.0.0");
MODULE_LICENSE("GPL");
