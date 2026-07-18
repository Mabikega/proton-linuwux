# Build as an external kernel module.
obj-m += umip_limit_fix_linuwux.o
umip_limit_fix_linuwux-y := umip_limit_fix_linuwux_main.o
umip_limit_fix_linuwux-$(CONFIG_X86_KERNEL_IBT) += umip_ibt_thunks_linuwux.o

KDIR ?= /lib/modules/$(shell uname -r)/build

.PHONY: all clean

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
