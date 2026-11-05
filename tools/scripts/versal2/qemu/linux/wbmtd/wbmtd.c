/* wbmtd.c - wolfBoot partition tool for the Linux test (libwolfboot on
 * /dev/mtd). Commands: state, update <image> [--corrupt-sig], confirm. */
/* target.h must come before image.h, so image.h sees PART_*_EXT. If not,
 * the partitions are treated as internal flash and read as raw memory. */
#include "target.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include "image.h"
#include "wolfboot/wolfboot.h"

/* Reuse libwolfboot's own code. */
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
        const char* s = "UNKNOWN";

        if (st == IMG_STATE_NEW) {
            s = "NEW";
        }
        else if (st == IMG_STATE_UPDATING) {
            s = "UPDATING";
        }
        else if (st == IMG_STATE_FINAL_FLAGS) {
            s = "FINAL_FLAGS";
        }
        else if (st == IMG_STATE_TESTING) {
            s = "TESTING";
        }
        else if (st == IMG_STATE_SUCCESS) {
            s = "SUCCESS";
        }
        printf("  %s: state=%s (0x%02x)\n", name, s, st);
    }
    ver = wolfBoot_get_image_version(part);
    printf("  %s: version=%u (valid header)\n", name, ver);
}

/* Flip the last 16 bytes of the HDR_SIGNATURE TLV: the payload hash still
 * passes, the signature check fails (L4). */
static int corrupt_signature(uint8_t* img, uint32_t len)
{
    /* Walk the TLVs like wolfBoot_find_header(), skipping 0xFF padding and
     * odd offsets one byte at a time. */
    uint32_t i = IMAGE_HEADER_OFFSET;

    while (i + 4 <= len && i + 4 < IMAGE_HEADER_SIZE) {
        uint16_t tag, vlen;

        if (img[i] == 0xFF || (i & 1U)) {
            i += 1;
            continue;
        }
        tag = (uint16_t)(img[i] | (img[i + 1] << 8));
        if (tag == 0) {
            break;
        }
        vlen = (uint16_t)(img[i + 2] | (img[i + 3] << 8));
        if ((uint32_t)(4 + vlen) >
                (uint32_t)(IMAGE_HEADER_SIZE - IMAGE_HEADER_OFFSET)) {
            break;
        }
        if (tag == HDR_SIGNATURE && vlen >= 16 &&
                (uint32_t)(i + 4 + vlen) <= len) {
            uint32_t k;
            for (k = 0; k < 16; k++) {
                img[i + 4 + vlen - 16 + k] ^= 0xA5;
            }
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
        /* Init first, so a missing /dev/mtdN gives a clear error and
         * not a wrong "no valid trailer". */
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
        uint8_t st = 0;

        /* Init before wolfBoot_success(). If not, the write fails with
         * no error and the tool still prints "set to SUCCESS". */
        if (mtd_extflash_init() != 0) {
            fprintf(stderr, "wbmtd: MTD backend init failed (confirm)\n");
            return 1;
        }
        /* wolfBoot boots a newer UPDATE in place as TESTING; confirm UPDATE
         * then, since wolfBoot_success() only marks BOOT. */
        if ((wolfBoot_get_partition_state(PART_UPDATE, &st) == 0) &&
            (st == IMG_STATE_TESTING)) {
            wolfBoot_set_partition_state(PART_UPDATE, IMG_STATE_SUCCESS);
            printf("wbmtd: UPDATE partition state set to SUCCESS\n");
        }
        else {
            wolfBoot_success();
            printf("wbmtd: BOOT partition state set to SUCCESS\n");
        }
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
        if (argc > 3 && strcmp(argv[3], "--corrupt-sig") == 0) {
            corrupt = 1;
        }

        f = fopen(argv[2], "rb");
        if (f == NULL) {
            die("cannot open image");
        }
        fseek(f, 0, SEEK_END);
        sz = ftell(f);
        fseek(f, 0, SEEK_SET);
        if (sz <= 0 || (uint32_t)sz > upd_size - WOLFBOOT_SECTOR_SIZE) {
            die("image size out of range for the UPDATE partition "
                "(it must leave the trailer sector free)");
        }
        img = (uint8_t*)malloc((size_t)sz);
        if (img == NULL) {
            die("out of memory");
        }
        if (fread(img, 1, (size_t)sz, f) != (size_t)sz) {
            die("short read");
        }
        fclose(f);

        if (corrupt) {
            if (corrupt_signature(img, (uint32_t)sz) != 0) {
                die("no HDR_SIGNATURE TLV found in the image header");
            }
            printf("wbmtd: corrupted the HDR_SIGNATURE TLV (%ld bytes "
                "image)\n", sz);
        }

        /* Erase the whole UPDATE partition first: NOR flash can only
         * clear bits. The image goes at the start of the partition. */
        if (mtd_extflash_init() != 0) {
            die("MTD backend init failed");
        }
        if (ext_flash_erase(WOLFBOOT_PARTITION_UPDATE_ADDRESS, upd_size) != 0) {
            die("erasing the UPDATE partition failed");
        }
        printf("wbmtd: erased UPDATE partition (%u bytes)\n", upd_size);
        /* ext_flash_write() returns the byte count on success, not 0,
         * so check for < 0. */
        if (ext_flash_write(WOLFBOOT_PARTITION_UPDATE_ADDRESS, img,
                (int)sz) < 0) {
            die("writing the image into UPDATE failed");
        }
        printf("wbmtd: wrote %ld bytes at 0x%x\n", sz,
            (unsigned)WOLFBOOT_PARTITION_UPDATE_ADDRESS);

        /* Set the UPDATE trailer to UPDATING (plus the magic). */
        wolfBoot_update_trigger();
        printf("wbmtd: UPDATE partition state set to UPDATING "
            "(wolfBoot_update_trigger)\n");
        return 0;
    }
    fprintf(stderr, "unknown command '%s'\n", argv[1]);
    return 2;
}
