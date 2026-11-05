/* wbmtd_target.h - target.h for wbmtd and its host test. Geometry must
 * match config/examples/versal2_vek385*.config; all partitions external. */
#ifndef H_WBMTD_TARGET
#define H_WBMTD_TARGET

#ifndef WOLFBOOT_NO_PARTITIONS
#    define WOLFBOOT_FIXED_PARTITIONS
#endif

/* 128 KB (trailer/swap sector) */
#define WOLFBOOT_SECTOR_SIZE                 0x20000

#ifdef WOLFBOOT_FIXED_PARTITIONS
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
