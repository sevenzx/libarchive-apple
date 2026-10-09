/* Compile with the exact libarchive source and config used for each slice. */
#include "archive_platform.h"
#include "archive_private.h"
#include "archive_apple.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>

static struct archive *archive_new_utf8(unsigned magic,
    struct archive *(*create)(void), int (*release)(struct archive *)) {
    if (archive_version_number() != ARCHIVE_VERSION_NUMBER) {
        errno = ENOTSUP;
        return NULL;
    }
    struct archive *reader = create();
    if (reader == NULL) { errno = ENOMEM; return NULL; }
    if (reader->magic != magic || reader->state != ARCHIVE_STATE_NEW ||
        reader->current_code != NULL || reader->sconv != NULL) {
        release(reader);
        errno = ENOTSUP;
        return NULL;
    }
    /* A fresh object's native charset is UTF-8. Its normal release frees this
     * allocation. Do not access locale files or mutate the process locale. */
    reader->current_code = strdup("UTF-8");
    if (reader->current_code == NULL) {
        release(reader);
        errno = ENOMEM;
        return NULL;
    }
    return reader;
}

struct archive *archive_apple_read_new_utf8(void) {
    return archive_new_utf8(ARCHIVE_READ_MAGIC, archive_read_new, archive_read_free);
}
struct archive *archive_apple_write_new_utf8(void) {
    return archive_new_utf8(ARCHIVE_WRITE_MAGIC, archive_write_new, archive_write_free);
}
int archive_apple_shim_abi(void) {
    return ARCHIVE_APPLE_SHIM_ABI;
}

