#define _GNU_SOURCE
#define _XOPEN_SOURCE 600

#include "cpty.h"

#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

int cpty_open_master(char *slave, size_t len) {
    if (slave == NULL || len == 0) {
        return -1;
    }
    int m = posix_openpt(O_RDWR | O_NOCTTY);
    if (m < 0) {
        return -1;
    }
    if (grantpt(m) != 0) {
        close(m);
        return -1;
    }
    if (unlockpt(m) != 0) {
        close(m);
        return -1;
    }
#if defined(__linux__)
    if (ptsname_r(m, slave, len) != 0) {
        close(m);
        return -1;
    }
#else
    {
        const char *n = ptsname(m);
        if (n == NULL) {
            close(m);
            return -1;
        }
        if (strlen(n) + 1 > len) {
            close(m);
            return -1;
        }
        strncpy(slave, n, len);
        slave[len - 1] = '\0';
    }
#endif
    return m;
}