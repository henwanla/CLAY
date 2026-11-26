#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

static SOCKET listener(unsigned long address, unsigned short port) {
    struct sockaddr_in local = {0};
    int exclusive = 1;
    local.sin_family = AF_INET;
    local.sin_addr.s_addr = htonl(address);
    local.sin_port = htons(port);
    SOCKET fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd == INVALID_SOCKET || setsockopt(fd, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (char *)&exclusive, sizeof(exclusive)) ||
        bind(fd, (struct sockaddr *)&local, sizeof(local)) || listen(fd, 8)) return INVALID_SOCKET;
    return fd;
}

typedef struct fixture_state {
    char secret[65], nodes[2][42], mode[8];
    unsigned selected;
    int ignore_direct;
    int drain_failures, pending, readback;
} fixture_state;

static void respond(SOCKET fd, fixture_state *state) {
    SOCKET client = accept(fd, NULL, NULL);
    if (client == INVALID_SOCKET) return;
    char request[4096] = {0}, body[128] = "fixture";
    const char *status = "200 OK";
    DWORD timeout = 2000;
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, (char *)&timeout, sizeof(timeout));
    size_t used = 0;
    char *payload = NULL;
    while (used < sizeof(request) - 1) {
        int read = recv(client, request + used, (int)(sizeof(request) - 1 - used), 0);
        if (read <= 0) goto done;
        used += (size_t)read;
        request[used] = 0;
        char *end = strstr(request, "\r\n\r\n");
        if (!end) continue;
        payload = end + 4;
        size_t length = 0;
        for (const char *line = strstr(request, "\r\n"); line && line < end; line = strstr(line + 2, "\r\n")) {
            if (!_strnicmp(line + 2, "Content-Length:", 15)) length = strtoul(line + 17, NULL, 10);
        }
        if (length > 512) goto done;
        if (used >= (size_t)(payload - request) + length) break;
    }
    if (!payload) goto done;
    if (state) {
        char expected[96];
        sprintf_s(expected, sizeof(expected), "Authorization: Bearer %s\r\n", state->secret);
        int allowed = 0;
        for (const char *line = strstr(request, "\r\n"); line && line < payload - 4; line = strstr(line + 2, "\r\n")) {
            if (!_strnicmp(line + 2, expected, 15) && !strncmp(line + 17, expected + 15, strlen(expected) - 15)) allowed = 1;
        }
        body[0] = 0;
        if (!allowed) status = "401 Unauthorized";
        else if (!strncmp(request, "GET /configs ", 13)) {
            if (state->pending == 1) state->readback = 1;
            sprintf_s(body, sizeof(body), "{\"mode\":\"%s\"}", state->mode);
        } else if (!strncmp(request, "GET /proxies/CLAY ", 18)) {
            if (state->pending == 2) state->readback = 1;
            sprintf_s(body, sizeof(body), "{\"now\":\"%s\"}", state->nodes[state->selected]);
        } else if (!strncmp(request, "PATCH /configs ", 15)) {
            status = "204 No Content";
            if (!strcmp(payload, "{\"mode\":\"rule\"}")) strcpy_s(state->mode, sizeof(state->mode), "rule");
            else if (!strcmp(payload, "{\"mode\":\"global\"}")) strcpy_s(state->mode, sizeof(state->mode), "global");
            else if (!strcmp(payload, "{\"mode\":\"direct\"}")) {
                if (!state->ignore_direct) strcpy_s(state->mode, sizeof(state->mode), "direct");
            } else status = "400 Bad Request";
            state->pending = 1;
            state->readback = 0;
        } else if (!strncmp(request, "PUT /proxies/CLAY ", 18)) {
            status = "400 Bad Request";
            for (unsigned i = 0; i < _countof(state->nodes) && state->nodes[i][0]; ++i) {
                sprintf_s(expected, sizeof(expected), "{\"name\":\"%s\"}", state->nodes[i]);
                if (!strcmp(payload, expected)) {
                    if (state->selected == i) break;
                    state->selected = i; state->pending = 2; state->readback = 0;
                    status = "204 No Content";
                    break;
                }
            }
        } else if (!strncmp(request, "DELETE /connections ", sizeof("DELETE /connections ") - 1)) {
            if (!state->pending || !state->readback) status = "409 Conflict";
            else if (state->drain_failures > 0) { --state->drain_failures; status = "503 Service Unavailable"; }
            else { state->pending = 0; state->readback = 0; status = "204 No Content"; }
        } else status = "404 Not Found";
    }
    char response[256];
    int length = sprintf_s(response, sizeof(response), "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s",
                           status, strlen(body), body);
    if (length > 0) send(client, response, length, 0);
