#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <winhttp.h>
#include <bcrypt.h>
#include <iphlpapi.h>
#include <sddl.h>
#include <shlobj.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "CLAYWindowsRuntime.h"

#define CONFIG_LIMIT (2U * 1024 * 1024)
#define BINARY_LIMIT (512ULL * 1024 * 1024)
#define LISTENER_TABLE_LIMIT (16U * 1024 * 1024)
#define PATH_CAP MAX_PATH

struct clay_win_session {
    WCHAR dir[PATH_CAP], exe[PATH_CAP], config[PATH_CAP];
    HANDLE verified, job, process;
    SOCKET proxy, control;
    uint16_t proxy_port, control_port;
    DWORD pid;
    BOOL winsock, console_handler;
};

// One foreground run per CLI process. Keep these events alive until exit:
// an already dispatched console callback can outlive handler removal.
static HANDLE stop_event, cleaned_event;
static BOOL WINAPI on_console(DWORD event) {
    if (event != CTRL_C_EVENT && event != CTRL_BREAK_EVENT && event != CTRL_CLOSE_EVENT &&
        event != CTRL_LOGOFF_EVENT && event != CTRL_SHUTDOWN_EVENT) return FALSE;
    SetEvent(stop_event);
    if (event != CTRL_C_EVENT && event != CTRL_BREAK_EVENT) WaitForSingleObject(cleaned_event, 4000);
    return TRUE;
}
static BOOL stopped(void) { return WaitForSingleObject(stop_event, 0) == WAIT_OBJECT_0; }

static BOOL join_path(WCHAR out[PATH_CAP], const WCHAR *dir, const WCHAR *name) {
    return _snwprintf_s(out, PATH_CAP, _TRUNCATE, L"%ls\\%ls", dir, name) >= 0;
}
static BOOL random_bytes(uint8_t *bytes, ULONG size) {
    return BCRYPT_SUCCESS(BCryptGenRandom(NULL, bytes, size, BCRYPT_USE_SYSTEM_PREFERRED_RNG));
}
static BOOL private_dir(WCHAR out[PATH_CAP]) {
    BOOL ok = FALSE;
    HANDLE token = NULL;
    TOKEN_USER *user = NULL;
    LPWSTR sid = NULL, root = NULL;
    PSECURITY_DESCRIPTOR descriptor = NULL;
    DWORD size = 0, flags = 0;
    WCHAR volume[PATH_CAP], rule[256], name[42], path[PATH_CAP];
    uint8_t entropy[16];
    SECURITY_ATTRIBUTES attrs = {sizeof(attrs), NULL, FALSE};
    const KNOWNFOLDERID local_app_data = {0xf1b32785, 0x6fba, 0x4fcf, {0x9d, 0x55, 0x7b, 0x8e, 0x7f, 0x15, 0x70, 0x91}};
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) goto done;
    GetTokenInformation(token, TokenUser, NULL, 0, &size);
    if (!size || size > 8192) goto done;
    user = malloc(size);
    if (!user || !GetTokenInformation(token, TokenUser, user, size, &size) ||
        !ConvertSidToStringSidW(user->User.Sid, &sid)) goto done;
    // An ACE has separate object and inherited-object fields before the SID.
    if (_snwprintf_s(rule, 256, _TRUNCATE, L"D:P(A;OICI;FA;;;%ls)", sid) < 0 ||
        !ConvertStringSecurityDescriptorToSecurityDescriptorW(rule, SDDL_REVISION_1, &descriptor, NULL)) goto done;
    if (FAILED(SHGetKnownFolderPath(&local_app_data, KF_FLAG_DEFAULT, NULL, &root)) || !root ||
        !GetVolumePathNameW(root, volume, PATH_CAP) || GetDriveTypeW(volume) != DRIVE_FIXED ||
        !GetVolumeInformationW(volume, NULL, 0, NULL, NULL, &flags, NULL, 0) || !(flags & FILE_PERSISTENT_ACLS)) goto done;
    if (!random_bytes(entropy, sizeof(entropy))) goto done;
    wcscpy_s(name, 42, L"clay-win-");
    const WCHAR hex[] = L"0123456789abcdef";
    for (size_t i = 0; i < sizeof(entropy); ++i) {
        name[9 + i * 2] = hex[entropy[i] >> 4];
        name[10 + i * 2] = hex[entropy[i] & 15];
    }
    name[41] = 0;
    attrs.lpSecurityDescriptor = descriptor;
    if (!join_path(path, root, name) || !CreateDirectoryW(path, &attrs)) goto done;
    wcscpy_s(out, PATH_CAP, path);
    ok = TRUE;
