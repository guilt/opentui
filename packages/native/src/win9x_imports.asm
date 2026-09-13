; Win9x (Windows XP) import stubs — redirects Vista+/Win8+ kernel32.dll and
; ntdll.dll imports to local polyfills in win9x_compat.c.
;
; Defining `__imp__Foo@N` as a real DATA symbol in an object beats the import
; library: every caller resolves to our pointer, no IAT entry, no kernel32/
; ntdll import. Each data symbol points at the private `_win9x_Foo@N`
; polyfill defined in win9x_compat.c.
;
; win32 COFF, i586 (NASM `-f win32`).

BITS 32

extern _win9x_AcquireSRWLockExclusive@4
extern _win9x_ReleaseSRWLockExclusive@4
extern _win9x_AcquireSRWLockShared@4
extern _win9x_ReleaseSRWLockShared@4
extern _win9x_TryAcquireSRWLockExclusive@4
extern _win9x_SleepConditionVariableSRW@16
extern _win9x_WakeConditionVariable@4
extern _win9x_WakeAllConditionVariable@4
extern _win9x_FlsAlloc@4
extern _win9x_FlsGetValue@4
extern _win9x_FlsSetValue@8
extern _win9x_InitOnceExecuteOnce@16
extern _win9x_GetSystemTimePreciseAsFileTime@4
extern _win9x_GetThreadId@4
extern _win9x_K32EnumProcessModules@16
extern _win9x_NtAlertThread@4
extern _win9x_NtAlertThreadByThreadId@4
extern _win9x_NtWaitForAlertByThreadId@8
extern _win9x_NtCancelIoFileEx@12
extern _win9x_NtCancelSynchronousIoFile@12
extern _win9x_NtCreateNamedPipeFile@56
extern _win9x_NtCreateThreadEx@44
extern _win9x_LdrRegisterDllNotification@16
extern _win9x_RtlGetSystemTimePrecise@0
extern _win9x_RtlReportSilentProcessExit@8

section .data

global __imp__AcquireSRWLockExclusive@4
__imp__AcquireSRWLockExclusive@4: dd _win9x_AcquireSRWLockExclusive@4
global __imp__ReleaseSRWLockExclusive@4
__imp__ReleaseSRWLockExclusive@4: dd _win9x_ReleaseSRWLockExclusive@4
global __imp__AcquireSRWLockShared@4
__imp__AcquireSRWLockShared@4: dd _win9x_AcquireSRWLockShared@4
global __imp__ReleaseSRWLockShared@4
__imp__ReleaseSRWLockShared@4: dd _win9x_ReleaseSRWLockShared@4
global __imp__TryAcquireSRWLockExclusive@4
__imp__TryAcquireSRWLockExclusive@4: dd _win9x_TryAcquireSRWLockExclusive@4
global __imp__SleepConditionVariableSRW@16
__imp__SleepConditionVariableSRW@16: dd _win9x_SleepConditionVariableSRW@16
global __imp__WakeConditionVariable@4
__imp__WakeConditionVariable@4: dd _win9x_WakeConditionVariable@4
global __imp__WakeAllConditionVariable@4
__imp__WakeAllConditionVariable@4: dd _win9x_WakeAllConditionVariable@4
global __imp__FlsAlloc@4
__imp__FlsAlloc@4: dd _win9x_FlsAlloc@4
global __imp__FlsGetValue@4
__imp__FlsGetValue@4: dd _win9x_FlsGetValue@4
global __imp__FlsSetValue@8
__imp__FlsSetValue@8: dd _win9x_FlsSetValue@8
global __imp__InitOnceExecuteOnce@16
__imp__InitOnceExecuteOnce@16: dd _win9x_InitOnceExecuteOnce@16
global __imp__GetSystemTimePreciseAsFileTime@4
__imp__GetSystemTimePreciseAsFileTime@4: dd _win9x_GetSystemTimePreciseAsFileTime@4
global __imp__GetThreadId@4
__imp__GetThreadId@4: dd _win9x_GetThreadId@4
global __imp__K32EnumProcessModules@16
__imp__K32EnumProcessModules@16: dd _win9x_K32EnumProcessModules@16
global __imp__NtAlertThread@4
__imp__NtAlertThread@4: dd _win9x_NtAlertThread@4
global __imp__NtAlertThreadByThreadId@4
__imp__NtAlertThreadByThreadId@4: dd _win9x_NtAlertThreadByThreadId@4
global __imp__NtWaitForAlertByThreadId@8
__imp__NtWaitForAlertByThreadId@8: dd _win9x_NtWaitForAlertByThreadId@8
global __imp__NtCancelIoFileEx@12
__imp__NtCancelIoFileEx@12: dd _win9x_NtCancelIoFileEx@12
global __imp__NtCancelSynchronousIoFile@12
__imp__NtCancelSynchronousIoFile@12: dd _win9x_NtCancelSynchronousIoFile@12
global __imp__NtCreateNamedPipeFile@56
__imp__NtCreateNamedPipeFile@56: dd _win9x_NtCreateNamedPipeFile@56
global __imp__NtCreateThreadEx@44
__imp__NtCreateThreadEx@44: dd _win9x_NtCreateThreadEx@44
global __imp__LdrRegisterDllNotification@16
__imp__LdrRegisterDllNotification@16: dd _win9x_LdrRegisterDllNotification@16
global __imp__RtlGetSystemTimePrecise@0
__imp__RtlGetSystemTimePrecise@0: dd _win9x_RtlGetSystemTimePrecise@0
global __imp__RtlReportSilentProcessExit@8
__imp__RtlReportSilentProcessExit@8: dd _win9x_RtlReportSilentProcessExit@8

