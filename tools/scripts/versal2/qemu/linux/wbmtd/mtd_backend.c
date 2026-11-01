/* mtd_backend.c - ext_flash_* backend for wbmtd (QEMU local Linux test).
 *
 * libwolfboot (src/libwolfboot.c, included by wbmtd.c) drives every
 * partition operation of the versal2 target through the ext_flash_*
 * interface (BOOT/UPDATE/SWAP are external OSPI partitions, see
 * PART_*_EXT in wbmtd_target.h). This backend implements that interface:
 *
 *   - WBMTD_BACKEND_MTD (the guest tool): on the MTD character device of
 *     the WHOLE 256 MB OSPI flash, discovered by size among /dev/mtdN
 *     (the flash base is 0x0, so a flash address IS an MTD offset). The
 *     kernel MTD core applies the NOR semantics of the real flash:
 *     MEMERASE issues the 128 KB sector erase, write() programs (bit-
 *     clear only). Erase-then-write is enforced by the driver + flash.
 *   - WBMTD_BACKEND_FILE (the host unit test): on a regular file with
 *     emulated NOR semantics (erase = 0xFF fill, write = AND), so the
 *     trailer bytes produced by libwolfboot's own
 *     wolfBoot_update_trigger()/wolfBoot_success() can be checked on the
 *     host without a device.
 *
 * Only the addresses libwolfboot actually uses (the three partitions)
 * are accepted; anything else is refused, mirroring the OSPI driver's
 * address guard (hal/versal2.c).
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#ifndef WBMTD_BACKEND_FILE
#    include <fcntl.h>
#    include <unistd.h>
#    include <errno.h>
#    include <sys/ioctl.h>
#endif

#ifndef WBMTD_BACKEND_FILE
/*
 * MTD user-space ABI (matches the guest kernel's include/uapi/mtd/mtd-abi.h:
 * this kernel dropped MEMGETSIZE and the oobsize field of the erase struct).
 * The layouts below mirror the kernel's exactly so the ioctl numbers
 * (_IOR/_IOW, size in bytes) match; keeping them local avoids depending on
 * the cross toolchain's kernel UAPI headers.
 */
struct wb_mtd_info_user {
    uint8_t  type;
    uint32_t flags;
    uint32_t size;      /* total size of the MTD */
    uint32_t erasesize;
    uint32_t writesize;
    uint32_t oobsize;
    uint64_t padding;
};
struct wb_erase_info_user {
    uint32_t start;
    uint32_t length;
};
#define WB_MEMGETINFO  _IOR('M', 1, struct wb_mtd_info_user)
#define WB_MEMERASE    _IOW('M', 2, struct wb_erase_info_user)
#endif

/* Whole-flash size (Micron MT35XU02GCBA, 256 MB) - the parent MTD device
 * is the unique one with this size. */
#ifndef WBMTD_FLASH_SIZE
#define WBMTD_FLASH_SIZE 0x10000000
#endif

/* --- partition table (flash address, size, label) ------------------- */
struct mtd_part {
    uintptr_t base;
    uint32_t  size;
    const char* label;
};
static const struct mtd_part mtd_parts[] = {
    { WOLFBOOT_PARTITION_BOOT_ADDRESS,   WOLFBOOT_PARTITION_SIZE,     "boot" },
    { WOLFBOOT_PARTITION_UPDATE_ADDRESS, WOLFBOOT_PARTITION_UPDATE_SIZE, "update" },
    { WOLFBOOT_PARTITION_SWAP_ADDRESS,   WOLFBOOT_SECTOR_SIZE,        "swap" },
};
#define N_MTD_PARTS (sizeof(mtd_parts) / sizeof(mtd_parts[0]))

static int mtd_fd = -1;

#ifndef WBMTD_BACKEND_FILE
/* ------------------------------------------------------------------ */
/* /dev/mtdN backend                                                  */
/* ------------------------------------------------------------------ */

/* Find the MTD device whose size is the whole flash (256 MB). Returns the
 * fd, or -1. */
static int mtd_find_whole_flash(void)
{
    int n;
    for (n = 0; n < 16; n++) {
        char path[32];
        int  fd;
        struct wb_mtd_info_user mi;
        snprintf(path, sizeof(path), "/dev/mtd%d", n);
        fd = open(path, O_RDWR);
        if (fd < 0)
            continue;
        if (ioctl(fd, WB_MEMGETINFO, &mi) == 0 &&
                (uint32_t)mi.size == WBMTD_FLASH_SIZE) {
            return fd;
        }
        close(fd);
    }
    return -1;
}