done:
    if (root) CoTaskMemFree(root);
    if (descriptor) LocalFree(descriptor);
    if (sid) LocalFree(sid);
    free(user);
    if (token) CloseHandle(token);
    return ok;
}

static BOOL regular_file(HANDLE file) {
    BY_HANDLE_FILE_INFORMATION info;
    return GetFileType(file) == FILE_TYPE_DISK && GetFileInformationByHandle(file, &info) &&
        !(info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DEVICE));
}
static int32_t stage(clay_win_session *s, const WCHAR *source, const uint8_t expected[32]) {
    HANDLE input = INVALID_HANDLE_VALUE, output = INVALID_HANDLE_VALUE;
    BCRYPT_ALG_HANDLE algorithm = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    uint8_t buffer[64 * 1024], digest[32], *object = NULL;
    DWORD object_size = 0, copied = 0, count, written;
    WCHAR absolute[PATH_CAP];
    LARGE_INTEGER file_size;
    uint64_t total = 0;
    int32_t status = CLAY_WIN_FILES;
    DWORD length = GetFullPathNameW(source, PATH_CAP, absolute, NULL);
    if (length < 4 || length >= PATH_CAP || absolute[1] != L':' || absolute[2] != L'\\' ||
        wcschr(absolute + 2, L':')) goto done;
    input = CreateFileW(absolute, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (input == INVALID_HANDLE_VALUE || !regular_file(input) || !GetFileSizeEx(input, &file_size) ||
        file_size.QuadPart <= 0 || (uint64_t)file_size.QuadPart > BINARY_LIMIT) goto done;
    output = CreateFileW(s->exe, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (output == INVALID_HANDLE_VALUE) goto done;
    for (;;) {
        if (stopped()) { status = CLAY_WIN_INTERRUPTED; goto done; }
        if (!ReadFile(input, buffer, sizeof(buffer), &count, NULL)) goto done;
        if (!count) break;
        total += count;
        if (total > BINARY_LIMIT || !WriteFile(output, buffer, count, &written, NULL) || written != count) goto done;
    }
    CloseHandle(output);
    output = INVALID_HANDLE_VALUE;
    // Verify the exact staged file under a handle that denies writes and deletion through execution.
    s->verified = CreateFileW(s->exe, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                             FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (s->verified == INVALID_HANDLE_VALUE || !regular_file(s->verified)) goto done;
    status = CLAY_WIN_DIGEST;
    if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0)) ||
        !BCRYPT_SUCCESS(BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, (PUCHAR)&object_size,
                                         sizeof(object_size), &copied, 0)) || !object_size || object_size > 65536) goto done;
    object = malloc(object_size);
    if (!object || !BCRYPT_SUCCESS(BCryptCreateHash(algorithm, &hash, object, object_size, NULL, 0, 0))) goto done;
    total = 0;
    for (;;) {
        if (stopped()) { status = CLAY_WIN_INTERRUPTED; goto done; }
        if (!ReadFile(s->verified, buffer, sizeof(buffer), &count, NULL)) goto done;
        if (!count) break;
        total += count;
        if (total > BINARY_LIMIT || !BCRYPT_SUCCESS(BCryptHashData(hash, buffer, count, 0))) goto done;
    }
    if (BCRYPT_SUCCESS(BCryptFinishHash(hash, digest, sizeof(digest), 0)) && !memcmp(digest, expected, sizeof(digest)))
        status = CLAY_WIN_OK;
done:
    if (hash) BCryptDestroyHash(hash);
    if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    free(object);
    if (output != INVALID_HANDLE_VALUE) CloseHandle(output);
    if (input != INVALID_HANDLE_VALUE) CloseHandle(input);
    return status;
}

