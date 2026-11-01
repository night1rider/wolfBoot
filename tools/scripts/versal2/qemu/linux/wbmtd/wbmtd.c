/* wbmtd.c - wolfBoot partition state tool for the QEMU local Linux test.
 *
 * Part of plan item Q5 "Local Linux test (not CI)" (PR 1). wolfBoot ships
 * no Linux-side tool for the update/confirm interface (the manual,
 * p74-75 and p83-84: wolfBoot_update_trigger() / wolfBoot_success()), so
 * this small one is built here by reusing libwolfboot's own code: this
 * file #includes src/libwolfboot.c verbatim and provides a small
 * /dev/mtdN backend for the ext_flash_* interface that libwolfboot uses
 * on EXT_FLASH targets (the versal2 config marks BOOT/UPDATE/SWAP as
 * external OSPI partitions).
 *
 * The backend (see mtd_backend.c, included below) translates the
 * flash addresses libwolfboot works with (WOLFBOOT_PARTITION_*_ADDRESS
 * + offset) to the MTD character device of the whole 256 MB OSPI flash
 * (flash offset == MTD offset), which the kernel's MTD core presents
 * with the NOR erase-then-program semantics of the real flash. The
 * fixed-partition devices /dev/mtdN (BOOT/UPDATE/SWAP, created by the
 * DTB fixed-partitions node) are left for inspection; the tool drives
 * the parent device because its numbering is stable-by-size.
 *
 * Commands (run inside the QEMU guest as root):
 *   wbmtd state
 *       print the BOOT/UPDATE partition states and image versions.
 *   wbmtd update <image>
 *       erase the UPDATE partition, program <image> at its start, and
 *       call wolfBoot_update_trigger() (UPDATE trailer -> UPDATING).
 *       The next reboot makes wolfBoot validate, swap and boot it.
 *   wbmtd update <image> --corrupt-sig
 *       as update, but first corrupt the image's HDR_SIGNATURE TLV in
 *       RAM (the signed bytes are changed, the payload hash is not) -
 *       the refused-update scenario (L4).
 *   wbmtd confirm
 *       call wolfBoot_success() (BOOT trailer -> SUCCESS).
 *
 * Build: see the Makefile in this directory (static aarch64 for the
 * guest; a host build with the file-backed backend is used by the
 * trailer unit test).
 */
/* wbmtd_target.h (via target.h) must come FIRST: image.h evaluates
 * #ifdef PART_UPDATE_EXT when it is processed, so the PART_*_EXT defines
 * must be visible before image.h (otherwise the partitions are treated as
 * internal and the trailer helpers dereference raw flash addresses). */
#include "target.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include "image.h"
#include "wolfboot/wolfboot.h"

/* Pull in libwolfboot's own implementation (the code under test / reuse). */
#include "libwolfboot.c"

/* The ext_flash_* backend + the HAL stubs libwolfboot references. */
#include "mtd_backend.c"

/* ------------------------------------------------------------------ */
/* helpers                                                            */
/* ------------------------------------------------------------------ */

static void die(const char* msg)
{
    fprintf(stderr, "wbmtd: %s\n", msg);
    exit(1);
}

static void print_state(uint8_t part, const char* name)
{
    uint8_t  st = 0;
    uint32_t ver;

    if (wolfBoot_get_partition_state(part, &st) != 0) {
        printf("  %s: no valid trailer (erased)\n", name);
    }
    else {
        const char* s =
            (st == IMG_STATE_NEW)      ? "NEW" :
            (st == IMG_STATE_UPDATING) ? "UPDATING" :
            (st == IMG_STATE_FINAL_FLAGS) ? "FINAL_FLAGS" :
            (st == IMG_STATE_TESTING)  ? "TESTING" :
            (st == IMG_STATE_SUCCESS)  ? "SUCCESS" :
            "UNKNOWN";
        printf("  %s: state=%s (0x%02x)\n", name, s, st);
    }
    ver = wolfBoot_get_image_version(part);
    printf("  %s: version=%u (valid header)\n", name, ver);
}