done:
    shutdown(client, SD_SEND);
    closesocket(client);
}

int wmain(int argc, wchar_t **argv) {
    WSADATA data;
    if (WSAStartup(MAKEWORD(2, 2), &data)) return 11;
    if (argc == 3 && !wcscmp(argv[1], L"foreign-listener")) {
        SOCKET child = listener(INADDR_LOOPBACK, (unsigned short)wcstoul(argv[2], NULL, 10));
        if (child == INVALID_SOCKET) return 12;
        for (;;) respond(child, NULL);
    }
    if (argc != 5 || wcscmp(argv[1], L"-d") || wcscmp(argv[3], L"-f") ||
        GetEnvironmentVariableW(L"CLAY_WINDOWS_TEST_MARKER", NULL, 0)) return 13;
    FILE *config;
    if (_wfopen_s(&config, argv[4], L"rb") != 0) return 14;
    char json[16384];
    size_t size = fread(json, 1, sizeof(json) - 1, config);
    fclose(config);
    json[size] = '\0';
    char *mixed = strstr(json, "\"mixed-port\":"), *api = strstr(json, "\"external-controller\":\"127.0.0.1:");
    if (!mixed || !api || !strstr(json, "DOMAIN-SUFFIX,example.invalid,DIRECT") || !strstr(json, "\"mode\":\"global\"")) return 15;
    if (strstr(json, "exit-only-dummy")) return 16;
    unsigned short proxy = (unsigned short)strtoul(mixed + strlen("\"mixed-port\":"), NULL, 10);
    unsigned short control = (unsigned short)strtoul(api + strlen("\"external-controller\":\"127.0.0.1:"), NULL, 10);
    fixture_state state = {0};
    const char *secret = strstr(json, "\"secret\":\"");
    if (!secret) return 22;
    memcpy(state.secret, secret + strlen("\"secret\":\""), 64);
    const char *node = json;
    for (unsigned i = 0; i < _countof(state.nodes); ++i) {
        node = strstr(node, "\"name\":\"node-");
        if (!node) break;
        node += strlen("\"name\":\"");
        memcpy(state.nodes[i], node, 41);
    }
    if (!state.nodes[0][0]) return 23;
    strcpy_s(state.mode, sizeof(state.mode), "global");
    state.ignore_direct = strstr(json, "ignore-update-dummy") != NULL;
    state.drain_failures = strstr(json, "retry-drain-dummy") != NULL ? 2 : 0;
    // Any child output (including the synthetic test credential) must be dropped.
    fprintf(stderr, "fixture-child-output: %s\n", json);
    fflush(stderr);
    SOCKET proxy_fd = listener(INADDR_LOOPBACK, proxy), control_fd = INVALID_SOCKET;
    if (proxy_fd == INVALID_SOCKET) return 17;
    if (strstr(json, "split-owner-dummy")) {
        wchar_t args[2 * MAX_PATH];
        if (_snwprintf_s(args, _countof(args), _TRUNCATE, L"\"%ls\" foreign-listener %u", argv[0], (unsigned)control) < 0) return 18;
        STARTUPINFOW startup = {0};
        PROCESS_INFORMATION child = {0};
        startup.cb = sizeof(startup);
        if (!CreateProcessW(argv[0], args, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &startup, &child)) return 19;
        CloseHandle(child.hProcess);
        CloseHandle(child.hThread);
    } else {
        control_fd = listener(strstr(json, "wildcard-dummy") ? INADDR_ANY : INADDR_LOOPBACK, control);
        if (control_fd == INVALID_SOCKET) return 20;
    }
    for (;;) {
        fd_set readable;
        FD_ZERO(&readable);
        FD_SET(proxy_fd, &readable);
        if (control_fd != INVALID_SOCKET) FD_SET(control_fd, &readable);
        if (select(0, &readable, NULL, NULL, NULL) == SOCKET_ERROR) return 21;
        if (FD_ISSET(proxy_fd, &readable)) respond(proxy_fd, NULL);
        if (control_fd != INVALID_SOCKET && FD_ISSET(control_fd, &readable)) respond(control_fd, &state);
    }
}
