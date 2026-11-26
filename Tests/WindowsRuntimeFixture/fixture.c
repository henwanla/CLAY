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

static void respond(SOCKET fd) {
    SOCKET client = accept(fd, NULL, NULL);
    if (client == INVALID_SOCKET) return;
    const char response[] = "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nfixture";
    char request[4096];
    DWORD timeout = 2000;
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, (char *)&timeout, sizeof(timeout));
    if (recv(client, request, sizeof(request), 0) > 0) send(client, response, sizeof(response) - 1, 0);
    shutdown(client, SD_SEND);
    closesocket(client);
}

int wmain(int argc, wchar_t **argv) {
    WSADATA data;
    if (WSAStartup(MAKEWORD(2, 2), &data)) return 11;
    if (argc == 3 && !wcscmp(argv[1], L"foreign-listener")) {
        SOCKET child = listener(INADDR_LOOPBACK, (unsigned short)wcstoul(argv[2], NULL, 10));
        if (child == INVALID_SOCKET) return 12;
        for (;;) respond(child);
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
        if (FD_ISSET(proxy_fd, &readable)) respond(proxy_fd);
        if (control_fd != INVALID_SOCKET && FD_ISSET(control_fd, &readable)) respond(control_fd);
    }
}
