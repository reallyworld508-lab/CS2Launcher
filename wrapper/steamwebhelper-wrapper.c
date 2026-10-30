/*
 * steamwebhelper wrapper.
 *
 * Replaces Steam\bin\cef\cef.win64\steamwebhelper.exe. Launches the renamed
 * original (steamwebhelper_real.exe, same folder) with extra Chromium flags
 * prepended, forwards the remaining command line verbatim, waits for it and
 * returns its exit code.
 *
 * Set STEAMWEBHELPER_WRAPPER_DEBUG to log to steamwebhelper-wrapper.log
 * next to this executable.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <wchar.h>

#define REAL_NAME   L"steamwebhelper_real.exe"
#define EXTRA_FLAGS L"--disable-gpu --single-process"

static FILE *g_log = NULL;

static void log_open(const wchar_t *dir) {
    wchar_t env[8];
    if (GetEnvironmentVariableW(L"STEAMWEBHELPER_WRAPPER_DEBUG", env, 8) == 0) return;
    size_t n = wcslen(dir) + 64;
    wchar_t *path = (wchar_t *)malloc(n * sizeof(wchar_t));
    if (!path) return;
    swprintf(path, n, L"%lssteamwebhelper-wrapper.log", dir);
    g_log = _wfopen(path, L"a");
    free(path);
}

static void logf_(const wchar_t *fmt, ...) {
    if (!g_log) return;
    va_list ap;
    va_start(ap, fmt);
    fwprintf(g_log, L"[%lu] ", (unsigned long)GetCurrentProcessId());
    vfwprintf(g_log, fmt, ap);
    fwprintf(g_log, L"\n");
    fflush(g_log);
    va_end(ap);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, LPWSTR cmd, int show) {
    (void)inst; (void)prev; (void)show;
    int exit_code = 1;
    wchar_t *line = NULL;
    PROCESS_INFORMATION pi = {0};

    wchar_t self[MAX_PATH * 2];
    DWORD len = GetModuleFileNameW(NULL, self, (DWORD)(sizeof(self) / sizeof(self[0])));
    if (len == 0 || len >= sizeof(self) / sizeof(self[0])) return 2;
    wchar_t *slash = wcsrchr(self, L'\\');
    if (slash) slash[1] = 0; else self[0] = 0;

    log_open(self);
    if (!cmd) cmd = L"";
    logf_(L"wrapper started in %ls, args: %ls", self, cmd);

    /* "<dir>\steamwebhelper_real.exe" <extra flags> <original args> */
    size_t n = wcslen(self) + wcslen(cmd) + 128;
    line = (wchar_t *)malloc(n * sizeof(wchar_t));
    if (!line) { logf_(L"out of memory"); goto done; }
    swprintf(line, n, L"\"%ls" REAL_NAME L"\" " EXTRA_FLAGS L"%ls%ls",
             self, *cmd ? L" " : L"", cmd);
    logf_(L"command line: %ls", line);

    /* Inherit handles: CEF children receive IPC handles by inheritance. */
    STARTUPINFOW si;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    if (!CreateProcessW(NULL, line, NULL, NULL, TRUE, 0, NULL, self[0] ? self : NULL, &si, &pi)) {
        logf_(L"CreateProcess failed: %lu", (unsigned long)GetLastError());
        exit_code = 3;
        goto done;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    if (GetExitCodeProcess(pi.hProcess, &code)) {
        exit_code = (int)code;
    } else {
        logf_(L"GetExitCodeProcess failed: %lu", (unsigned long)GetLastError());
    }
    logf_(L"child exited with %lu", (unsigned long)code);

done:
    if (pi.hProcess) CloseHandle(pi.hProcess);
    if (pi.hThread) CloseHandle(pi.hThread);
    free(line);
    if (g_log) fclose(g_log);
    return exit_code;
}