static BOOL reserve(SOCKET *slot, uint16_t requested, uint16_t *number) {
    int exclusive = 1;
    struct sockaddr_in address = {0};
    int size = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(requested);
    *slot = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (*slot == INVALID_SOCKET || setsockopt(*slot, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char *)&exclusive, sizeof(exclusive)) ||
        bind(*slot, (const struct sockaddr *)&address, size) || getsockname(*slot, (struct sockaddr *)&address, &size)) return FALSE;
    *number = ntohs(address.sin_port);
    return *number != 0;
}
static void release_port(SOCKET *slot) {
    if (*slot != INVALID_SOCKET) closesocket(*slot);
    *slot = INVALID_SOCKET;
}

int32_t clay_win_prepare(const uint16_t *source, const uint8_t expected[32], uint16_t requested_proxy,
                         uint16_t requested_control, uint16_t *proxy, uint16_t *control, uint8_t random[32],
                         clay_win_session **session) {
    WSADATA winsock;
    int32_t status = CLAY_WIN_FILES;
    clay_win_session *s = calloc(1, sizeof(*s));
    if (!s) return status;
    s->verified = INVALID_HANDLE_VALUE;
    s->proxy = s->control = INVALID_SOCKET;
    if (stop_event || cleaned_event) { free(s); return CLAY_WIN_SIGNALS; }
    stop_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    cleaned_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!stop_event || !cleaned_event) { free(s); return CLAY_WIN_SIGNALS; }
    // The desktop host redirects input and launches without a console.
    if (GetConsoleCP() != 0) {
        if (!SetConsoleCtrlHandler(on_console, TRUE)) { free(s); return CLAY_WIN_SIGNALS; }
        s->console_handler = TRUE;
    }
    if (!private_dir(s->dir) || !join_path(s->exe, s->dir, L"mihomo.exe") ||
        !join_path(s->config, s->dir, L"clay.json") || !random_bytes(random, 32)) goto fail;
    status = stage(s, (const WCHAR *)source, expected);
    if (status != CLAY_WIN_OK) goto fail;
    status = CLAY_WIN_PORTS;
    if (WSAStartup(MAKEWORD(2, 2), &winsock)) goto fail;
    s->winsock = TRUE;
    // If only the controller is fixed, reserve it first so the ephemeral proxy cannot claim that port.
    if (requested_control && !requested_proxy && !reserve(&s->control, requested_control, &s->control_port)) goto fail;
    if (!reserve(&s->proxy, requested_proxy, &s->proxy_port) ||
        (s->control == INVALID_SOCKET && !reserve(&s->control, requested_control, &s->control_port))) goto fail;
    *proxy = s->proxy_port;
    *control = s->control_port;
    *session = s;
    return CLAY_WIN_OK;
fail:
    return clay_win_stop(s) == CLAY_WIN_OK ? status : CLAY_WIN_FILES;
}

