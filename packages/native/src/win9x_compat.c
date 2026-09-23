// Windows XP compatibility stubs for opentui.dll (x86-windows-gnu build).
//
// The DLL (via Zig std + UCRT runtime) imports several Vista+/Win8+ kernel32
// and ntdll entry points that do not exist on Windows XP (SRW locks,
// condition variables, Fiber Local Storage, one-time init, NtAlertThread /
// NtCreateThreadEx / LdrRegisterDllNotification, ...), so the DLL would fail
// to load there.
//
// Each Vista+ entry point `Foo` is stubbed here under a private name
// `win9x_Foo` (never conflicts with the import library), and win9x_imports.asm
// defines the corresponding `__imp__Foo@N` DATA symbol + `_Foo@N` code thunk
// pointing at the stub. An object definition of `__imp_` beats the import
// library, so references resolve to the stub and no IAT entry is created —
// the loader never looks the function up in kernel32.dll/ntdll.dll on XP.
//
// Concurrency semantics are relaxed (SRW shared locks degrade to exclusive,
// condition variables wake on timeout) which is correct enough for the
// audio/render threads and avoids load failure.
//
// The UCRT (api-ms-win-crt-*.dll) imports are NOT handled here — the build
// links libc++ (yoga) so Zig always links the UCRT; those imports are
// satisfied at runtime by the UCRT-for-XP shim DLLs shipped alongside the
// opencode binary.
//
// NOTE: this file deliberately does NOT include <windows.h> — the modern
// headers declare these Vista+ functions, which would conflict. Only the
// kernel32 functions actually used are declared.

#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>

// --- types + kernel32 declarations (must precede the shims that use them) ---

typedef long LONG;
typedef unsigned long DWORD;
typedef unsigned long ULONG;
typedef int BOOL;

typedef struct _FILETIME { DWORD dwLowDateTime; DWORD dwHighDateTime; } FILETIME;

#define WINAPI __stdcall
#define WINBASEAPI __declspec(dllimport)

WINBASEAPI LONG WINAPI InterlockedCompareExchange(LONG volatile*, LONG, LONG);
WINBASEAPI LONG WINAPI InterlockedExchange(LONG volatile*, LONG);
WINBASEAPI void WINAPI SwitchToThread(void);
WINBASEAPI DWORD WINAPI TlsAlloc(void);
WINBASEAPI void* WINAPI TlsGetValue(DWORD);
WINBASEAPI BOOL WINAPI TlsSetValue(DWORD, void*);
WINBASEAPI void WINAPI Sleep(DWORD);
WINBASEAPI void WINAPI GetSystemTimeAsFileTime(FILETIME*);
WINBASEAPI DWORD WINAPI GetCurrentThreadId(void);
WINBASEAPI void* WINAPI GetProcessHeap(void);
WINBASEAPI void* WINAPI HeapAlloc(void*, DWORD, size_t);
WINBASEAPI BOOL WINAPI HeapFree(void*, DWORD, void*);

// --- msvcrt forwards used by the UCRT-internal shims ---

typedef struct _iobuf {
    char* _ptr;
    int _cnt;
    char* _base;
    int _flag;
    int _file;
    int _charbuf;
    int _bufsiz;
    char* _tmpfname;
} FILE;

extern FILE _iob[];                    // msvcrt's stdin/stdout/stderr table
extern int vfprintf(FILE*, const char*, va_list);
extern int vsprintf(char*, const char*, va_list);
extern int vsscanf(const char*, const char*, va_list);
extern int _close(int);
extern void* memcpy(void*, const void*, size_t);

// --- UCRT-internal stubs (win9x_* names; __imp_ redirects in win9x_imports.asm) ---

FILE* win9x_acrt_iob_func(unsigned int index) {
    return &_iob[index];
}

int win9x_stdio_common_vfprintf(uint64_t options, FILE* stream, const char* format, void* locale, va_list argptr) {
    (void)options;
    (void)locale;
    return vfprintf(stream, format, argptr);
}

int win9x_stdio_common_vsprintf(uint64_t options, char* const buffer, size_t const buffer_count, const char* const format, void* locale, va_list argptr) {
    (void)options;
    (void)buffer_count;
    (void)locale;
    return vsprintf(buffer, format, argptr);
}

int win9x_stdio_common_vsscanf(const char* const buffer, size_t const buffer_count, const char* const format, void* locale, va_list argptr) {
    (void)buffer_count;
    (void)locale;
    return vsscanf(buffer, format, argptr);
}

