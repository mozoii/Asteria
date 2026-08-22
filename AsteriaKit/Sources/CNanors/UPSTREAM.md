# nanors provenance

Source: <https://github.com/sleepybishop/nanors>

Pinned commit: `17fc7d61afb2fdd9a9aff38fbd7d4f2ff73a4508`

License: MIT, preserved verbatim in `LICENSE` and in the app's third-party notices.

The following files are byte-for-byte copies from the pinned upstream commit:

- `rs.c`
- upstream `rs.h`, stored as `include/rs.h` for SwiftPM
- `deps/obl/oblas_common.c`
- `deps/obl/oblas_common.h`
- `deps/obl/oblas_lite.c`
- `deps/obl/oblas_lite.h`
- `deps/obl/gf2_8_tables.h`
- `deps/obl/gf2_8_affine_mat.h`
- upstream `deps/obl/oblas_common.h`, also stored as `include/oblas_common.h` so the public
  SwiftPM module header resolves its unchanged include

Asteria does not patch those files. These files are Asteria-owned integration code:

- `AsteriaNanorsAdapter.c` selects the fixed Host audio parity matrix.
- `include/CNanors.h` declares the adapter and includes upstream `rs.h`.
- `include/module.modulemap` exposes the C target to Swift.

The replacement recovery tests contain independently calculated mathematical vectors. Verification
against sanitized FEC traffic captured from a lawfully operated Host remains required before the
commercial-use audit can mark Host compatibility complete.