static BOOL write_config(clay_win_session *s, const uint8_t *data, size_t length) {
    DWORD written = 0;
    if (!length || length > CONFIG_LIMIT) return FALSE;
    HANDLE file = CreateFileW(s->config, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return FALSE;
    BOOL ok = WriteFile(file, data, (DWORD)length, &written, NULL) && written == (DWORD)length;
    CloseHandle(file);
    return ok;
}

static BOOL launch(clay_win_session *s) {
    WCHAR args[3 * PATH_CAP + 32], env[9 * (PATH_CAP + 24)], root[PATH_CAP], path[PATH_CAP];
    UINT root_length = GetWindowsDirectoryW(root, PATH_CAP), system_length = GetSystemDirectoryW(path, PATH_CAP);
    if (!root_length || root_length >= PATH_CAP || !system_length || system_length >= PATH_CAP) return FALSE;
    if (_snwprintf_s(args, _countof(args), _TRUNCATE, L"\"%ls\" -d \"%ls\" -f \"%ls\"", s->exe, s->dir, s->config) < 0) return FALSE;
    const WCHAR *keys[] = {L"APPDATA", L"HOME", L"LOCALAPPDATA", L"PATH", L"SystemRoot", L"TEMP", L"TMP", L"USERPROFILE", L"WINDIR"};
    const WCHAR *values[] = {s->dir, s->dir, s->dir, path, root, s->dir, s->dir, s->dir, root};
    size_t offset = 0;
    for (size_t i = 0; i < _countof(keys); ++i) {
        int len = _snwprintf_s(env + offset, _countof(env) - offset, _TRUNCATE, L"%ls=%ls", keys[i], values[i]);
        if (len < 0) return FALSE;
        offset += (size_t)len + 1;
    }
    if (offset >= _countof(env)) return FALSE;
    env[offset] = 0;
    BOOL ok = FALSE, initialized = FALSE;
    HANDLE null = INVALID_HANDLE_VALUE;
    PROCESS_INFORMATION process = {0};
    STARTUPINFOEXW startup = {0};
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    SECURITY_ATTRIBUTES inherited = {sizeof(inherited), NULL, TRUE};
    SIZE_T attr_size = 0;
    s->job = CreateJobObjectW(NULL, NULL);
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!s->job || !SetInformationJobObject(s->job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) goto done;
    null = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                       &inherited, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (null == INVALID_HANDLE_VALUE) goto done;
    InitializeProcThreadAttributeList(NULL, 2, 0, &attr_size);
    if (!attr_size || attr_size > 65536) goto done;
    startup.lpAttributeList = malloc(attr_size);
    if (!startup.lpAttributeList || !InitializeProcThreadAttributeList(startup.lpAttributeList, 2, 0, &attr_size)) goto done;
    initialized = TRUE;
    if (!UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                   &null, sizeof(null), NULL, NULL) ||
        !UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
                                   &s->job, sizeof(s->job), NULL, NULL)) goto done;
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = startup.StartupInfo.hStdOutput = startup.StartupInfo.hStdError = null;
    release_port(&s->proxy);
    release_port(&s->control);
    if (stopped() || !CreateProcessW(s->exe, args, NULL, NULL, TRUE, CREATE_SUSPENDED | CREATE_NO_WINDOW |
                                    CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT, env, s->dir,
                                    &startup.StartupInfo, &process)) goto done;
    s->process = process.hProcess;
    s->pid = process.dwProcessId;
    // The Windows 10 job-list attribute attaches the process during creation.
    // Even a force kill between process creation and resume closes the job.
    if (!stopped() && ResumeThread(process.hThread) != (DWORD)-1) ok = TRUE;
done:
    if (process.hThread) CloseHandle(process.hThread);
    if (initialized) DeleteProcThreadAttributeList(startup.lpAttributeList);
    free(startup.lpAttributeList);
    if (null != INVALID_HANDLE_VALUE) CloseHandle(null);
    return ok;
}

static void *listeners(ULONG family) {
    DWORD size = 0;
    if (GetExtendedTcpTable(NULL, &size, FALSE, family, TCP_TABLE_OWNER_PID_LISTENER, 0) != ERROR_INSUFFICIENT_BUFFER) return NULL;
    for (int attempt = 0; attempt < 3 && size && size <= LISTENER_TABLE_LIMIT; ++attempt) {
        void *table = malloc(size);
        if (!table) return NULL;
        DWORD result = GetExtendedTcpTable(table, &size, FALSE, family, TCP_TABLE_OWNER_PID_LISTENER, 0);
        if (result == NO_ERROR) return table;
        free(table);
        if (result != ERROR_INSUFFICIENT_BUFFER) break;
    }
    return NULL;
}
static BOOL own_listeners(const clay_win_session *s) {
    MIB_TCPTABLE_OWNER_PID *v4 = listeners(AF_INET);
    MIB_TCP6TABLE_OWNER_PID *v6 = listeners(AF_INET6);
    BOOL proxy = FALSE, control = FALSE, ok = v4 && v6;
    if (ok) {
        for (DWORD i = 0; i < v4->dwNumEntries; ++i) {
            const MIB_TCPROW_OWNER_PID *row = &v4->table[i];
            uint16_t port = ntohs((u_short)row->dwLocalPort);
            if (port != s->proxy_port && port != s->control_port) continue;
            if (row->dwOwningPid != s->pid || row->dwLocalAddr != htonl(INADDR_LOOPBACK)) { ok = FALSE; break; }
            if (port == s->proxy_port) proxy = TRUE;
            if (port == s->control_port) control = TRUE;
        }
        const UCHAR loopback6[16] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
        for (DWORD i = 0; ok && i < v6->dwNumEntries; ++i) {
            const MIB_TCP6ROW_OWNER_PID *row = &v6->table[i];
            uint16_t port = ntohs((u_short)row->dwLocalPort);
            if (port != s->proxy_port && port != s->control_port) continue;
            if (row->dwOwningPid != s->pid || memcmp(row->ucLocalAddr, loopback6, sizeof(loopback6))) ok = FALSE;
        }
    }
    free(v4);
    free(v6);
    return ok && proxy && control;
}

