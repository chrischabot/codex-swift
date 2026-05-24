#ifndef CODEXKIT_CPTY_H
#define CODEXKIT_CPTY_H

#include <stddef.h>

/* Open a PTY master (posix_openpt + grantpt + unlockpt) and write the
 * NUL-terminated slave device path into `slave` (capacity `len`).
 * Returns the master fd (>= 0) on success, or -1 on failure. */
int cpty_open_master(char *slave, size_t len);

#endif /* CODEXKIT_CPTY_H */