/* Scan the signed image header for the HDR_SIGNATURE TLV and corrupt its
 * last 16 bytes. The payload hash (HDR_SHA384) is computed over the image
 * payload only, so the integrity check still passes and the signature
 * check fails - the "broken signature" update of scenario L4. */
static int corrupt_signature(uint8_t* img, uint32_t len)
{
    /* Scan the TLV list exactly like wolfBoot_find_header()
     * (src/libwolfboot.c): byte-wise walk from IMAGE_HEADER_OFFSET to
     * IMAGE_HEADER_SIZE; skip bytes whose first byte is HDR_PADDING
     * (0xFF) or whose position is odd BEFORE interpreting tag/vlen;
     * tag 0 = explicit end; a vlen that would overflow the header
     * budget (4 + vlen > IMAGE_HEADER_SIZE - IMAGE_HEADER_OFFSET)
     * ends the scan; otherwise advance by 4 + vlen.
     * Old (run 5-10) scan, kept for reference - it misaligns on 0xFF
     * padding: a 0xFFFF tag straddling into the next TLV's vlen makes
     * "i += 4 + vlen" land mid-TLV, so the HDR_SIGNATURE TLV (which the
     * real parser finds at offset 0x9C in the v2 FIT header) was never
     * seen and --corrupt-sig died with "no HDR_SIGNATURE TLV found"
     * (Run 11 L4 evidence; the bootloader verified the signature fine,
     * so the TLV was present):
     *   uint16_t tag = (uint16_t)(img[i] | (img[i + 1] << 8));
     *   uint16_t vlen = (uint16_t)(img[i + 2] | (img[i + 3] << 8));
     *   if (tag == 0) break;
     *   if (tag == HDR_SIGNATURE && vlen >= 16 && ...) { ... }
     *   if (vlen == 0 || vlen > 512) i += 1; else i += 4 + vlen;
     */
    uint32_t i = IMAGE_HEADER_OFFSET;

    while (i + 4 <= len && i + 4 < IMAGE_HEADER_SIZE) {
        if (img[i] == 0xFF || (i & 1U)) {
            i += 1;
            continue;
        }
        uint16_t tag = (uint16_t)(img[i] | (img[i + 1] << 8));
        if (tag == 0)
            break;
        uint16_t vlen = (uint16_t)(img[i + 2] | (img[i + 3] << 8));
        if ((uint32_t)(4 + vlen) >
                (uint32_t)(IMAGE_HEADER_SIZE - IMAGE_HEADER_OFFSET))
            break;
        if (tag == HDR_SIGNATURE && vlen >= 16 &&
                (uint32_t)(i + 4 + vlen) <= len) {
            uint32_t k;
            for (k = 0; k < 16; k++)
                img[i + 4 + vlen - 16 + k] ^= 0xA5;
            return 0;
        }
        i += 4 + vlen;
    }
    return -1;
}