// stdout can be a full pipe. A dedicated worker handling this single, public
// line keeps console messages and process teardown responsive.
static char output_line[256];
static DWORD WINAPI emit_line(LPVOID ignored) {
    (void)ignored;
    DWORD length = (DWORD)strlen(output_line), written = 0;
    HANDLE stdout_handle = GetStdHandle(STD_OUTPUT_HANDLE);
    return WriteFile(stdout_handle, output_line, length, &written, NULL) && written == length ? 0 : 1;
}
int32_t clay_win_emit(clay_win_session *s, const char *line) {
    if (sprintf_s(output_line, sizeof(output_line), "%s\r\n", line) <= 0) return CLAY_WIN_OUTPUT;
    HANDLE worker = CreateThread(NULL, 0, emit_line, NULL, 0, NULL);
    if (!worker) return CLAY_WIN_OUTPUT;
    HANDLE waits[] = {stop_event, s->process, worker};
    DWORD wait = WaitForMultipleObjects(3, waits, FALSE, 2000), code = 1;
    if (wait == WAIT_OBJECT_0 + 2) GetExitCodeThread(worker, &code);
    else CancelSynchronousIo(worker);
    // The worker accesses only static memory and is reclaimed on exit, even
    // if the timeout races the beginning of its write.
    CloseHandle(worker);
    if (wait == WAIT_OBJECT_0) return CLAY_WIN_INTERRUPTED;
    if (wait == WAIT_OBJECT_0 + 1) return CLAY_WIN_EXITED;
    return code == 0 ? CLAY_WIN_OK : CLAY_WIN_OUTPUT;
}

int32_t clay_win_start(clay_win_session *s, const uint8_t *config, size_t length) {
    if (stopped()) return CLAY_WIN_INTERRUPTED;
    if (!write_config(s, config, length)) return CLAY_WIN_FILES;
    if (!launch(s)) return stopped() ? CLAY_WIN_INTERRUPTED : CLAY_WIN_LAUNCH;
    HANDLE waits[] = {stop_event, s->process};
    ULONGLONG deadline = GetTickCount64() + 6000;
    for (;;) {
        DWORD wait = WaitForMultipleObjects(2, waits, FALSE, 35);
        if (wait == WAIT_OBJECT_0) return CLAY_WIN_INTERRUPTED;
        if (wait != WAIT_TIMEOUT) return CLAY_WIN_EXITED;
        if (own_listeners(s) && WaitForSingleObject(s->process, 0) == WAIT_TIMEOUT) break;
        if (GetTickCount64() >= deadline) return CLAY_WIN_LISTENERS;
    }
    char line[112];
    if (sprintf_s(line, sizeof(line), "mihomo=ready proxy=127.0.0.1:%u controller=127.0.0.1:%u",
                  (unsigned)s->proxy_port, (unsigned)s->control_port) <= 0) return CLAY_WIN_OUTPUT;
    return clay_win_emit(s, line);
}

int32_t clay_win_run(clay_win_session *s, const uint8_t *config, size_t length) {
    int32_t status = clay_win_start(s, config, length);
    if (status != CLAY_WIN_OK) return status;
    HANDLE waits[] = {stop_event, s->process};
    for (;;) {
        DWORD wait = WaitForMultipleObjects(2, waits, FALSE, 500);
        if (wait == WAIT_OBJECT_0) return CLAY_WIN_INTERRUPTED;
        if (wait != WAIT_TIMEOUT) return CLAY_WIN_EXITED;
        if (!own_listeners(s)) return CLAY_WIN_LISTENERS;
    }
}