section .text

; Code thunks: callers that reference the plain `_Foo@N` symbol (not __imp__)
; would otherwise pull kernel32.lib/ntdll.lib's thunk + IAT, duplicating our
; __imp__ data symbol. Defining the thunks here avoids that.

global _AcquireSRWLockExclusive@4
_AcquireSRWLockExclusive@4: jmp _win9x_AcquireSRWLockExclusive@4
global _ReleaseSRWLockExclusive@4
_ReleaseSRWLockExclusive@4: jmp _win9x_ReleaseSRWLockExclusive@4
global _AcquireSRWLockShared@4
_AcquireSRWLockShared@4: jmp _win9x_AcquireSRWLockShared@4
global _ReleaseSRWLockShared@4
_ReleaseSRWLockShared@4: jmp _win9x_ReleaseSRWLockShared@4
global _TryAcquireSRWLockExclusive@4
_TryAcquireSRWLockExclusive@4: jmp _win9x_TryAcquireSRWLockExclusive@4
global _SleepConditionVariableSRW@16
_SleepConditionVariableSRW@16: jmp _win9x_SleepConditionVariableSRW@16
global _WakeConditionVariable@4
_WakeConditionVariable@4: jmp _win9x_WakeConditionVariable@4
global _WakeAllConditionVariable@4
_WakeAllConditionVariable@4: jmp _win9x_WakeAllConditionVariable@4
global _FlsAlloc@4
_FlsAlloc@4: jmp _win9x_FlsAlloc@4
global _FlsGetValue@4
_FlsGetValue@4: jmp _win9x_FlsGetValue@4
global _FlsSetValue@8
_FlsSetValue@8: jmp _win9x_FlsSetValue@8
global _InitOnceExecuteOnce@16
_InitOnceExecuteOnce@16: jmp _win9x_InitOnceExecuteOnce@16
global _GetSystemTimePreciseAsFileTime@4
_GetSystemTimePreciseAsFileTime@4: jmp _win9x_GetSystemTimePreciseAsFileTime@4
global _GetThreadId@4
_GetThreadId@4: jmp _win9x_GetThreadId@4
global _K32EnumProcessModules@16
_K32EnumProcessModules@16: jmp _win9x_K32EnumProcessModules@16
global _NtAlertThread@4
_NtAlertThread@4: jmp _win9x_NtAlertThread@4
global _NtAlertThreadByThreadId@4
_NtAlertThreadByThreadId@4: jmp _win9x_NtAlertThreadByThreadId@4
global _NtWaitForAlertByThreadId@8
_NtWaitForAlertByThreadId@8: jmp _win9x_NtWaitForAlertByThreadId@8
global _NtCancelIoFileEx@12
_NtCancelIoFileEx@12: jmp _win9x_NtCancelIoFileEx@12
global _NtCancelSynchronousIoFile@12
_NtCancelSynchronousIoFile@12: jmp _win9x_NtCancelSynchronousIoFile@12
global _NtCreateNamedPipeFile@56
_NtCreateNamedPipeFile@56: jmp _win9x_NtCreateNamedPipeFile@56
global _NtCreateThreadEx@44
_NtCreateThreadEx@44: jmp _win9x_NtCreateThreadEx@44
global _LdrRegisterDllNotification@16
_LdrRegisterDllNotification@16: jmp _win9x_LdrRegisterDllNotification@16
global _RtlGetSystemTimePrecise@0
_RtlGetSystemTimePrecise@0: jmp _win9x_RtlGetSystemTimePrecise@0
global _RtlReportSilentProcessExit@8
_RtlReportSilentProcessExit@8: jmp _win9x_RtlReportSilentProcessExit@8