int mtd_extflash_init(void)
{
    mtd_fd = mtd_find_whole_flash();
    if (mtd_fd < 0) {
        fprintf(stderr, "mtd: no /dev/mtdN with size %d (whole OSPI "
            "flash) found\n", WBMTD_FLASH_SIZE);
        return -1;
    }
    return 0;
}

/* Translate a flash address to (fd, offset). All addresses are inside the
 * whole flash, so the offset is the address itself. Returns 0 or -1. */
static int mtd_addr_ok(uintptr_t addr, int len)
{
    if (len <= 0)
        return -1;
    if (addr + (uint32_t)len > WBMTD_FLASH_SIZE)
        return -1;
    /* Must fall inside one of the known partitions (address guard). */
    {
        size_t i;
        for (i = 0; i < N_MTD_PARTS; i++) {
            if (addr >= mtd_parts[i].base &&
                addr + (uint32_t)len <= mtd_parts[i].base + mtd_parts[i].size)
                return 0;
        }
        return -1;
    }
}

int ext_flash_read(uintptr_t address, uint8_t* data, int len)
{
    int got;
    if (mtd_addr_ok(address, len) != 0)
        return -1;
    if (lseek(mtd_fd, (off_t)address, SEEK_SET) != (off_t)address)
        return -1;
    got = read(mtd_fd, data, (size_t)len);
    return (got == len) ? got : -1;
}

int ext_flash_write(uintptr_t address, const uint8_t* data, int len)
{
    int put;
    if (mtd_addr_ok(address, len) != 0) {
        fprintf(stderr, "wbmtd: ext_flash_write: addr 0x%lx len %d "
            "rejected by mtd_addr_ok\n", (unsigned long)address, len);
        return -1;
    }
    if (lseek(mtd_fd, (off_t)address, SEEK_SET) != (off_t)address) {
        fprintf(stderr, "wbmtd: ext_flash_write: lseek(0x%lx) failed "
            "(errno %d)\n", (unsigned long)address, errno);
        return -1;
    }
    put = write(mtd_fd, data, (size_t)len);
    if (put != len)
        /* Run 11 diagnostics: the stock kernel's MTD/SPI-NOR path can fail
         * a long write with no dmesg message (Run 11 L2/L3: a 14 MB
         * write failed near its end; L4 early). Report where + errno so
         * the failing offset and kernel error are visible in the test log. */
        fprintf(stderr, "wbmtd: ext_flash_write: lseek 0x%lx ok, write "
            "returned %d of %d (errno %d)\n",
            (unsigned long)address, put, len, errno);
    return (put == len) ? put : -1;
}

int ext_flash_erase(uintptr_t address, int len)
{
    struct wb_erase_info_user ei;
    if (mtd_addr_ok(address, len) != 0)
        return -1;
    if ((address % WOLFBOOT_SECTOR_SIZE) != 0 ||
        ((uint32_t)len % WOLFBOOT_SECTOR_SIZE) != 0)
        return -1; /* erase must be sector-aligned and a whole number of sectors */
    memset(&ei, 0, sizeof(ei));
    ei.start  = (uint32_t)address;
    ei.length = (uint32_t)len;
    if (ioctl(mtd_fd, WB_MEMERASE, &ei) != 0)
        return -1;
    return 0;
}

void ext_flash_lock(void)   { }
void ext_flash_unlock(void) { }

#else
/* ------------------------------------------------------------------ */
/* file backend (host unit test) with NOR semantics                   */
/* ------------------------------------------------------------------ */

static FILE*   mtd_file = NULL;
static uint32_t mtd_file_size = WBMTD_FLASH_SIZE;

int mtd_extflash_init(void)
{
    const char* path = getenv("WBMTD_FILE");
    if (path == NULL)
        path = "/tmp/wbmtd-test-flash.bin";
    mtd_file = fopen(path, "r+b");
    if (mtd_file == NULL)
        mtd_file = fopen(path, "wb+");
    if (mtd_file == NULL)
        return -1;
    /* grow to full flash size, erased */
    if (fseek(mtd_file, 0, SEEK_END) != 0)
        return -1;
    {
        long cur = ftell(mtd_file);
        if (cur < (long)WBMTD_FLASH_SIZE) {
            if (fseek(mtd_file, 0, SEEK_SET) != 0)
                return -1;
            {
                static uint8_t ff[65536];
                memset(ff, 0xFF, sizeof(ff));
                while (cur < (long)WBMTD_FLASH_SIZE) {
                    long chunk = (cur + (long)sizeof(ff) > (long)WBMTD_FLASH_SIZE)
                        ? ((long)WBMTD_FLASH_SIZE - cur) : (long)sizeof(ff);
                    if (fwrite(ff, 1, (size_t)chunk, mtd_file) != (size_t)chunk)
                        return -1;
                    cur += chunk;
                }
            }
        }
    }
    return 0;
}