// The console or redirected input can be idle indefinitely. Only the input
// worker blocks; the session thread can still stop and reap its private job.
static uint8_t input_chunk[512];
static DWORD input_size;
static DWORD WINAPI read_chunk(LPVOID ignored) {
    (void)ignored;
    HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
    if (ReadFile(input, input_chunk, sizeof(input_chunk), &input_size, NULL)) return input_size ? CLAY_WIN_OK : CLAY_WIN_EOF;
    DWORD error = GetLastError();
    return error == ERROR_BROKEN_PIPE || error == ERROR_HANDLE_EOF ? CLAY_WIN_EOF : CLAY_WIN_INPUT;
}

int32_t clay_win_read(clay_win_session *s, uint8_t *buffer, uint32_t capacity, uint32_t *count) {
    if (capacity < sizeof(input_chunk)) return CLAY_WIN_INPUT;
    *count = 0;
    HANDLE worker = CreateThread(NULL, 0, read_chunk, NULL, 0, NULL);
    if (!worker) return CLAY_WIN_INPUT;
    HANDLE waits[] = {stop_event, s->process, worker};
    int32_t status;
    for (;;) {
        DWORD wait = WaitForMultipleObjects(3, waits, FALSE, 500), result;
        if (wait == WAIT_OBJECT_0) { status = CLAY_WIN_INTERRUPTED; break; }
        if (wait == WAIT_OBJECT_0 + 1) { status = CLAY_WIN_EXITED; break; }
        if (wait == WAIT_OBJECT_0 + 2) {
            status = GetExitCodeThread(worker, &result) ? (int32_t)result : CLAY_WIN_INPUT;
            if (status == CLAY_WIN_OK) { memcpy(buffer, input_chunk, input_size); *count = input_size; }
            CloseHandle(worker);
            return status;
        }
        if (wait != WAIT_TIMEOUT) { status = CLAY_WIN_INPUT; break; }
        if (!own_listeners(s)) { status = CLAY_WIN_LISTENERS; break; }
    }
    CancelSynchronousIo(worker);
    // On early return the worker uses only static storage and the CLI exits
    // after cleanup. It never touches the caller's buffer or session.
    CloseHandle(worker);
    return status;
}

static int32_t control_health(const clay_win_session *s) {
    if (stopped()) return CLAY_WIN_INTERRUPTED;
    if (WaitForSingleObject(s->process, 0) != WAIT_TIMEOUT) return CLAY_WIN_EXITED;
    return own_listeners(s) ? CLAY_WIN_OK : CLAY_WIN_LISTENERS;
}

