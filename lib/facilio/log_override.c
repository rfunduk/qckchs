// Overrides facil.io's weak FIO_LOG2STDERR symbol.
// Must be compiled separately — cannot include fio.h (it has an inline definition).

#include <stdio.h>
#include <stdarg.h>
#include <string.h>

// level: 0=debug, 1=info, 2=warning, 3=error, 4=fatal
typedef void (*fiow_log_fn)(int level, const char *msg, unsigned int len);
static fiow_log_fn log_callback = NULL;

void fiow_set_log(fiow_log_fn fn) {
    log_callback = fn;
}

void fiow_log_msg(int level, const char *msg, unsigned int len) {
    if (log_callback) {
        log_callback(level, msg, len);
    }
}

void FIO_LOG2STDERR(const char *format, ...) {
    char buf[2048];
    va_list argv;
    va_start(argv, format);
    int len = vsnprintf(buf, sizeof(buf), format, argv);
    va_end(argv);

    if (len <= 0) return;
    if (buf[len - 1] == '\n') len--;

    if (!log_callback) {
        buf[len] = '\n';
        fwrite(buf, len + 1, 1, stderr);
        return;
    }

    // Strip facil.io prefixes and map to level
    const char *msg = buf;
    int level = 1; // default: info

    if (len > 6 && memcmp(buf, "INFO: ", 6) == 0) {
        msg += 6; len -= 6; level = 1;
    } else if (len > 9 && memcmp(buf, "WARNING: ", 9) == 0) {
        msg += 9; len -= 9; level = 2;
    } else if (len > 7 && memcmp(buf, "ERROR: ", 7) == 0) {
        msg += 7; len -= 7; level = 3;
    } else if (len > 7 && memcmp(buf, "FATAL: ", 7) == 0) {
        msg += 7; len -= 7; level = 4;
    } else if (len > 6 && memcmp(buf, "DEBUG ", 6) == 0) {
        msg += 6; len -= 6; level = 0;
    }

    log_callback(level, msg, (unsigned int)len);
}
