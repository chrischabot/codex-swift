/*
 * CodexKit CSQLiteVec — auto-extension registration bridge.
 *
 * The real `sqlite-vec.c` amalgamation (v0.1.9) defines `sqlite3_vec_init`.
 * Dropping that amalgamation into this target's source directory (per the
 * upstream static-link pattern, compiled with `-DSQLITE_CORE` via Package.swift
 * cSettings) wires the brute-force `vec0` virtual table into every SQLite
 * connection.
 *
 * When the amalgamation is absent we provide a weak fallback `sqlite3_vec_init`
 * so the package still links cleanly. The fallback is a no-op; the Swift layer
 * detects this via `codex_sqlite_vec_available()` and switches MemoryStore to
 * its in-process cosine search path (which is correctness-equivalent at
 * 80k–200k chunks, just slower than the brute-force vec0 inner loop).
 */

#include "sqlite_vec_shim.h"
#include <stddef.h>

#ifndef CODEX_HAS_SQLITE_VEC
#  if defined(__has_include)
#    if __has_include("sqlite-vec.h")
#      define CODEX_HAS_SQLITE_VEC 1
#    else
#      define CODEX_HAS_SQLITE_VEC 0
#    endif
#  else
#    define CODEX_HAS_SQLITE_VEC 0
#  endif
#endif

#if !CODEX_HAS_SQLITE_VEC
/* Stub: matches the sqlite3_vec_init signature so it can still be passed
   to sqlite3_auto_extension if a caller insists, but registers nothing. */
int sqlite3_vec_init(sqlite3 *db,
                     char **pzErrMsg,
                     const struct sqlite3_api_routines *pApi) {
    (void)db; (void)pzErrMsg; (void)pApi;
    return SQLITE_OK;
}
#endif

int codex_register_sqlite_vec(void) {
#if CODEX_HAS_SQLITE_VEC && !defined(__APPLE__)
    /* `sqlite3_auto_extension` expects a function pointer with no specific
       signature; cast through `void(*)(void)` as documented. */
    return sqlite3_auto_extension((void (*)(void))sqlite3_vec_init);
#else
    /* On Apple platforms `sqlite3_auto_extension` is deprecated since macOS
       10.10 — process-global auto extensions are unsupported. Use the
       per-connection `codex_init_sqlite_vec_for` entry instead. */
    return SQLITE_OK;
#endif
}

int codex_init_sqlite_vec_for(sqlite3 *db) {
#if CODEX_HAS_SQLITE_VEC
    char *errmsg = NULL;
    int rc = sqlite3_vec_init(db, &errmsg, NULL);
    if (errmsg) sqlite3_free(errmsg);
    return rc;
#else
    (void)db;
    return SQLITE_OK;
#endif
}

int codex_sqlite_vec_available(void) {
#if CODEX_HAS_SQLITE_VEC
    return 1;
#else
    return 0;
#endif
}
