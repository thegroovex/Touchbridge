#include "tb_sdk.h"
#include <Availability.h>
#include <AvailabilityMacros.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <string.h>

int tb_sdk_compile_max_allowed(void) { return __MAC_OS_X_VERSION_MAX_ALLOWED; }
int tb_sdk_compile_min_required(void) { return __MAC_OS_X_VERSION_MIN_REQUIRED; }

int tb_main_build_version(uint32_t *minos, uint32_t *sdk) {
    const struct mach_header *h = _dyld_get_image_header(0);
    if (!h) return 0;
    const uint8_t *p;
    uint32_t ncmds = h->ncmds;
    if (h->magic == MH_MAGIC_64) p = (const uint8_t *)h + sizeof(struct mach_header_64);
    else if (h->magic == MH_MAGIC) p = (const uint8_t *)h + sizeof(struct mach_header);
    else return 0;
    for (uint32_t i = 0; i < ncmds; i++) {
        struct load_command lc;
        memcpy(&lc, p, sizeof lc);
        if (lc.cmd == LC_BUILD_VERSION) {
            struct build_version_command b;
            memcpy(&b, p, sizeof b);
            if (minos) *minos = b.minos;
            if (sdk) *sdk = b.sdk;
            return 1;
        }
        if (lc.cmd == LC_VERSION_MIN_MACOSX) {
            struct version_min_command v;
            memcpy(&v, p, sizeof v);
            if (minos) *minos = v.version;
            if (sdk) *sdk = v.sdk;
            return 1;
        }
        if (lc.cmdsize == 0) break;
        p += lc.cmdsize;
    }
    return 0;
}
