# AMD VEK385 (Versal AI Edge Gen 2) on the wolfHAL drivers.
# Used with TARGET=versal2 WOLFHAL=1 BOARD=vek385; arch.mk keeps the
# versal2 CPU flags, link address and linker script.

# Bind the wolfHAL drivers directly to the top-level API symbols:
# whal_Uart_* -> PL011, whal_SpiMem_* -> Cadence OSPI, whal_Flash_* -> NOR
# flash on the OSPI controller. No dispatch sources are compiled.
CFLAGS+=-DWHAL_CFG_PL011_UART_DIRECT_API_MAPPING
CFLAGS+=-DWHAL_CFG_CADENCE_OSPI_SPIMEM_DIRECT_API_MAPPING
CFLAGS+=-DWHAL_CFG_SPIMEM_NOR_FLASH_DIRECT_API_MAPPING

# Console: send '\n' as "\r\n" (hal/wolfhal.c).
CFLAGS+=-DWOLFHAL_UART_CRLF

WOLFHAL_OBJS+=$(WOLFHAL_ROOT)/src/reg.o
WOLFHAL_OBJS+=$(WOLFHAL_ROOT)/src/uart/pl011_uart.o
WOLFHAL_OBJS+=$(WOLFHAL_ROOT)/src/spimem/cadence_ospi_spimem.o
WOLFHAL_OBJS+=$(WOLFHAL_ROOT)/src/spimem/versal2_ospi_dma.o
WOLFHAL_OBJS+=$(WOLFHAL_ROOT)/src/flash/spimem_nor_flash.o

OBJS+=$(WOLFHAL_OBJS)
APP_OBJS+=$(WOLFHAL_OBJS)
