#ifndef CODEXKIT_SQLITE_VEC_SHIM_H
#define CODEXKIT_SQLITE_VEC_SHIM_H

#include <sqlite3.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Real symbol from sqlite-vec amalgamation. */
int sqlite3_vec_init(sqlite3 *db, char **pzErrMsg,
                     const struct sqlite3_api_routines *pApi);

/* Stable bridge used by MemoryStore. Returns SQLITE_OK on success.
   When the real sqlite-vec.c amalgamation is dropped into this target's
   Sources/ directory, this calls sqlite3_auto_extension(sqlite3_vec_init)
   so the extension is registered for every subsequent connection (the
   pattern documented by sqlite-vec upstream). When the amalgamation is
   absent the helper still returns SQLITE_OK and registers nothing — the
   Swift layer detects the missing vec0 virtual table on bring-up and falls
   back to its in-process cosine path. */
int codex_register_sqlite_vec(void);

/* Per-connection initialisation. Apple platforms deprecated process-wide
   `sqlite3_auto_extension`, so the canonical pattern there is to call the
   extension init directly on each open `sqlite3*`. When the amalgamation
   is absent this is a no-op returning SQLITE_OK. */
int codex_init_sqlite_vec_for(sqlite3 *db);

/* Reports whether the real amalgamation is linked. The Swift layer uses
   this for diagnostics and for VERIFIED.md. */
int codex_sqlite_vec_available(void);

#ifdef __cplusplus
}
#endif

#endif /* CODEXKIT_SQLITE_VEC_SHIM_H */
