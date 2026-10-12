KDIR ?= /lib/modules/$(shell uname -r)/build
obj-m += pilote.o

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) MO=$(CURDIR)/build modules compile_commands.json

clean:
	rm -rf build
