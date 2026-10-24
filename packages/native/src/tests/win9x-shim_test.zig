//! Regression tests for the XP thread-parking shims (win9x_compat.c).
//!
//! Zig std's Io.Threaded.park (Threaded.zig:17782) switches on exactly
//! STATUS_ALERTED (0x101) / STATUS_TIMEOUT (0x102) from
//! NtWaitForAlertByThreadId; any other status hits `unreachable` and panics
//! the process (observed in opencode as `ZIG_PANIC msg=reached unreachable
//! code ra=... rva=0x1c9d57` when the old shim returned STATUS_SUCCESS).
const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;

const NTSTATUS = i32;
const STATUS_ALERTED: NTSTATUS = 0x101;
const STATUS_TIMEOUT: NTSTATUS = 0x102;

extern fn win9x_NtAlertThreadByThreadId(id: ?*anyopaque) callconv(.winapi) NTSTATUS;
extern fn win9x_NtWaitForAlertByThreadId(id: ?*const anyopaque, timeout: ?*const i64) callconv(.winapi) NTSTATUS;

extern "kernel32" fn GetTickCount() callconv(.winapi) u32;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

test "win9x shim: relative timeout returns STATUS_TIMEOUT after the interval" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const start = GetTickCount();
    const interval: i64 = -20 * 10_000; // relative 20ms (negative, 100ns units)
    const status = win9x_NtWaitForAlertByThreadId(null, &interval);
    const elapsed = GetTickCount() - start;

    try expect(status == STATUS_TIMEOUT);
    // Slept the requested interval rather than returning after ~1ms
    // (the old stub ignored the interval entirely).
    try expect(elapsed >= 15);
    // And did not block anywhere near the 5s ceiling used by the wake test.
    try expect(elapsed < 1000);
}

test "win9x shim: zero timeout returns STATUS_TIMEOUT immediately" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const zero: i64 = 0;
    const status = win9x_NtWaitForAlertByThreadId(null, &zero);
    try expect(status == STATUS_TIMEOUT);
}

test "win9x shim: past absolute deadline returns STATUS_TIMEOUT immediately" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const past: i64 = 1; // absolute time just after the 1601 epoch
    const status = win9x_NtWaitForAlertByThreadId(null, &past);
    try expect(status == STATUS_TIMEOUT);
}

test "win9x shim: NtAlertThreadByThreadId wakes a parked thread with STATUS_ALERTED" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const self_tid: u32 = @intCast(std.Thread.getCurrentId());

    const helper = try std.Thread.spawn(.{}, struct {
        fn run(tid: u32) void {
            // QueueUserAPC keeps the APC pending until the target enters an
            // alertable wait, so alerting before (or during) SleepEx is fine;
            // the short sleep just exercises the "parked already" ordering.
            Sleep(30);
            _ = win9x_NtAlertThreadByThreadId(@ptrFromInt(@as(usize, tid)));
        }
    }.run, .{self_tid});
    defer helper.join();

    // Bounded park: if the wake regresses the test fails with TIMEOUT
    // instead of hanging the suite. 5s also caps the old-bug case where
    // the shim ignored the interval and returned instantly.
    const interval: i64 = -5 * 1000 * 10_000;
    const status = win9x_NtWaitForAlertByThreadId(null, &interval);

    try expect(status == STATUS_ALERTED);
}
