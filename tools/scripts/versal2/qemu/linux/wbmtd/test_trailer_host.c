/* test_trailer_host.c - Host unit test for the wbmtd /dev/mtd backend.
 *
 * Plan item Q5 "Local Linux test (not CI)" (PR 1). The Linux-side update
 * tool (wbmtd) reuses libwolfboot's own partition-trailer operations
 * (wolfBoot_update_trigger() / wolfBoot_success()) through a small
 * ext_flash_* backend. On the target that backend is /dev/mtdN; on the
 * host it is a regular file with NOR semantics (erase = 0xFF, program =
 * AND). This test drives the REAL libwolfboot trailer code against the
 * file backend and checks the exact bytes it writes, so the guest tool is
 * guaranteed to set the trailer exactly as wolfBoot's own firmware does.
 *
 * Checked (little-endian; WOLFBOOT_MAGIC_TRAIL = 0x544F4F42 = "BOOT"):
 *   UPDATE trailer after wolfBoot_update_trigger():
 *       [END-5]  = IMG_STATE_UPDATING (0x70)
 *       [END-4..END-1] = 42 4F 4F 54
 *   BOOT trailer after wolfBoot_success():
 *       [END-5]  = IMG_STATE_SUCCESS (0x00)
 *       [END-4..END-1] = 42 4F 4F 54
 *   and wolfBoot_get_partition_state() reads them back.
 *
 * Build: make -C .../wbmtd test-host  (see the Makefile there).
 */
/* target.h (wbmtd_target.h) must come FIRST: image.h evaluates
 * #ifdef PART_UPDATE_EXT when it is processed (see wbmtd.c). */
#include "target.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include "image.h"
#include "wolfboot/wolfboot.h"

#include "libwolfboot.c"
#include "mtd_backend.c"

static int failures = 0;

#define CHECK(cond, msg) do { \
    if (cond) { printf("  [ OK ] %s\n", msg); } \
    else      { printf("  [FAIL] %s\n", msg); failures++; } \
} while (0)

static uint8_t fbyte(uint32_t off)
{
    uint8_t b;
    if (ext_flash_read(off, &b, 1) != 1)
        return 0xEE;
    return b;
}

int main(void)
{
    /* Isolated scratch flash file for the test. */
    setenv("WBMTD_FILE", "/tmp/wbmtd-trailer-test.bin", 1);
    remove("/tmp/wbmtd-trailer-test.bin");

    printf("wbmtd trailer host test (libwolfboot + file NOR backend)\n");
    if (mtd_extflash_init() != 0)
    {
        printf("  [FAIL] backend init\n");
        return 1;
    }

    uint32_t upd_end = WOLFBOOT_PARTITION_UPDATE_ADDRESS +
                       WOLFBOOT_PARTITION_UPDATE_SIZE;
    uint32_t boot_end = WOLFBOOT_PARTITION_BOOT_ADDRESS +
                        WOLFBOOT_PARTITION_SIZE;

    /* --- wolfBoot_update_trigger(): UPDATE trailer -> UPDATING -------- */
    printf("update_trigger (UPDATE partition):\n");
    wolfBoot_update_trigger();
    CHECK(fbyte(upd_end - 5) == IMG_STATE_UPDATING,
          "UPDATE [END-5] == IMG_STATE_UPDATING (0x70)");
    CHECK(fbyte(upd_end - 4) == 0x42 && fbyte(upd_end - 3) == 0x4F &&
          fbyte(upd_end - 2) == 0x4F && fbyte(upd_end - 1) == 0x54,
          "UPDATE [END-4..END-1] == 42 4F 4F 54 (WOLFBOOT_MAGIC_TRAIL)");
    {
        uint8_t st = 0;
        CHECK(wolfBoot_get_partition_state(PART_UPDATE, &st) == 0 &&
              st == IMG_STATE_UPDATING,
              "wolfBoot_get_partition_state(UPDATE) == UPDATING");
    }

    /* --- wolfBoot_success(): BOOT trailer -> SUCCESS ------------------ */
    printf("success (BOOT partition):\n");
    wolfBoot_success();
    CHECK(fbyte(boot_end - 5) == IMG_STATE_SUCCESS,
          "BOOT [END-5] == IMG_STATE_SUCCESS (0x00)");
    CHECK(fbyte(boot_end - 4) == 0x42 && fbyte(boot_end - 3) == 0x4F &&
          fbyte(boot_end - 2) == 0x4F && fbyte(boot_end - 1) == 0x54,
          "BOOT [END-4..END-1] == 42 4F 4F 54 (WOLFBOOT_MAGIC_TRAIL)");
    {
        uint8_t st = 0;
        CHECK(wolfBoot_get_partition_state(PART_BOOT, &st) == 0 &&
              st == IMG_STATE_SUCCESS,
              "wolfBoot_get_partition_state(BOOT) == SUCCESS");
    }

    /* --- untouched partition has no valid trailer --------------------- */
    {
        uint8_t st = 0;
        int rc = wolfBoot_get_partition_state(PART_SWAP, &st);
        /* SWAP is not a trailer partition; just ensure no crash. */
        (void)rc; (void)st;
        printf("  [info] SWAP state query rc=%d (expected non-zero or 0)\n", rc);
    }

    remove("/tmp/wbmtd-trailer-test.bin");

    printf("=========================================\n");
    if (failures == 0)
        printf(" trailer host test: PASS\n");
    else
        printf(" trailer host test: FAIL (%d)\n", failures);
    printf("=========================================\n");
    return (failures == 0) ? 0 : 1;
}