static int mtd_addr_ok(uintptr_t addr, int len)
{
    size_t i;
    if (len <= 0)
        return -1;
    if (addr + (uint32_t)len > WBMTD_FLASH_SIZE)
        return -1;
    for (i = 0; i < N_MTD_PARTS; i++) {
        if (addr >= mtd_parts[i].base &&
            addr + (uint32_t)len <= mtd_parts[i].base + mtd_parts[i].size)
            return 0;
    }
    return -1;
}

int ext_flash_read(uintptr_t address, uint8_t* data, int len)
{
    if (mtd_addr_ok(address, len) != 0)
        return -1;
    if (fseek(mtd_file, (long)address, SEEK_SET) != 0)
        return -1;
    return (int)fread(data, 1, (size_t)len, mtd_file);
}

int ext_flash_write(uintptr_t address, const uint8_t* data, int len)
{
    uint8_t cur[4096];
    int i;
    if (mtd_addr_ok(address, len) != 0)
        return -1;
    /* NOR program: new = old & data (bits can only be cleared) */
    i = 0;
    while (i < len) {
        int chunk = (len - i > (int)sizeof(cur)) ? (int)sizeof(cur) : (len - i);
        if (fseek(mtd_file, (long)(address + i), SEEK_SET) != 0)
            return -1;
        if ((int)fread(cur, 1, (size_t)chunk, mtd_file) != chunk)
            return -1;
        {
            int k;
            for (k = 0; k < chunk; k++)
                cur[k] &= data[i + k];
        }
        if (fseek(mtd_file, (long)(address + i), SEEK_SET) != 0)
            return -1;
        if (fwrite(cur, 1, (size_t)chunk, mtd_file) != (size_t)chunk)
            return -1;
        i += chunk;
    }
    return len;
}

int ext_flash_erase(uintptr_t address, int len)
{
    if (mtd_addr_ok(address, len) != 0)
        return -1;
    if ((address % WOLFBOOT_SECTOR_SIZE) != 0 ||
        ((uint32_t)len % WOLFBOOT_SECTOR_SIZE) != 0)
        return -1;
    {
        static uint8_t ff[65536];
        int off;
        memset(ff, 0xFF, sizeof(ff));
        if (fseek(mtd_file, (long)address, SEEK_SET) != 0)
            return -1;
        off = 0;
        while (off < len) {
            int chunk = (len - off > (int)sizeof(ff)) ? (int)sizeof(ff) : (len - off);
            if (fwrite(ff, 1, (size_t)chunk, mtd_file) != (size_t)chunk)
                return -1;
            off += chunk;
        }
    }
    return 0;
}

void ext_flash_lock(void)   { }
void ext_flash_unlock(void) { }

#endif /* WBMTD_BACKEND_FILE */

/* ------------------------------------------------------------------ */
/* HAL stubs referenced by libwolfboot.c.                             */
/*                                                                    */
/* All partitions are external (PART_*_EXT), so the trailer paths use */
/* the ext_flash_* functions above; the hal_flash_* are only reached  */
/* for non-external partitions (none here) but must still link.       */
/* ------------------------------------------------------------------ */
void hal_init(void) { }
int  hal_flash_write(uint32_t address, const uint8_t* data, int len)
{
    (void)address; (void)data; (void)len;
    return -1; /* must not be used on this target (all parts are ext) */
}
int  hal_flash_erase(uint32_t address, int len)
{
    (void)address; (void)len;
    return -1;
}
void hal_flash_unlock(void) { }
void hal_flash_lock(void)   { }
void hal_prepare_boot(void) { }
int  hal_flash_protect(uint32_t address, int len)
{
    (void)address; (void)len;
    return 0;
}
void* hal_get_primary_address(void)
{
    return (void*)(uintptr_t)WOLFBOOT_PARTITION_BOOT_ADDRESS;
}
void* hal_get_update_address(void)
{
    return (void*)(uintptr_t)WOLFBOOT_PARTITION_UPDATE_ADDRESS;
}
/* NOTE: hal_flash_is_erased() / ext_flash_is_erased() are NOT overridden:
 * libwolfboot.c provides weak defaults, and the ext default reads through
 * ext_flash_read() (this backend). On this target every partition is
 * external, so the non-ext hal_flash_is_erased() default (raw memory read)
 * is never reached. */
