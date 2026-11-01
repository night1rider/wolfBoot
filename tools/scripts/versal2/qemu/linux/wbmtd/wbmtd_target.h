/* wbmtd_target.h
 *
 * target.h for the QEMU local-Linux-test update tool (wbmtd) and for the
 * host unit test that checks its trailer bytes against libwolfboot's
 * reference operations.
 *
 * The partition geometry MUST match config/examples/versal2_vek385*.config
 * (run-13 Bank A layout: 8 MB BOOT.BIN reservation 0x15C0000-0x1DBFFFF,
 * run 13 layout decision - AMD BOOT.BIN 5.31 MiB,
 * evidence/mdom-bank-analysis-run9.txt): 128 KB erase sectors, 44 MB
 * BOOT/UPDATE partitions, the SWAP "User Scratchpad" sector. All three
 * partitions are on the external (OSPI) flash, so the PART_*_EXT defines
 * route libwolfboot's trailer helpers through the ext_flash_* backend
 * provided by mtd_backend.c (/dev/mtdN in Linux, file-backed NOR
 * emulation on the host).
 */
#ifndef H_WBMTD_TARGET
#define H_WBMTD_TARGET

#ifndef WOLFBOOT_NO_PARTITIONS
#    define WOLFBOOT_FIXED_PARTITIONS
#endif

#define WOLFBOOT_SECTOR_SIZE                 0x10000 /* 64 KB (trailer/swap sector) */

#ifdef WOLFBOOT_FIXED_PARTITIONS
/* Run 13 layout decision: 8 MB BOOT.BIN reservation, AMD BOOT.BIN
 * 5.31 MiB, evidence/mdom-bank-analysis-run9.txt. Old (run 3-12) values,
 * kept for reference:
#    define WOLFBOOT_PARTITION_BOOT_ADDRESS    0x19C0000
#    define WOLFBOOT_PARTITION_UPDATE_ADDRESS  0x4600000
 */
#    define WOLFBOOT_PARTITION_BOOT_ADDRESS    0x1DC0000
#    define WOLFBOOT_PARTITION_UPDATE_ADDRESS  0x49C0000
#    define WOLFBOOT_PARTITION_SWAP_ADDRESS    0xFA40000
#    define WOLFBOOT_PARTITION_SIZE            0x2C00000 /* 44 MB */
#    define WOLFBOOT_PARTITION_UPDATE_SIZE     0x2C00000 /* 44 MB */
#endif

/* External-flash partitions (EXT_FLASH build; see mtd_backend.c). */
#define PART_BOOT_EXT
#define PART_UPDATE_EXT
#define PART_SWAP_EXT

#endif /* H_WBMTD_TARGET */
