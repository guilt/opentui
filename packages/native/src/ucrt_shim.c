// UCRT-for-XP shim: api-ms-win-crt-stdio-l1-1-0.dll + api-ms-win-crt-runtime-l1-1-0.dll
// (+ api-ms-win-crt-string-l1-1-0.dll for wcsrtombs, which XP's msvcrt lacks).
// Implement the UCRT-internal functions on top of msvcrt.dll (present on XP).
// Built with clang-cl for x86, msvcrt ABI (cdecl), no CRT. msvcrt functions
// are resolved at runtime via GetProcAddress (XP's msvcrt exports the plain
// names; modern msvcrt routes them through the UCRT, so a load-time import
// would fail there — but the shim is only used on XP/9x anyway).

#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>

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

typedef void* HMODULE;
extern __declspec(dllimport) HMODULE __stdcall LoadLibraryA(const char*);
extern __declspec(dllimport) void* __stdcall GetProcAddress(HMODULE, const char*);

typedef int(__cdecl* vfprintf_fn)(FILE*, const char*, va_list);
typedef int(__cdecl* vsprintf_fn)(char*, const char*, va_list);
typedef int(__cdecl* vsscanf_fn)(const char*, const char*, va_list);
typedef int(__cdecl* close_fn)(int);

static void* get_msvcrt(const char* name) {
    static HMODULE m;
    if (!m) m = LoadLibraryA("msvcrt.dll");
    return m ? GetProcAddress(m, name) : 0;
}

// Custom CRT entry (no CRT startup linked due to /NODEFAULTLIB). Must return
// TRUE for the loader to proceed.
int __stdcall _DllMainCRTStartup(void* hinst, unsigned reason, void* reserved) {
    (void)hinst; (void)reason; (void)reserved;
    return 1;
}

#if SHIM_STDIO

// Local stdin/stdout/stderr FILE table (msvcrt FILE layout). The FILE*
// pointers are only ever passed back to msvcrt's v* functions.
static FILE stdio_files[3] = {0};

FILE* __acrt_iob_func(unsigned int index) {
    return index < 3 ? &stdio_files[index] : 0;
}

int __stdio_common_vfprintf(uint64_t options, FILE* stream, const char* format, void* locale, va_list argptr) {
    (void)options;
    (void)locale;
    vfprintf_fn fn = (vfprintf_fn)get_msvcrt("vfprintf");
    return fn ? fn(stream, format, argptr) : -1;
}

int __stdio_common_vsprintf(uint64_t options, char* const buffer, size_t const buffer_count, const char* const format, void* locale, va_list argptr) {
    (void)options;
    (void)buffer_count;
    (void)locale;
    vsprintf_fn fn = (vsprintf_fn)get_msvcrt("vsprintf");
    return fn ? fn(buffer, format, argptr) : -1;
}

int __stdio_common_vsscanf(const char* const buffer, size_t const buffer_count, const char* const format, void* locale, va_list argptr) {
    (void)buffer_count;
    (void)locale;
    vsscanf_fn fn = (vsscanf_fn)get_msvcrt("vsscanf");
    return fn ? fn(buffer, format, argptr) : -1;
}

int _close(int fd) {
    close_fn fn = (close_fn)get_msvcrt("_close");
    return fn ? fn(fd) : -1;
}

#elif SHIM_STRING // api-ms-win-crt-string-l1-1-0.dll (wcsrtombs — XP msvcrt lacks it)

// Windows wchar_t is 16-bit; define it for the no-CRT build (stddef.h does
// not reliably provide it under clang-cl /NODEFAULTLIB).
#ifndef _WCHAR_T_DEFINED
typedef unsigned short wchar_t;
#define _WCHAR_T_DEFINED
#endif

