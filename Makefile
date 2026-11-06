ifneq ($(KERNELRELEASE),)
obj-m += pilote.o
else

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build
KVER_DEBUG ?= $(notdir $(lastword $(sort $(wildcard /lib/modules/*+debug))))

KBUILD = $(MAKE) -C $(KDIR) M=$(CURDIR) MO=$(CURDIR)/build
SRCS = pilote.c edu_ioctl.h
TESTS = charge_decharge bind_unbind
need = command -v $(1) >/dev/null || { echo "$(1) introuvable : sudo dnf install $(2)"; exit 1; }

.PHONY: all clean check checkpatch sparse smatch cocci test test-debug vm vm-debug

all:
	$(KBUILD) modules compile_commands.json

clean:
	rm -rf build qemu/build

check: checkpatch sparse smatch cocci

checkpatch:
	perl $(KDIR)/scripts/checkpatch.pl --no-tree --strict -f $(SRCS)

sparse:
	@$(call need,sparse,sparse)
	@test "$$($(KDIR)/scripts/checker-valid.sh sparse -m64)" = 1 || \
		{ echo "sparse $$(sparse --version) trop ancien pour ce noyau : compiler la version git (voir useful_commands.txt)"; exit 1; }
	$(KBUILD) C=2 W=1 modules

smatch:
	@$(call need,smatch,smatch)
	$(KBUILD) C=2 CHECK="smatch -p=kernel" modules

cocci:
	@$(call need,spatch,coccinelle)
	@mkdir -p build && rm -f build/cocci.log
	$(MAKE) --no-print-directory -C $(KDIR) M=$(CURDIR) coccicheck MODE=report \
		DEBUG_FILE=$(CURDIR)/build/cocci.log

test:
	@for t in $(TESTS); do qemu/check.sh qemu/tests/$$t.sh || exit 1; done

test-debug:
	@test -n "$(KVER_DEBUG)" || { echo "noyau +debug introuvable : sudo dnf install kernel-debug kernel-debug-devel"; exit 1; }
	@for t in $(TESTS) injection_fautes; do \
		KVER=$(KVER_DEBUG) TIMEOUT=300 qemu/check.sh qemu/tests/$$t.sh || exit 1; \
	done

vm:
	qemu/run.sh -e

vm-debug:
	KVER=$(KVER_DEBUG) qemu/run.sh -e

endif
