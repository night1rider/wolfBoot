/* dac_test.c
 *
 * Linux-test bring-up probe (TARGET=versal2): validates the OSPI
 * access paths the guest Linux MTD driver will use, inside QEMU
 * amd-versal2-virt (QEMU 11.1.3):
 *
 *   1. controller bring-up (ENB_SPI, 2Gb/4-addr-byte device size,
 *      0x13/0x12 default read/program opcodes) - the proven sequence;
 *   2. flash ID (9Fh) via the STIG path;
 *   3. 128 KB sector erase (0xDC) via the STIG path;
 *   4. enable the AXI DAC (linear) window: SLCR 0xF1060504 OSPI mux
 *      (bit 1) + CONFIG ENB_DIR_ACC_CTLR (bit 7);
 *   5. program a 4 KB pattern through the DAC window (CPU stores at
 *      0xC0000000+addr = page programs, 0x12);
 *   6. read it back through the DAC window and compare;
 *   7. cross-verify the same bytes through the STIG read path (0x13).
 *
 * If this passes, the guest MTD driver can use the (fast, memory-
 * mapped) DAC window for bulk read/program and the STIG path for erase.
 * Markers go to UART1 (0xF1930000); final marker "DAC-TEST-DONE rc=<n>".
 *
 * QEMU-only test artifact: never part of the wolfBoot build or image.
 */

#include <stdint.h>
#include <string.h>

/* Device addresses (AM026/AM028, see hal/versal2.h) */
#define OSPI_BASE         0xF1010000UL
#define SLCR_BASE         0xF1060000UL
#define SLCR_OSPI_MUX     0x504UL      /* OSPI_QSPI_IOU_AXI_MUX_SEL */
#define OSPI_DAC_BASE     0xC0000000UL
#define UART1_BASE        0xF1930000UL

/* OSPI APB register offsets */
#define R_CONFIG              0x00
#define R_DEV_INSTR_RD        0x04
#define R_DEV_INSTR_WR        0x08
#define R_DEV_SIZE            0x14
#define R_FLASH_CMD_CTRL      0x90
#define R_FLASH_CMD_ADDR      0x94
#define R_FLASH_RD_DATA_LO    0xA0
#define R_FLASH_RD_DATA_HI    0xA4
#define R_FLASH_WR_DATA_LO    0xA8
#define R_FLASH_WR_DATA_HI    0xAC
#define R_MODULE_ID           0xFC

/* CONFIG bits */
#define CFG_ENB_SPI           (1UL << 0)
#define CFG_ENB_DIR_ACC_CTLR  (1UL << 7)

/* SLCR mux bits */
#define SLCR_OSPI_MUX_SEL     (1UL << 1)   /* select OSPI linear (DAC) */
#define SLCR_QSPI_OSPI_MUX_SEL (1UL << 0)

/* 2 Gb, 4 address bytes, 256-byte page, 16-byte subsector */
#define DEV_SIZE_VERSAL2 \
    ((2UL << 21) | (0x10UL << 16) | (0x100UL << 4) | 3UL)

/* STIG FLASH_CMD_CTRL fields */
#define FCC_OPCODE_SHIFT      24
#define FCC_ENB_READ_DATA     (1UL << 23)
#define FCC_NUM_RD_DATA_SHIFT 20
#define FCC_ENB_COMD_ADDR     (1UL << 19)
#define FCC_NUM_ADDR_SHIFT    16
#define FCC_ENB_WRITE_DATA    (1UL << 15)
#define FCC_NUM_WR_DATA_SHIFT 12
#define FCC_CMD_EXEC_STATUS   (1UL << 1)
#define FCC_CMD_EXEC          (1UL << 0)

#define FLAG_READY            (1U << 7)

/* Partition address (config/examples/versal2_vek385_linux.config). */
#define PART_UPDATE_ADDR      0x49C0000UL

/* PL011 registers */
#define UART_DR   (*(volatile uint32_t*)(UART1_BASE + 0x00))
#define UART_FR   (*(volatile uint32_t*)(UART1_BASE + 0x18))
#define UART_IBRD (*(volatile uint32_t*)(UART1_BASE + 0x24))
#define UART_FBRD (*(volatile uint32_t*)(UART1_BASE + 0x28))
#define UART_LCR  (*(volatile uint32_t*)(UART1_BASE + 0x2C))
#define UART_CR   (*(volatile uint32_t*)(UART1_BASE + 0x30))

