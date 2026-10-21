#ifndef TB_SDK_H
#define TB_SDK_H
#include <stdint.h>
/// macOS SDK the binary was compiled against (__MAC_OS_X_VERSION_MAX_ALLOWED, e.g. 270000 for SDK 27.0)
int tb_sdk_compile_max_allowed(void);
/// Deployment target used at compile time (__MAC_OS_X_VERSION_MIN_REQUIRED, e.g. 120000)
int tb_sdk_compile_min_required(void);
/// Reads LC_BUILD_VERSION (or LC_VERSION_MIN_MACOSX) of the main executable. Versions are nibble-encoded
/// (xxxx.yy.zz -> major << 16 | minor << 8 | patch). This is what AppKit's linked-on-or-after checks use.
/// Returns 1 when found, 0 otherwise.
int tb_main_build_version(uint32_t *minos, uint32_t *sdk);
#endif
