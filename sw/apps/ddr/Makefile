APP  := ddr
GLUE := ../../common/litedram
SRCS := main.c memtest.c selftest.c verify.c \
        $(GLUE)/bow_litedram.c $(GLUE)/bow_litedram_ddr2.c $(GLUE)/bow_litedram_ddr3.c
EXTRA_CFLAGS = -I$(SW_ROOT)/common/litedram
include ../../mk/app.mk

# LiteDRAM glue: the generated headers of one core per file (csr.h,
# sdram_phy.h, soc.h of hw/ip/ddr/litedram/generated/<core>/include) and the
# stand-ins for the LiteX headers they include (common/litedram/include).
LD_GEN := $(REPO_ROOT)/hw/ip/ddr/litedram/generated
LD_OBJ := $(BUILD_DIR)/obj/sw/common/litedram
LD_INC := -I$(SW_ROOT)/common/litedram/include
$(LD_OBJ)/bow_litedram.c.o $(LD_OBJ)/bow_litedram_ddr2.c.o: CFLAGS += $(LD_INC) -I$(LD_GEN)/ddr2/include
$(LD_OBJ)/bow_litedram_ddr3.c.o: CFLAGS += $(LD_INC) -I$(LD_GEN)/ddr3/include
