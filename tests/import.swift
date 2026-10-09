import libarchive

precondition(archive_apple_shim_abi() == ARCHIVE_APPLE_SHIM_ABI)
guard let reader = archive_apple_read_new_utf8(),
      let writer = archive_apple_write_new_utf8() else {
    fatalError("UTF-8 constructors unavailable")
}
precondition(archive_read_free(reader) == ARCHIVE_OK)
precondition(archive_write_free(writer) == ARCHIVE_OK)
print("Swift module and UTF-8 constructors verified.")