int win9x_close(int fd) { return _close(fd); }

// One-time-init / C++ static-init tables (UCRT layout).
typedef void(__cdecl* _PVFV)(void);
typedef int(__cdecl* _PIFV)(void);

typedef struct {
    _PVFV* _first;
    _PVFV* _last;
    _PVFV* _end;
} _onexit_table_t;

void win9x_initialize_onexit_table(_onexit_table_t* table) {
    table->_first = 0;
    table->_last = 0;
    table->_end = 0;
}

int win9x_register_onexit_function(_onexit_table_t* table, _PVFV function) {
    size_t used = (size_t)(table->_last - table->_first);
    size_t cap = (size_t)(table->_end - table->_first);
    if (used + 1 > cap) {
        size_t new_cap = cap == 0 ? 16 : cap * 2;
        _PVFV* nb = (_PVFV*)HeapAlloc(GetProcessHeap(), 0, new_cap * sizeof(_PVFV));
        if (!nb) return -1;
        if (used) {
            memcpy(nb, table->_first, used * sizeof(_PVFV));
            HeapFree(GetProcessHeap(), 0, table->_first);
        }
        table->_first = nb;
        table->_last = nb + used;
        table->_end = nb + new_cap;
    }
    *table->_last++ = function;
    return 0;
}

int win9x_execute_onexit_table(_onexit_table_t* table) {
    while (table->_last > table->_first) {
        _PVFV fn = *--table->_last;
        if (fn) fn();
    }
    if (table->_first) HeapFree(GetProcessHeap(), 0, table->_first);
    table->_first = table->_last = table->_end = 0;
    return 0;
}

void win9x_initterm(_PVFV* first, _PVFV* last) {
    while (first < last) {
        _PVFV fn = *first++;
        if (fn) fn();
    }
}

int win9x_initterm_e(_PIFV* first, _PIFV* last) {
    while (first < last) {
        _PIFV fn = *first++;
        if (fn) {
            int result = fn();
            if (result != 0) return result;
        }
    }
    return 0;
}

// --- Vista+ kernel32 stubs ---

// SRW locks degrade to a 4-byte spinlock (fits the x86 SRWLOCK footprint).
// Shared acquire is treated as exclusive (no concurrent readers).
static void spin_lock(LONG volatile* p) {
    while (InterlockedCompareExchange(p, 1, 0) != 0) {
        SwitchToThread();
    }
}

void WINAPI win9x_AcquireSRWLockExclusive(void* srwl) { spin_lock((LONG volatile*)srwl); }
void WINAPI win9x_ReleaseSRWLockExclusive(void* srwl) { InterlockedExchange((LONG volatile*)srwl, 0); }
void WINAPI win9x_AcquireSRWLockShared(void* srwl) { spin_lock((LONG volatile*)srwl); }
void WINAPI win9x_ReleaseSRWLockShared(void* srwl) { InterlockedExchange((LONG volatile*)srwl, 0); }
BOOL WINAPI win9x_TryAcquireSRWLockExclusive(void* srwl) { return InterlockedCompareExchange((LONG volatile*)srwl, 1, 0) == 0; }

// Condition variables: release the (spin)lock, sleep, reacquire. Wakes are
// no-ops; waiters wake on timeout.
BOOL WINAPI win9x_SleepConditionVariableSRW(void* cv, void* srwl, DWORD ms, ULONG flags) {
    (void)cv;
    (void)flags;
    InterlockedExchange((LONG volatile*)srwl, 0);
    Sleep(ms);
    spin_lock((LONG volatile*)srwl);
    return 1;
}
void WINAPI win9x_WakeConditionVariable(void* cv) { (void)cv; }
void WINAPI win9x_WakeAllConditionVariable(void* cv) { (void)cv; }

// Fiber Local Storage -> thread-local storage (ignores the alloc callback).
DWORD WINAPI win9x_FlsAlloc(void* callback) {
    (void)callback;
    return TlsAlloc();
}
void* WINAPI win9x_FlsGetValue(DWORD index) { return TlsGetValue(index); }
BOOL WINAPI win9x_FlsSetValue(DWORD index, void* value) { return TlsSetValue(index, value); }

// One-time init -> spinlock flag.
typedef void (*WINAPI PINIT_ONCE_FN)(void* param, void* context, void** out);
BOOL WINAPI win9x_InitOnceExecuteOnce(LONG volatile* init_once, PINIT_ONCE_FN fn, void* param, void** context) {
    spin_lock(init_once);
    if (*init_once == 2) {
        InterlockedExchange(init_once, 0);
        return 1;
    }
    void* ctx = 0;
    fn(param, 0, &ctx);
    if (context) *context = ctx;
    InterlockedExchange(init_once, 2);
    InterlockedExchange(init_once, 0);
    return 1;
}