int main(int argc, char** argv)
{
    if (argc < 2) {
        fprintf(stderr,
            "usage: wbmtd state | update <image> [--corrupt-sig] | confirm\n");
        return 2;
    }
    if (strcmp(argv[1], "state") == 0) {
        /* Run 9: init the backend first so a missing /dev/mtdN is a
         * clear error instead of "no valid trailer (erased)" for the
         * wrong reason. */
        if (mtd_extflash_init() != 0) {
            fprintf(stderr, "wbmtd: MTD backend init failed (state)\n");
            return 1;
        }
        printf("wolfBoot partition state:\n");
        print_state(PART_BOOT, "BOOT  ");
        print_state(PART_UPDATE, "UPDATE");
        return 0;
    }
    if (strcmp(argv[1], "confirm") == 0) {
        /* Run 9 fix: init the backend BEFORE wolfBoot_success(). Without
         * this the MTD backend's fd is -1, the trailer write silently
         * fails (EBADF, return code ignored) and the tool still prints
         * "set to SUCCESS" - a false success (run 9 L2 evidence: the
         * flash trailer was never written). */
        if (mtd_extflash_init() != 0) {
            fprintf(stderr, "wbmtd: MTD backend init failed (confirm)\n");
            return 1;
        }
        wolfBoot_success();
        printf("wbmtd: BOOT partition state set to SUCCESS\n");
        return 0;
    }
    if (strcmp(argv[1], "update") == 0) {
        uint8_t* img;
        long    sz;
        FILE*   f;
        int     corrupt = 0;
        uint32_t upd_size = WOLFBOOT_PARTITION_UPDATE_SIZE;

        if (argc < 3) {
            fprintf(stderr, "usage: wbmtd update <image> [--corrupt-sig]\n");
            return 2;
        }
        if (argc > 3 && strcmp(argv[3], "--corrupt-sig") == 0)
            corrupt = 1;

        f = fopen(argv[2], "rb");
        if (f == NULL)
            die("cannot open image");
        fseek(f, 0, SEEK_END);
        sz = ftell(f);
        fseek(f, 0, SEEK_SET);
        if (sz <= 0 || (uint32_t)sz > upd_size - WOLFBOOT_SECTOR_SIZE)
            die("image size out of range for the UPDATE partition "
                "(it must leave the trailer sector free)");
        img = (uint8_t*)malloc((size_t)sz);
        if (img == NULL)
            die("out of memory");
        if (fread(img, 1, (size_t)sz, f) != (size_t)sz)
            die("short read");
        fclose(f);

        if (corrupt) {
            if (corrupt_signature(img, (uint32_t)sz) != 0)
                die("no HDR_SIGNATURE TLV found in the image header");
            printf("wbmtd: corrupted the HDR_SIGNATURE TLV (%ld bytes "
                "image)\n", sz);
        }

        /* The image must start at the beginning of the UPDATE partition
         * and the whole partition is erased first: the NOR can only clear
         * bits, so any previous image must be erased before programming. */
        if (mtd_extflash_init() != 0)
            die("MTD backend init failed");
        if (ext_flash_erase(WOLFBOOT_PARTITION_UPDATE_ADDRESS, upd_size) != 0)
            die("erasing the UPDATE partition failed");
        printf("wbmtd: erased UPDATE partition (%u bytes)\n", upd_size);
        /* ext_flash_write (like the wolfBoot HAL convention) returns the
         * number of bytes written on success - NOT 0 - so the check must
         * be < 0 (Run 11: the old "!= 0" check turned every successful
         * 14 MB write into "writing the image into UPDATE failed" and
         * aborted before wolfBoot_update_trigger(); the flash actually
         * contained the complete image - verified byte-for-byte - but no
         * trigger was ever set, so L2/L3/L4 updates were never exercised
         * and the "v2 booted" checks passed on the v1 boot instead).
         * Old (run 5-10) check, kept for reference:
         *   if (ext_flash_write(WOLFBOOT_PARTITION_UPDATE_ADDRESS, img,
         *           (int)sz) != 0)
         *       die("writing the image into UPDATE failed");
         */
        if (ext_flash_write(WOLFBOOT_PARTITION_UPDATE_ADDRESS, img,
                (int)sz) < 0)
            die("writing the image into UPDATE failed");
        printf("wbmtd: wrote %ld bytes at 0x%x\n", sz,
            (unsigned)WOLFBOOT_PARTITION_UPDATE_ADDRESS);

        /* libwolfboot's own trigger: erase the UPDATE trailer sector and
         * set the state to IMG_STATE_UPDATING (+ magic). */
        wolfBoot_update_trigger();
        printf("wbmtd: UPDATE partition state set to UPDATING "
            "(wolfBoot_update_trigger)\n");
        return 0;
    }
    fprintf(stderr, "unknown command '%s'\n", argv[1]);
    return 2;
}