static uint32_t ospi_r(uint32_t off)
{
    return *(volatile uint32_t*)(OSPI_BASE + off);
}
static void ospi_w(uint32_t off, uint32_t v)
{
    *(volatile uint32_t*)(OSPI_BASE + off) = v;
}

static void uart_init(void)
{
    UART_CR = 0;
    UART_IBRD = 67;
    UART_FBRD = 32;
    UART_LCR = 0x60;
    UART_CR = 0x203;
}
static void putc(char c)
{
    while (UART_FR & (1 << 5)) {
        ;
    }
    UART_DR = (uint32_t)(unsigned char)c;
}
static void putstr(const char *s)
{
    while (*s) {
        putc(*s++);
    }
}
static void puthex8(uint8_t v)
{
    static const char h[] = "0123456789ABCDEF";

    putc(h[(v >> 4) & 0xF]);
    putc(h[v & 0xF]);
}
static void puthex32(uint32_t v)
{
    static const char h[] = "0123456789ABCDEF";
    int i;

    for (i = 28; i >= 0; i -= 4) {
        putc(h[(v >> i) & 0xF]);
    }
}
static void putnl(void) { putc('\n'); }

/* Send one STIG command (an early copy of the board STIG code). */
static int ospi_stig(uint8_t op, uint32_t addr, int naddr,
                     const uint8_t *wd, int wl, uint8_t *rd, int rl)
{
    uint32_t ctrl = (uint32_t)op << FCC_OPCODE_SHIFT;
    int timeout;

    if (naddr > 0) {
        ctrl |= FCC_ENB_COMD_ADDR |
                ((uint32_t)(naddr - 1) << FCC_NUM_ADDR_SHIFT);
    }
    if (wl > 0) {
        uint32_t lo = 0, hi = 0;
        int i;

        ctrl |= FCC_ENB_WRITE_DATA |
                ((uint32_t)(wl - 1) << FCC_NUM_WR_DATA_SHIFT);
        for (i = 0; i < wl && i < 4; i++) {
            lo |= (uint32_t)wd[i] << (8 * i);
        }
        for (i = 4; i < wl; i++) {
            hi |= (uint32_t)wd[i] << (8 * (i - 4));
        }
        ospi_w(R_FLASH_WR_DATA_LO, lo);
        if (wl > 4) {
            ospi_w(R_FLASH_WR_DATA_HI, hi);
        }
    }
    if (rl > 0) {
        ctrl |= FCC_ENB_READ_DATA |
                ((uint32_t)(rl - 1) << FCC_NUM_RD_DATA_SHIFT);
    }

    ospi_w(R_FLASH_CMD_ADDR, addr);
    ospi_w(R_FLASH_CMD_CTRL, ctrl | FCC_CMD_EXEC);

    timeout = 100000000;
    while (ospi_r(R_FLASH_CMD_CTRL) & FCC_CMD_EXEC_STATUS) {
        if (--timeout == 0) {
            return -1;
        }
    }

    if (rl > 0) {
        uint64_t v = (uint64_t)ospi_r(R_FLASH_RD_DATA_LO);
        int i;

        v |= (uint64_t)ospi_r(R_FLASH_RD_DATA_HI) << 32;
        for (i = 0; i < rl; i++) {
            rd[i] = (uint8_t)(v >> (8 * i));
        }
    }
    return 0;
}

static int ospi_wait_ready(void)
{
    uint8_t st;
    int timeout = 60000000;

    while (timeout > 0) {
        if (ospi_stig(0x70, 0, 0, NULL, 0, &st, 1) != 0) {
            return -1;
        }
        if (st & FLAG_READY) {
            return 0;
        }
        timeout--;
    }
    return -1;
}

static int ospi_erase_128k(uint32_t addr)
{
    if (ospi_stig(0x06, 0, 0, NULL, 0, NULL, 0) != 0) {
        return -1;
    }
    if (ospi_stig(0xDC, addr, 4, NULL, 0, NULL, 0) != 0) {
        return -1;
    }
    return ospi_wait_ready();
}

