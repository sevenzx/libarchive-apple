#include "archive_apple.h"
#include <archive_entry.h>
#include <assert.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *name = "字幕.简繁英粵.srt";
static const char *payload = "1\n00:00:01,000 --> 00:00:03,000\n字幕测试\n";
static void check_ok(struct archive *object, int status, const char *operation) {
    if (status != ARCHIVE_OK) {
        fprintf(stderr, "Archive smoke test failed: operation=%s status=%d errno=%d\n",
            operation, status, archive_errno(object));
        exit(1);
    }
}
#define require_ok(object, status) check_ok(object, status, #status)
static struct archive *reader(void) {
    struct archive *r = archive_apple_read_new_utf8();
    assert(r != NULL);
    require_ok(r, archive_read_support_filter_none(r));
    require_ok(r, archive_read_support_format_zip_seekable(r));
    require_ok(r, archive_read_support_format_rar(r));
    require_ok(r, archive_read_support_format_rar5(r));
    require_ok(r, archive_read_support_format_7zip(r));
    return r;
}
static void inspect(void *bytes, size_t count, int check_name) {
    struct archive *r = reader();
    require_ok(r, archive_read_open_memory(r, bytes, count));
    struct archive_entry *entry;
    size_t entries = 0, total = 0;
    int status;
    while ((status = archive_read_next_header(r, &entry)) == ARCHIVE_OK) {
        if (check_name) assert(strcmp(archive_entry_pathname(entry), name) == 0);
        char buffer[8192];
        la_ssize_t got;
        size_t offset = 0;
        while ((got = archive_read_data(r, buffer, sizeof(buffer))) > 0) {
            if (check_name) {
                assert(offset + (size_t)got <= strlen(payload));
                assert(memcmp(buffer, payload + offset, (size_t)got) == 0);
            }
            offset += (size_t)got;
            total += (size_t)got;
        }
        assert(got == 0);
        if (check_name) assert(offset == strlen(payload));
        entries++;
    }
    assert(status == ARCHIVE_EOF && entries > 0 && total > 0);
    if (check_name) assert(entries == 1);
    require_ok(r, archive_read_close(r));
    require_ok(r, archive_read_free(r));
    assert(strcmp(setlocale(LC_CTYPE, NULL), "C") == 0);
}
static void roundtrip(int seven_zip, const char *compression) {
    unsigned char bytes[65536];
    size_t count = 0;
    struct archive *w = archive_apple_write_new_utf8();
    assert(w != NULL);
    require_ok(w, seven_zip ? archive_write_set_format_7zip(w) : archive_write_set_format_zip(w));
    if (compression) require_ok(w, archive_write_set_options(w, compression));
    if (!seven_zip) require_ok(w, archive_write_set_format_option(w, "zip", "hdrcharset", "UTF-8"));
    require_ok(w, archive_write_open_memory(w, bytes, sizeof(bytes), &count));
    struct archive_entry *entry = archive_entry_new();
    assert(entry != NULL);
    archive_entry_set_pathname(entry, name);
    archive_entry_set_filetype(entry, AE_IFREG);
    archive_entry_set_perm(entry, 0644);
    archive_entry_set_size(entry, (la_int64_t)strlen(payload));
    require_ok(w, archive_write_header(w, entry));
    assert(archive_write_data(w, payload, strlen(payload)) == (la_ssize_t)strlen(payload));
    archive_entry_free(entry);
    require_ok(w, archive_write_close(w));
    require_ok(w, archive_write_free(w));
    inspect(bytes, count, 1);
    if (!seven_zip) {
        /* Corrupt the central-directory CRC and require rejection. */
        size_t central = 0;
        for (size_t i = 0; i + 46 < count; i++) {
            if (memcmp(bytes + i, "PK\001\002", 4) == 0) { central = i; break; }
        }
        assert(central > 0);
        bytes[central + 16] ^= 1;
        struct archive *r = reader();
        require_ok(r, archive_read_open_memory(r, bytes, count));
        struct archive_entry *read_entry;
        int header = archive_read_next_header(r, &read_entry);
        int rejected = header != ARCHIVE_OK;
        if (!rejected) {
            char buffer[8192];
            la_ssize_t got;
            while ((got = archive_read_data(r, buffer, sizeof(buffer))) > 0) {}
            rejected = got < 0;
        }
        assert(rejected);
        archive_read_free(r);
    }
}
int main(int argc, char **argv) {
    assert(setlocale(LC_ALL, "C") != NULL);
    assert(archive_apple_shim_abi() == ARCHIVE_APPLE_SHIM_ABI);
    roundtrip(0, "zip:compression=store");
    roundtrip(0, "zip:compression=deflate");
    roundtrip(1, NULL);
    for (int i = 1; i < argc; i++) {
        FILE *file = fopen(argv[i], "rb");
        assert(file != NULL && fseek(file, 0, SEEK_END) == 0);
        long length = ftell(file);
        assert(length > 0 && length < 16 * 1024 * 1024);
        rewind(file);
        void *bytes = malloc((size_t)length);
        assert(bytes != NULL && fread(bytes, 1, (size_t)length, file) == (size_t)length);
        fclose(file);
        inspect(bytes, (size_t)length, 0);
        free(bytes);
    }
    printf("Archive smoke tests passed (libarchive=%d shimABI=%d).\n",
        archive_version_number(), archive_apple_shim_abi());
    return 0;
}