// size_t wcsrtombs(char* dst, const wchar_t** src, size_t len, mbstate_t* ps)
// Convert the wide string *src to multibyte into dst (at most len bytes).
// wcstombs (present in XP's msvcrt) does the actual conversion; this wrapper
// implements the wcsrtombs contract: on success updates *src past the wide
// chars consumed (NULL if fully consumed) and returns the byte count; returns
// (size_t)-1 on an invalid wide character (leaving *src at the bad char).
typedef size_t(__cdecl* wcstombs_fn)(char*, const wchar_t*, size_t);
static wcstombs_fn get_wcstombs(void) {
    return (wcstombs_fn)get_msvcrt("wcstombs");
}

size_t wcsrtombs(char* dst, const wchar_t** src, size_t len, void* ps) {
    (void)ps;
    if (!src || !*src) return (size_t)-1;
    wcstombs_fn wcstombs_fn_p = get_wcstombs();
    if (!wcstombs_fn_p) return (size_t)-1;
    const wchar_t* s = *src;

    if (!dst) {
        // Length query: wcstombs(NULL, ...) with a huge count computes the
        // total length of the full conversion (no state, same output).
        return wcstombs_fn_p(NULL, s, (size_t)-1);
    }

    size_t written = 0;
    while (written < len) {
        if (!*s) { *src = NULL; return written; }
        char tmp[8];
        size_t m = wcstombs_fn_p(tmp, s, sizeof(tmp));
        if (m == (size_t)-1) { *src = s; return (size_t)-1; }
        if (written + m > len) break;
        // Count the wide chars that produced these m bytes (wcstombs consumed
        // the minimal prefix that fit; walk char by char to find k).
        size_t k = 0, acc = 0;
        while (acc < m) {
            size_t mm = wcstombs_fn_p(tmp, s + k, sizeof(tmp));
            if (mm == (size_t)-1) { *src = s + k; return (size_t)-1; }
            acc += mm;
            k++;
        }
        size_t m2 = wcstombs_fn_p(dst + written, s, len - written);
        if (m2 == (size_t)-1) { *src = s; return (size_t)-1; }
        written += m2;
        s += k;
    }
    *src = s;
    return written;
}

#else // runtime-l1-1-0 (onexit/init tables)

typedef void(__cdecl* _PVFV)(void);
typedef int(__cdecl* _PIFV)(void);

typedef struct {
    _PVFV* _first;
    _PVFV* _last;
    _PVFV* _end;
} _onexit_table_t;

// Kernel32 heap for table growth.
extern __declspec(dllimport) void* __stdcall GetProcessHeap(void);
extern __declspec(dllimport) void* __stdcall HeapAlloc(void*, uint32_t, size_t);
extern __declspec(dllimport) int __stdcall HeapFree(void*, uint32_t, void*);

static void* memcpy(void* dst, const void* src, size_t n) {
    unsigned char* d = (unsigned char*)dst;
    const unsigned char* s = (const unsigned char*)src;
    while (n--) *d++ = *s++;
    return dst;
}

void _initialize_onexit_table(_onexit_table_t* table) {
    table->_first = 0;
    table->_last = 0;
    table->_end = 0;
}

int _register_onexit_function(_onexit_table_t* table, _PVFV function) {
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

int _execute_onexit_table(_onexit_table_t* table) {
    while (table->_last > table->_first) {
        _PVFV fn = *--table->_last;
        if (fn) fn();
    }
    if (table->_first) HeapFree(GetProcessHeap(), 0, table->_first);
    table->_first = table->_last = table->_end = 0;
    return 0;
}

void _initterm(_PVFV* first, _PVFV* last) {
    while (first < last) {
        _PVFV fn = *first++;
        if (fn) fn();
    }
}

int _initterm_e(_PIFV* first, _PIFV* last) {
    while (first < last) {
        _PIFV fn = *first++;
        if (fn) {
            int result = fn();
            if (result != 0) return result;
        }
    }
    return 0;
}

#endif // SHIM_STDIO / SHIM_STRING / runtime