int main(void)
{
    int rc = 0;
    uint32_t cfg;
    uint8_t id[3] = { 0 };
    uint32_t slcr;
    /* 128 KB test sector */
    uint32_t sec = (uint32_t)PART_UPDATE_ADDR + 0x200000;
    uint32_t *dac = (uint32_t*)(OSPI_DAC_BASE + sec);
    int i;

    uart_init();
    putstr("DAC-TEST-START"); putnl();

    /* 1. Set up the controller (the steps the board code used then). */
    (void)ospi_r(R_MODULE_ID);
    cfg = ospi_r(R_CONFIG);
    ospi_w(R_CONFIG, cfg | CFG_ENB_SPI);
    ospi_w(R_DEV_SIZE, DEV_SIZE_VERSAL2);
    ospi_w(R_DEV_INSTR_RD, 0x13);
    ospi_w(R_DEV_INSTR_WR, 0x12);

    /* 2. flash ID via STIG. */
    if (ospi_stig(0x9F, 0, 0, NULL, 0, id, 3) != 0) {
        putstr("DAC ID: FAIL (no response)"); putnl();
        rc = 1;
    } else {
        putstr("DAC ID: ");
        puthex8(id[0]); putc(' '); puthex8(id[1]); putc(' ');
        puthex8(id[2]);
        if (id[0] == 0x2C && id[1] == 0x5B && id[2] == 0x1C) {
            putstr(" OK (MT35XU02G)");
        } else {
            putstr(" UNEXPECTED");
        }
        putnl();
        if (!(id[0] == 0x2C && id[1] == 0x5B && id[2] == 0x1C)) {
            rc = 1;
        }
    }

    /* 3. erase a 128 KB sector via STIG. */
    if (ospi_erase_128k(sec) != 0) {
        putstr("DAC ERASE: FAIL"); putnl();
        rc = 1;
    } else {
        putstr("DAC ERASE: OK"); putnl();
    }

    /* 4. Turn on the DAC window: SLCR OSPI mux bit 1, then DIR_ACC_CTLR. */
    slcr = *(volatile uint32_t*)(SLCR_BASE + SLCR_OSPI_MUX);
    *(volatile uint32_t*)(SLCR_BASE + SLCR_OSPI_MUX) =
        (slcr & ~SLCR_QSPI_OSPI_MUX_SEL) | SLCR_OSPI_MUX_SEL;
    cfg = ospi_r(R_CONFIG);
    ospi_w(R_CONFIG, cfg | CFG_ENB_SPI | CFG_ENB_DIR_ACC_CTLR);

    /* 5. program a 4 KB pattern through the DAC window (word stores). */
    for (i = 0; i < 1024; i++) {   /* 1024 words = 4 KB */
        dac[i] = (uint32_t)(0xA5A50000u | (uint32_t)i);
    }

    /* 6. read it back through the DAC window and compare. */
    {
        int mism = 0;

        for (i = 0; i < 1024; i++) {
            if (dac[i] != (uint32_t)(0xA5A50000u | (uint32_t)i)) {
                if (mism < 4) {
                    putstr("DAC RW MISMATCH @w"); puthex32((uint32_t)i);
                    putstr(" got="); puthex32(dac[i]); putnl();
                }
                mism++;
            }
        }
        if (mism == 0) {
            putstr("DAC RW: OK (4 KB through the linear window)"); putnl();
        } else {
            putstr("DAC RW: FAIL ("); puthex32((uint32_t)mism);
            putstr(" mismatches)"); putnl();
            rc = 1;
        }
    }

    /* 7. Check the first 8 bytes again with a STIG read. */
    {
        uint8_t rd[8];

        if (ospi_stig(0x13, sec, 4, NULL, 0, rd, 8) != 0) {
            putstr("DAC STIG-XCHK: FAIL (read)"); putnl();
            rc = 1;
        } else {
            int ok = 1;

            /* Word i is 0xA5A50000|i, stored low byte first. */
            for (i = 0; i < 8; i++) {
                uint32_t w = 0xA5A50000u | (uint32_t)(i >> 2);

                if (rd[i] != (uint8_t)(w >> (8 * (i & 3)))) {
                    ok = 0;
                }
            }
            if (ok) {
                putstr("DAC STIG-XCHK: OK (STIG 0x13 matches DAC write)");
                putnl();
            } else {
                putstr("DAC STIG-XCHK: FAIL (STIG read differs)"); putnl();
                rc = 1;
            }
        }
    }

    putstr("DAC-TEST-DONE rc=");
    puthex32((uint32_t)rc);
    putnl();

    while (1) {
        __asm__ volatile ("wfi");
    }
}
