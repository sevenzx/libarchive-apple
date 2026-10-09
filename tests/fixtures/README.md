# Archive fixtures

`rar4-compressed.rar` and `rar5-compressed.rar` are decoded upstream
libarchive test fixtures from tag v3.8.7:

- `libarchive/test/test_read_format_rar_compress_normal.rar.uu`
- `libarchive/test/test_read_format_rar5_compressed.rar.uu`

Source: https://github.com/libarchive/libarchive/tree/v3.8.7/libarchive/test

`LICENSE.txt` preserves their upstream notices. ZIP and 7z smoke data are
synthetic and generated in memory by `tests/smoke.c`. Fixtures are decoded
as data and never executed.

