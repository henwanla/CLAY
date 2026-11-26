#ifndef CLAY_WINDOWS_RUNTIME_H
#define CLAY_WINDOWS_RUNTIME_H

#include <stddef.h>
#include <stdint.h>

typedef struct clay_win_session clay_win_session;

enum {
    CLAY_WIN_OK = 0,
    CLAY_WIN_INTERRUPTED = 1,
    CLAY_WIN_FILES = 2,
    CLAY_WIN_DIGEST = 3,
    CLAY_WIN_PORTS = 4,
    CLAY_WIN_LAUNCH = 5,
    CLAY_WIN_EXITED = 6,
    CLAY_WIN_LISTENERS = 7,
    CLAY_WIN_OUTPUT = 8,
    CLAY_WIN_SIGNALS = 9
};

int32_t clay_win_prepare(const uint16_t *source, const uint8_t fingerprint[32],
                         uint16_t requested_proxy, uint16_t requested_control,
                         uint16_t *proxy, uint16_t *control, uint8_t random[32],
                         clay_win_session **session);
int32_t clay_win_run(clay_win_session *session, const uint8_t *config, size_t length);
// Also terminates the process tree and removes the private runtime files.
int32_t clay_win_stop(clay_win_session *session);

#endif