// High-resolution time -> plain file time (XP has no precise variant).
void WINAPI win9x_GetSystemTimePreciseAsFileTime(FILETIME* out) { GetSystemTimeAsFileTime(out); }

// GetThreadId for the current thread (the common case).
DWORD WINAPI win9x_GetThreadId(void* thread) { (void)thread; return GetCurrentThreadId(); }

// Process module enumeration (debugging only) -> unsupported on XP.
BOOL WINAPI win9x_K32EnumProcessModules(void* proc, void* modules, DWORD cb, DWORD* needed) {
    (void)proc; (void)modules; (void)cb;
    if (needed) *needed = 0;
    return 0;
}

// --- Vista+ ntdll stubs (NTSTATUS) ---

typedef long NTSTATUS;
#define STATUS_SUCCESS ((NTSTATUS)0)
#define STATUS_NOT_IMPLEMENTED ((NTSTATUS)0xC0000002L)

NTSTATUS WINAPI win9x_NtAlertThread(void* thread) { (void)thread; return STATUS_SUCCESS; }
NTSTATUS WINAPI win9x_NtAlertThreadByThreadId(void* id) { (void)id; return STATUS_SUCCESS; }
NTSTATUS WINAPI win9x_NtWaitForAlertByThreadId(void* id, void* alertable) { (void)id; (void)alertable; Sleep(1); return STATUS_SUCCESS; }
NTSTATUS WINAPI win9x_NtCancelIoFileEx(void* file, void* io, void* status) { (void)file; (void)io; (void)status; return STATUS_NOT_IMPLEMENTED; }
NTSTATUS WINAPI win9x_NtCancelSynchronousIoFile(void* thread, void* io, void* status) { (void)thread; (void)io; (void)status; return STATUS_NOT_IMPLEMENTED; }
NTSTATUS WINAPI win9x_NtCreateNamedPipeFile(void* a, void* b, void* c, void* d, void* e, void* f, void* g, void* h, void* i, void* j, void* k, void* l, void* m, void* n) { return STATUS_NOT_IMPLEMENTED; }
NTSTATUS WINAPI win9x_NtCreateThreadEx(void* a, void* b, void* c, void* d, void* e, void* f, void* g, void* h, void* i, void* j, void* k) { return STATUS_NOT_IMPLEMENTED; }
NTSTATUS WINAPI win9x_LdrRegisterDllNotification(void* a, void* b, void* c, void* d) { return STATUS_NOT_IMPLEMENTED; }

typedef union _LARGE_INTEGER_ { struct { DWORD LowPart; LONG HighPart; }; long long QuadPart; } LARGE_INTEGER;

// Zig std declares RtlGetSystemTimePrecise() with zero arguments returning the
// 100ns FILETIME-style counter.
LARGE_INTEGER WINAPI win9x_RtlGetSystemTimePrecise(void) {
    FILETIME ft;
    LARGE_INTEGER li;
    GetSystemTimeAsFileTime(&ft);
    li.LowPart = ft.dwLowDateTime;
    li.HighPart = ft.dwHighDateTime;
    return li;
}
void WINAPI win9x_RtlReportSilentProcessExit(void* a, long b) { (void)a; (void)b; }

// Zig std declares RtlQueryPerformanceCounter / RtlQueryPerformanceFrequency as
// returning BOOL (nonzero = success) and asserts .toBool() in the awake-clock
// path — NOT NTSTATUS. Polyfill with the kernel32 BOOL-returning equivalents.
WINBASEAPI void WINAPI ExitProcess(unsigned);
WINBASEAPI int WINAPI QueryPerformanceCounter(LARGE_INTEGER*);
WINBASEAPI int WINAPI QueryPerformanceFrequency(LARGE_INTEGER*);

void WINAPI win9x_RtlExitUserProcess(unsigned exit_code) {
    ExitProcess(exit_code);
}
BOOL WINAPI win9x_RtlQueryPerformanceCounter(LARGE_INTEGER* lp) {
    return QueryPerformanceCounter(lp);
}
BOOL WINAPI win9x_RtlQueryPerformanceFrequency(LARGE_INTEGER* lp) {
    return QueryPerformanceFrequency(lp);
}