int32_t clay_win_control(clay_win_session *s, int32_t operation, const char *secret, const char *body,
                         uint8_t *response, uint32_t capacity, uint32_t *count) {
    *count = 0;
    int32_t status = control_health(s);
    if (status != CLAY_WIN_OK) return status;
    static const WCHAR *verbs[] = {L"GET", L"GET", L"PATCH", L"PUT"};
    static const WCHAR *paths[] = {L"/configs", L"/proxies/CLAY", L"/configs", L"/proxies/CLAY"};
    if (operation < CLAY_CTL_GET_MODE || operation > CLAY_CTL_SET_NODE || !capacity ||
        strlen(secret) != 64 || strspn(secret, "0123456789abcdef") != 64) return CLAY_WIN_CONTROLLER;
    BOOL change = operation >= CLAY_CTL_SET_MODE;
    size_t length = body ? strlen(body) : 0;
    if ((change && (!length || length > 256)) || (!change && length)) return CLAY_WIN_CONTROLLER;
    status = CLAY_WIN_CONTROLLER;
    HINTERNET session = WinHttpOpen(L"CLAY", WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME,
                                    WINHTTP_NO_PROXY_BYPASS, 0), connection = NULL, request = NULL;
    if (!session || !WinHttpSetTimeouts(session, 500, 600, 600, 600)) goto done;
    connection = WinHttpConnect(session, L"127.0.0.1", s->control_port, 0);
    if (!connection) goto done;
    request = WinHttpOpenRequest(connection, verbs[operation], paths[operation], NULL,
                                 WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
    if (!request) goto done;
    DWORD disable = WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_AUTHENTICATION;
    if (!WinHttpSetOption(request, WINHTTP_OPTION_DISABLE_FEATURE, &disable, sizeof(disable))) goto done;
    WCHAR headers[160];
    if (swprintf_s(headers, _countof(headers), L"Authorization: Bearer %hs\r\nContent-Type: application/json\r\n", secret) <= 0) goto done;
    BOOL sent = WinHttpSendRequest(request, headers, (DWORD)-1, (void *)body, (DWORD)length, (DWORD)length, 0);
    SecureZeroMemory(headers, sizeof(headers));
    if (!sent || !WinHttpReceiveResponse(request, NULL)) goto done;
    DWORD http = 0, size = sizeof(http);
    if (!WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                             WINHTTP_HEADER_NAME_BY_INDEX, &http, &size, WINHTTP_NO_HEADER_INDEX)) goto done;
    if ((change && http != 204 && http != 200) || (!change && http != 200)) goto done;
    if (!change) {
        ULONGLONG deadline = GetTickCount64() + 1600;
        for (;;) {
            DWORD read = 0;
            if (stopped() || GetTickCount64() >= deadline || *count >= capacity ||
                !WinHttpReadData(request, response + *count, capacity - *count, &read)) goto done;
            if (!read) break;
            *count += read;
        }
    }
    status = CLAY_WIN_OK;
done:
    if (request) WinHttpCloseHandle(request);
    if (connection) WinHttpCloseHandle(connection);
    if (session) WinHttpCloseHandle(session);
    int32_t health = control_health(s);
    return health == CLAY_WIN_OK ? status : health;
}

// Remove generated files without ever traversing a directory reparse point.
static BOOL remove_tree(const WCHAR *folder, unsigned depth) {
    WCHAR pattern[PATH_CAP], path[PATH_CAP];
    WIN32_FIND_DATAW item;
    if (depth > 16 || !join_path(pattern, folder, L"*")) return FALSE;
    HANDLE files = FindFirstFileW(pattern, &item);
    if (files == INVALID_HANDLE_VALUE && GetLastError() != ERROR_FILE_NOT_FOUND) return FALSE;
    if (files != INVALID_HANDLE_VALUE) {
        do {
            if (!wcscmp(item.cFileName, L".") || !wcscmp(item.cFileName, L"..") || !join_path(path, folder, item.cFileName)) continue;
            if (item.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                if (item.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) RemoveDirectoryW(path);
                else remove_tree(path, depth + 1);
            } else {
                if (!(item.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) && (item.dwFileAttributes & FILE_ATTRIBUTE_READONLY))
                    SetFileAttributesW(path, FILE_ATTRIBUTE_NORMAL);
                DeleteFileW(path);
            }
        } while (FindNextFileW(files, &item));
        FindClose(files);
    }
    return RemoveDirectoryW(folder);
}

int32_t clay_win_stop(clay_win_session *s) {
    if (s->job) {
        TerminateJobObject(s->job, 1);
        ULONGLONG deadline = GetTickCount64() + 1800;
        JOBOBJECT_BASIC_ACCOUNTING_INFORMATION account;
        while (GetTickCount64() < deadline && QueryInformationJobObject(s->job, JobObjectBasicAccountingInformation,
                                                                        &account, sizeof(account), NULL) && account.ActiveProcesses)
            Sleep(15);
        CloseHandle(s->job);
    }
    if (s->process) {
        WaitForSingleObject(s->process, 1000);
        CloseHandle(s->process);
    }
    release_port(&s->proxy);
    release_port(&s->control);
    if (s->winsock) WSACleanup();
    if (s->verified != INVALID_HANDLE_VALUE) CloseHandle(s->verified);
    // Remove the credential-bearing config before trying to remove generated state.
    if (s->config[0]) DeleteFileW(s->config);
    BOOL ok = !s->dir[0] || remove_tree(s->dir, 0);
    SetEvent(cleaned_event);
    if (s->console_handler) SetConsoleCtrlHandler(on_console, FALSE);
    free(s);
    return ok ? CLAY_WIN_OK : CLAY_WIN_FILES;
}
