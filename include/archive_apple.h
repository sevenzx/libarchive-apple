#ifndef LIBARCHIVE_APPLE_H
#define LIBARCHIVE_APPLE_H
#include <archive.h>
#ifdef __cplusplus
extern "C" {
#endif
#define ARCHIVE_APPLE_SHIM_ABI 1
/* Each returned object is owned by the caller and released with libarchive. */
struct archive *archive_apple_read_new_utf8(void);
struct archive *archive_apple_write_new_utf8(void);
int archive_apple_shim_abi(void);
#ifdef __cplusplus
}
#endif
#endif

