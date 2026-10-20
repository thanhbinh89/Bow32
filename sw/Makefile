# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Build the boot ROM and every application in sw/apps/.

APPS := $(notdir $(patsubst %/,%,$(dir $(wildcard apps/*/Makefile))))

all: bootrom $(APPS)

bootrom:
	$(MAKE) -C bootrom all

$(APPS):
	$(MAKE) -C apps/$@ all

clean:
	$(MAKE) -C bootrom clean
	$(foreach a,$(APPS),$(MAKE) -C apps/$(a) clean;)

.PHONY: all clean bootrom $(APPS)
