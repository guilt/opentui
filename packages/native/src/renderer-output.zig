//! Output transport backends for `CliRenderer`.
//!
//! The renderer's render path writes ANSI bytes into an abstract writer
//! supplied by an `OutputBackend`. Two variants are available:
//!
//!   - `BufferedBackend`: writes into per-renderer A/B frame buffers, then
//!     flushes committed bytes to an injected `BufferedOutput`.
//!
//!   - `FeedBackend`: stages each complete frame, then atomically publishes it
//!     to a `NativeSpanFeed.Stream` whose chunks are consumed from TypeScript
//!     and piped to a user-supplied Writable (typically an SSH channel).
//!
//! The backend is a tagged union. `CliRenderer.render` performs exactly one
//! `switch` on the backend using `inline else` to pick the right variant's
//! writer type at compile time — keeping the render path generic over the
//! writer without scattering backend-specific switches across the codebase.

const std = @import("std");
const builtin = @import("builtin");
const io = if (builtin.is_test) std.testing.io else @import("root").io;
const Allocator = std.mem.Allocator;
const NativeSpanFeed = @import("native-span-feed.zig");
const ansi = @import("ansi.zig");

pub const OUTPUT_BUFFER_SIZE = 1024 * 1024 * 2; // 2 MiB, double-buffered per BufferedBackend for thread handoff
const UTF16_BUFFER_SIZE = 4096;

const CHAR_INFO = extern struct {
    Char: extern union {
        UnicodeChar: u16,
        AsciiChar: u8,
    },
    Attributes: u16,
};

const SMALL_RECT = extern struct {
    Left: i16,
    Top: i16,
    Right: i16,
    Bottom: i16,
};

const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: std.os.windows.COORD,
    dwCursorPosition: std.os.windows.COORD,
    wAttributes: u16,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: std.os.windows.COORD,
};

const CONSOLE_CURSOR_INFO = extern struct {
    dwSize: std.os.windows.DWORD,
    bVisible: std.os.windows.BOOL,
};

const WindowsConsole = struct {
    extern "kernel32" fn GetConsoleMode(
        handle: std.os.windows.HANDLE,
        mode: *std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn SetConsoleMode(
        handle: std.os.windows.HANDLE,
        mode: std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) std.os.windows.UINT;
    extern "kernel32" fn SetConsoleOutputCP(code_page: std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn WriteConsoleW(
        handle: std.os.windows.HANDLE,
        buffer: [*]const u16,
        chars_to_write: std.os.windows.DWORD,
        chars_written: ?*std.os.windows.DWORD,
        reserved: ?*anyopaque,
    ) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn GetConsoleScreenBufferInfo(
        handle: std.os.windows.HANDLE,
        info: *CONSOLE_SCREEN_BUFFER_INFO,
    ) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn WriteConsoleOutputW(
        handle: std.os.windows.HANDLE,
        buffer: [*]const CHAR_INFO,
        buffer_size: std.os.windows.COORD,
        buffer_coord: std.os.windows.COORD,
        write_region: *SMALL_RECT,
    ) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn ReadConsoleOutputW(
        handle: std.os.windows.HANDLE,
        buffer: [*]CHAR_INFO,
        buffer_size: std.os.windows.COORD,
        buffer_coord: std.os.windows.COORD,
        read_region: *SMALL_RECT,
    ) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn SetConsoleCursorPosition(
        handle: std.os.windows.HANDLE,
        position: std.os.windows.COORD,
    ) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn SetConsoleCursorInfo(
        handle: std.os.windows.HANDLE,
        info: *const CONSOLE_CURSOR_INFO,
    ) callconv(.winapi) std.os.windows.BOOL;
};

const ENABLE_VT: std.os.windows.DWORD = std.os.windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING;

pub const WriteStatus = enum(u8) {
    ok = 0,
    skipped = 1,
    failed = 2,
};

pub const BufferedWriteFn = *const fn (ctx: *anyopaque, data: []const u8) void;

pub const BufferedOutput = struct {
    ctx: *anyopaque,
    write_fn: BufferedWriteFn,
    thread_safe: bool = false,

    pub fn write(self: BufferedOutput, data: []const u8) void {
        self.write_fn(self.ctx, data);
    }
};

const Utf16Chunk = struct {
    input_len: usize,
    output_len: usize,
};

fn utf8ToUtf16Chunk(output: []u16, input: []const u8) error{InvalidUtf8}!Utf16Chunk {
    std.debug.assert(output.len >= 2);

    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < input.len) {
        const first_byte = input[input_index];
        if (first_byte < 0x80) {
            if (output_index == output.len) break;
            output[output_index] = first_byte;
            input_index += 1;
            output_index += 1;
            continue;
        }

        const sequence_len = std.unicode.utf8ByteSequenceLength(first_byte) catch return error.InvalidUtf8;
        if (input.len - input_index < sequence_len) return error.InvalidUtf8;
        const codepoint = std.unicode.utf8Decode(input[input_index..][0..sequence_len]) catch return error.InvalidUtf8;
        const output_len: usize = if (codepoint < 0x10000) 1 else 2;
        if (output.len - output_index < output_len) break;

        if (output_len == 1) {
            output[output_index] = @intCast(codepoint);
        } else {
            const value = codepoint - 0x10000;
            output[output_index] = @intCast(0xD800 + (value >> 10));
            output[output_index + 1] = @intCast(0xDC00 + (value & 0x3FF));
        }
        input_index += sequence_len;
        output_index += output_len;
    }

    return .{ .input_len = input_index, .output_len = output_index };
}

test "stdout write failures remain observable for resource cleanup" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const full = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/full", .{ .mode = .write_only });
    defer full.close(std.testing.io);
    var stdout_output = StdoutOutput.initForFile(std.testing.allocator, full);
    defer stdout_output.deinit();
    stdout_output.bufferedOutput().write("cannot write");
    try std.testing.expect(stdout_output.failed.load(.acquire));
}

test "UTF-8 output converts to UTF-16" {
    const input = "Aé東😀";
    const expected = [_]u16{ 'A', 0x00E9, 0x6771, 0xD83D, 0xDE00 };
    var output: [expected.len]u16 = undefined;

    const result = try utf8ToUtf16Chunk(&output, input);

    try std.testing.expectEqual(input.len, result.input_len);
    try std.testing.expectEqual(expected.len, result.output_len);
    try std.testing.expectEqualSlices(u16, &expected, output[0..result.output_len]);
}

test "UTF-8 output chunking does not split surrogate pairs" {
    const input = "A😀B";
    var output: [2]u16 = undefined;

    const first = try utf8ToUtf16Chunk(&output, input);
    try std.testing.expectEqual(@as(usize, 1), first.input_len);
    try std.testing.expectEqualSlices(u16, &.{'A'}, output[0..first.output_len]);

    const second = try utf8ToUtf16Chunk(&output, input[first.input_len..]);
    try std.testing.expectEqual(@as(usize, 4), second.input_len);
    try std.testing.expectEqualSlices(u16, &.{ 0xD83D, 0xDE00 }, output[0..second.output_len]);

    const third_offset = first.input_len + second.input_len;
    const third = try utf8ToUtf16Chunk(&output, input[third_offset..]);
    try std.testing.expectEqual(@as(usize, 1), third.input_len);
    try std.testing.expectEqualSlices(u16, &.{'B'}, output[0..third.output_len]);
}

test "UTF-8 output conversion is bounded by the UTF-16 buffer" {
    const input = "x" ** (UTF16_BUFFER_SIZE + 1);
    var output: [UTF16_BUFFER_SIZE]u16 = undefined;

    const first = try utf8ToUtf16Chunk(&output, input);
    try std.testing.expectEqual(@as(usize, UTF16_BUFFER_SIZE), first.input_len);
    try std.testing.expectEqual(@as(usize, UTF16_BUFFER_SIZE), first.output_len);

    const second = try utf8ToUtf16Chunk(&output, input[first.input_len..]);
    try std.testing.expectEqual(@as(usize, 1), second.input_len);
    try std.testing.expectEqualSlices(u16, &.{'x'}, output[0..second.output_len]);
}

test "UTF-8 output rejects invalid and incomplete input" {
    var output: [8]u16 = undefined;

    try std.testing.expectError(error.InvalidUtf8, utf8ToUtf16Chunk(&output, "\xFF"));
    try std.testing.expectError(error.InvalidUtf8, utf8ToUtf16Chunk(&output, "\xF0\x9F"));
}

fn isWindowsConsole(file: std.Io.File) bool {
    if (builtin.os.tag != .windows) return false;

    var console_mode: std.os.windows.DWORD = 0;
    return WindowsConsole.GetConsoleMode(file.handle, &console_mode).toBool();
}

/// Returns true when `file` is a Windows console whose mode already has, or can
/// be switched to, ENABLE_VIRTUAL_TERMINAL_PROCESSING. Bun enables the flag at
/// startup and ignores failure, so legacy hosts (XP conhost) never get VT
/// interpretation; probe the read-back so callers can pick a cell-based path.
fn supportsVirtualTerminal(file: std.Io.File) bool {
    if (builtin.os.tag != .windows) return false;
    // VT processing only exists on Windows 10+. A legacy conhost may accept
    // the unknown mode bit without acting on it, which would let the read-back
    // probe lie, so gate on the version first.
    if (!isWindowsVersionAtLeast10()) return false;

    var mode: std.os.windows.DWORD = 0;
    if (!WindowsConsole.GetConsoleMode(file.handle, &mode).toBool()) return false;
    if (mode & ENABLE_VT != 0) return true;

    if (!WindowsConsole.SetConsoleMode(file.handle, mode | ENABLE_VT).toBool()) return false;
    var verify: std.os.windows.DWORD = 0;
    if (!WindowsConsole.GetConsoleMode(file.handle, &verify).toBool()) return false;
    return verify & ENABLE_VT != 0;
}

/// RtlGetVersion (ntdll) is not manifest-shimmed the way GetVersionExW is, so
/// it reports the real major version on every OS we support.
fn isWindowsVersionAtLeast10() bool {
    if (builtin.os.tag != .windows) return false;

    var version_info: std.os.windows.RTL_OSVERSIONINFOW = undefined;
    version_info.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
    const status = std.os.windows.ntdll.RtlGetVersion(&version_info);
    if (status != .SUCCESS) return false;
    return version_info.dwMajorVersion >= 10;
}

test "supportsVirtualTerminal rejects non-console handles" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "vt-probe", .{});
    defer file.close(std.testing.io);
    try std.testing.expect(!supportsVirtualTerminal(file));
}

test "supportsVirtualTerminal accepts a VT-capable console" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    if (!isWindowsVersionAtLeast10()) return error.SkipZigTest;
    if (!isWindowsConsole(std.Io.File.stdout())) return error.SkipZigTest;
    try std.testing.expect(supportsVirtualTerminal(std.Io.File.stdout()));
}

/// Cell-based fallback for legacy conhosts (Windows < 10, including XP) that
/// ignore VT sequences even when the mode flag is accepted. Parses the
/// renderer's ANSI byte stream into a shadow window of CHAR_INFO cells so
/// output can be blitted with WriteConsoleOutputW, which XP does interpret.
///
/// The parser is pure (no Win32 calls) so it is unit-testable anywhere;
/// StdoutOutput owns the console calls that blit `cells` and place the cursor.
const LegacyScreen = struct {
    const State = enum { ground, esc, esc_inter, csi, osc, string, charset };
    const MAX_CSI_PARAMS = 16;

    allocator: Allocator,
    cells: []CHAR_INFO,
    /// Snapshot of `cells` taken when the alternate screen is entered.
    /// Null when the dupe failed (exit then clears instead of restoring).
    alt_cells: ?[]CHAR_INFO = null,
    width: u16,
    height: u16,

    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    /// Deferred wrap: the cell at the right margin has been written but the
    /// cursor has not moved yet; the next printable wraps first.
    pending_wrap: bool = false,
    cursor_visible: bool = true,
    autowrap: bool = true,
    /// Single save slot shared by DECSC/DECRC, CSI s/u, and `?1049` alt entry.
    saved_x: u16 = 0,
    saved_y: u16 = 0,

    /// SGR colors stored as win32 0-15 color patterns (bold/underline/inverse
    /// are applied when a cell is written, not stored here).
    fg: u16,
    bg: u16,
    default_fg: u16,
    default_bg: u16,
    bold: bool = false,
    underline: bool = false,
    inverse: bool = false,

    scroll_top: u16,
    scroll_bottom: u16, // inclusive

    dirty: bool = false,
    in_alt: bool = false,

    state: State = .ground,
    csi_params: [MAX_CSI_PARAMS]u16 = undefined,
    csi_count: usize = 0,
    csi_current: u16 = 0,
    csi_intermediate: u8 = 0,
    csi_private: u8 = 0,

    utf8_buf: [4]u8 = undefined,
    utf8_len: u8 = 0,
    utf8_need: u8 = 0,

    fn init(allocator: Allocator, width: u16, height: u16, w_attributes: u16) !LegacyScreen {
        if (width == 0 or height == 0) return error.ZeroSize;
        const cells = try allocator.alloc(CHAR_INFO, @as(usize, width) * @as(usize, height));
        errdefer allocator.free(cells);

        const default_fg: u16 = w_attributes & 0xF;
        const default_bg: u16 = (w_attributes >> 4) & 0xF;
        const erase_attr = default_fg | (default_bg << 4);
        for (cells) |*cell| {
            cell.* = .{ .Char = .{ .UnicodeChar = ' ' }, .Attributes = erase_attr };
        }

        return .{
            .allocator = allocator,
            .cells = cells,
            .width = width,
            .height = height,
            .fg = default_fg,
            .bg = default_bg,
            .default_fg = default_fg,
            .default_bg = default_bg,
            .scroll_top = 0,
            .scroll_bottom = height - 1,
        };
    }

    fn deinit(self: *LegacyScreen) void {
        self.allocator.free(self.cells);
        if (self.alt_cells) |alt| self.allocator.free(alt);
    }

    /// Attach to a live console: size/colors from GetConsoleScreenBufferInfo,
    /// shadow seeded with ReadConsoleOutputW so alt-screen exit restores
    /// whatever the shell had on screen.
    fn initForConsole(allocator: Allocator, file: std.Io.File) !LegacyScreen {
        if (builtin.os.tag != .windows) return error.NotConsole;
        return initForConsoleWindows(allocator, file);
    }

    fn initForConsoleWindows(allocator: Allocator, file: std.Io.File) !LegacyScreen {
        var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (!WindowsConsole.GetConsoleScreenBufferInfo(file.handle, &info).toBool()) return error.NotConsole;

        const win_w: u16 = @intCast(@max(@as(i32, info.srWindow.Right) - @as(i32, info.srWindow.Left) + 1, 1));
        const win_h: u16 = @intCast(@max(@as(i32, info.srWindow.Bottom) - @as(i32, info.srWindow.Top) + 1, 1));
        var screen = try LegacyScreen.init(allocator, win_w, win_h, info.wAttributes);
        errdefer screen.deinit();

        // Best effort: on failure the blank fill from init stands.
        _ = WindowsConsole.ReadConsoleOutputW(
            file.handle,
            screen.cells.ptr,
            .{ .X = @intCast(win_w), .Y = @intCast(win_h) },
            .{ .X = 0, .Y = 0 },
            &info.srWindow,
        );

        const cursor_x = @as(i32, info.dwCursorPosition.X) - @as(i32, info.srWindow.Left);
        const cursor_y = @as(i32, info.dwCursorPosition.Y) - @as(i32, info.srWindow.Top);
        screen.cursor_x = @intCast(std.math.clamp(cursor_x, 0, @as(i32, win_w) - 1));
        screen.cursor_y = @intCast(std.math.clamp(cursor_y, 0, @as(i32, win_h) - 1));
        screen.saved_x = screen.cursor_x;
        screen.saved_y = screen.cursor_y;
        return screen;
    }

    fn feed(self: *LegacyScreen, data: []const u8) void {
        for (data) |byte| {
            switch (self.state) {
                .ground => self.groundByte(byte),
                .esc => self.escByte(byte),
                .esc_inter, .charset => {
                    self.state = .ground;
                },
                .csi => self.csiByte(byte),
                .osc, .string => self.stringByte(byte),
            }
        }
        if (data.len > 0) self.dirty = true;
    }

    fn groundByte(self: *LegacyScreen, byte: u8) void {
        if (byte == 0x1B) {
            self.state = .esc;
            return;
        }
        if (byte < 0x20) {
            self.control(byte);
            return;
        }
        if (byte == 0x7F) return;

        const b = byte;
        while (true) {
            if (b < 0x80) {
                self.putCodepoint(b);
                return;
            }
            if (self.utf8_need == 0) {
                const sequence_len: u8 = std.unicode.utf8ByteSequenceLength(b) catch {
                    self.putCodepoint(0xFFFD);
                    return;
                };
                if (sequence_len == 1) {
                    self.putCodepoint(b);
                    return;
                }
                self.utf8_buf[0] = b;
                self.utf8_len = 1;
                self.utf8_need = sequence_len;
                return;
            }
            if ((b & 0xC0) != 0x80) {
                // Broken sequence: emit a replacement, then reprocess the byte
                // as a fresh start.
                self.utf8_need = 0;
                self.utf8_len = 0;
                self.putCodepoint(0xFFFD);
                continue;
            }
            self.utf8_buf[self.utf8_len] = b;
            self.utf8_len += 1;
            if (self.utf8_len == self.utf8_need) {
                const cp: u21 = std.unicode.utf8Decode(self.utf8_buf[0..self.utf8_need]) catch 0xFFFD;
                self.utf8_need = 0;
                self.utf8_len = 0;
                self.putCodepoint(cp);
            }
            return;
        }
    }

    fn control(self: *LegacyScreen, byte: u8) void {
        switch (byte) {
            0x08 => {
                self.pending_wrap = false;
                if (self.cursor_x > 0) self.cursor_x -= 1;
            },
            0x09 => {
                self.pending_wrap = false;
                const next_tab = (self.cursor_x / 8 + 1) * 8;
                self.cursor_x = @min(next_tab, self.width - 1);
            },
            0x0A, 0x0B, 0x0C => {
                self.pending_wrap = false;
                self.lineFeed();
            },
            0x0D => {
                self.cursor_x = 0;
                self.pending_wrap = false;
            },
            else => {},
        }
    }

    fn escByte(self: *LegacyScreen, byte: u8) void {
        switch (byte) {
            '[' => {
                self.resetCsi();
                self.state = .csi;
            },
            ']' => {
                self.state = .osc;
            },
            'P', 'X', '^', '_' => {
                self.state = .string;
            },
            '(', ')', '*', '+', '#', '%' => {
                self.state = .esc_inter;
            },
            '7' => {
                self.saveCursor();
                self.state = .ground;
            },
            '8' => {
                self.restoreCursor();
                self.state = .ground;
            },
            'D' => {
                self.pending_wrap = false;
                self.lineFeed();
                self.state = .ground;
            },
            'E' => {
                self.pending_wrap = false;
                self.cursor_x = 0;
                self.lineFeed();
                self.state = .ground;
            },
            'M' => {
                self.pending_wrap = false;
                self.reverseIndex();
                self.state = .ground;
            },
            'c' => {
                self.fullReset();
                self.state = .ground;
            },
            0x1B => {},
            else => {
                self.state = .ground;
            },
        }
    }

    /// OSC, DCS, APC, PM, SOS payloads have no cell effect. Both BEL and ESC
    /// end the string (ESC hands the next byte to the escape state so a
    /// premature ST/new sequence still parses correctly).
    fn stringByte(self: *LegacyScreen, byte: u8) void {
        switch (byte) {
            0x07 => {
                self.state = .ground;
            },
            0x1B => {
                self.state = .esc;
            },
            else => {},
        }
    }

    fn csiByte(self: *LegacyScreen, byte: u8) void {
        if (byte == 0x1B) {
            self.state = .esc;
            return;
        }
        if (byte < 0x20) {
            self.control(byte);
            return;
        }
        if (byte >= 0x40 and byte <= 0x7E) {
            self.dispatchCsi(byte);
            self.state = .ground;
            return;
        }
        if (byte >= 0x20 and byte <= 0x2F) {
            self.csi_intermediate = byte;
            return;
        }
        if (byte >= '0' and byte <= '9') {
            if (self.csi_current < 1000) self.csi_current = self.csi_current * 10 + @as(u16, byte - '0');
            return;
        }
        if (byte == ';' or byte == ':') {
            // ':' is treated like ';' so ITU-T colon sub-params still land in
            // the flat parameter list the renderer's sequences use.
            self.pushCsiParam();
            return;
        }
        if (byte == '?' or byte == '>' or byte == '<' or byte == '=') {
            if (self.csi_count == 0 and self.csi_current == 0) self.csi_private = byte;
            return;
        }
        // Unexpected byte: drop the sequence.
        self.state = .ground;
    }

    fn dispatchCsi(self: *LegacyScreen, final_byte: u8) void {
        if (self.csi_count > 0 or self.csi_current > 0) self.pushCsiParam();

        if (self.csi_intermediate != 0) {
            // DECSTR (`CSI ! p`); other intermediate sequences are cursor or
            // window queries with no shadow-screen effect.
            if (self.csi_intermediate == '!' and final_byte == 'p') {
                self.fullReset();
            }
            return;
        }

        // Only DECSET/DECRST act on private modes; mouse reports and
        // modifyOtherKeys carry a private prefix but never change cells.
        if (self.csi_private != 0 and final_byte != 'h' and final_byte != 'l') return;

        switch (final_byte) {
            'H', 'f' => self.moveCursor(self.param(1, 1) -| 1, self.param(0, 1) -| 1),
            'A' => self.moveCursorRel(0, -@as(i32, self.paramOr1(0))),
            'B' => self.moveCursorRel(0, @as(i32, self.paramOr1(0))),
            'C' => self.moveCursorRel(@as(i32, self.paramOr1(0)), 0),
            'D' => self.moveCursorRel(-@as(i32, self.paramOr1(0)), 0),
            'E' => {
                self.moveCursorRel(0, @as(i32, self.paramOr1(0)));
                self.cursor_x = 0;
            },
            'F' => {
                self.moveCursorRel(0, -@as(i32, self.paramOr1(0)));
                self.cursor_x = 0;
            },
            'G', '`' => self.moveCursor(self.param(0, 1) -| 1, self.cursor_y),
            'd' => self.moveCursor(self.cursor_x, self.param(0, 1) -| 1),
            'J' => self.eraseDisplay(@min(self.param(0, 0), 3)),
            'K' => self.eraseLine(@min(self.param(0, 0), 2)),
            'X' => self.eraseChars(self.paramOr1(0)),
            'm' => self.sgr(),
            'h' => self.setModes(true),
            'l' => self.setModes(false),
            'r' => {
                const top = self.param(0, 1) -| 1;
                const bottom = self.param(1, self.height) -| 1;
                if (top < bottom and bottom < self.height) {
                    self.scroll_top = top;
                    self.scroll_bottom = bottom;
                } else {
                    self.scroll_top = 0;
                    self.scroll_bottom = self.height - 1;
                }
                // DECSTBM homes the cursor; both renderer call sites
                // reposition explicitly afterwards.
                self.moveCursor(0, 0);
            },
            's' => {
                self.saved_x = self.cursor_x;
                self.saved_y = self.cursor_y;
            },
            'u' => self.moveCursor(self.saved_x, self.saved_y),
            'S' => self.scrollUp(self.paramOr1(0)),
            'T' => self.scrollDown(self.paramOr1(0)),
            'L' => self.insertLines(self.paramOr1(0)),
            'M' => self.deleteLines(self.paramOr1(0)),
            '@' => self.insertChars(self.paramOr1(0)),
            'P' => self.deleteChars(self.paramOr1(0)),
            // Queries (DSR, DA, DECRQM, cursor style, window ops) get no
            // reply: the renderer's capability timeouts already expect the
            // silence from a legacy console.
            else => {},
        }
    }

    fn resetCsi(self: *LegacyScreen) void {
        self.csi_count = 0;
        self.csi_current = 0;
        self.csi_intermediate = 0;
        self.csi_private = 0;
    }

    fn pushCsiParam(self: *LegacyScreen) void {
        if (self.csi_count < MAX_CSI_PARAMS) {
            self.csi_params[self.csi_count] = self.csi_current;
            self.csi_count += 1;
        }
        self.csi_current = 0;
    }

    fn param(self: *LegacyScreen, index: usize, default: u16) u16 {
        if (index >= self.csi_count) return default;
        return self.csi_params[index];
    }

    fn paramOr1(self: *LegacyScreen, index: usize) u16 {
        const value = self.param(index, 1);
        return if (value == 0) 1 else value;
    }

    fn sgr(self: *LegacyScreen) void {
        if (self.csi_count == 0) {
            self.resetSgr();
            return;
        }
        var i: usize = 0;
        while (i < self.csi_count) {
            const mode = self.csi_params[i];
            i += 1;
            switch (mode) {
                0 => self.resetSgr(),
                1 => self.bold = true,
                4 => self.underline = true,
                7 => self.inverse = true,
                21, 22 => self.bold = false,
                24 => self.underline = false,
                27 => self.inverse = false,
                30...37 => self.fg = ansiIndexToWinNibble(mode - 30),
                39 => self.fg = self.default_fg,
                40...47 => self.bg = ansiIndexToWinNibble(mode - 40),
                49 => self.bg = self.default_bg,
                90...97 => self.fg = ansiIndexToWinNibble(mode - 90 + 8),
                100...107 => self.bg = ansiIndexToWinNibble(mode - 100 + 8),
                38, 48 => {
                    const is_fg = mode == 38;
                    if (i >= self.csi_count) break;
                    const sub_mode = self.csi_params[i];
                    i += 1;
                    if (sub_mode == 5) {
                        if (i >= self.csi_count) break;
                        const index = self.csi_params[i];
                        i += 1;
                        const color: u16 = if (index < 16)
                            ansiIndexToWinNibble(index)
                        else blk: {
                            const rgba = ansi.fallbackAnsi256Color(index);
                            break :blk nearestAnsi16Nibble(ansi.red(rgba), ansi.green(rgba), ansi.blue(rgba));
                        };
                        if (is_fg) self.fg = color else self.bg = color;
                    } else if (sub_mode == 2) {
                        if (i + 2 >= self.csi_count) break;
                        const r: u8 = @intCast(@min(self.csi_params[i], 255));
                        const g: u8 = @intCast(@min(self.csi_params[i + 1], 255));
                        const b: u8 = @intCast(@min(self.csi_params[i + 2], 255));
                        i += 3;
                        const color = nearestAnsi16Nibble(r, g, b);
                        if (is_fg) self.fg = color else self.bg = color;
                    }
                    // Unknown/extended sub-mode: skip it, keep parsing.
                },
                else => {},
            }
        }
    }

    fn resetSgr(self: *LegacyScreen) void {
        self.fg = self.default_fg;
        self.bg = self.default_bg;
        self.bold = false;
        self.underline = false;
        self.inverse = false;
    }

    fn setModes(self: *LegacyScreen, enable: bool) void {
        if (self.csi_private != '?') return;
        for (self.csi_params[0..self.csi_count]) |mode| {
            switch (mode) {
                7 => self.autowrap = enable,
                25 => self.cursor_visible = enable,
                47, 1047, 1049 => self.setAltScreen(enable),
                else => {},
            }
        }
    }

    fn setAltScreen(self: *LegacyScreen, enable: bool) void {
        if (enable) {
            if (self.in_alt) return;
            self.alt_cells = self.allocator.dupe(CHAR_INFO, self.cells) catch null;
            self.saveCursor();
            self.fillCells(0, self.cells.len);
            self.in_alt = true;
        } else {
            if (!self.in_alt) return;
            if (self.alt_cells) |alt| {
                if (alt.len == self.cells.len) @memcpy(self.cells, alt);
                self.allocator.free(alt);
                self.alt_cells = null;
            } else {
                // Snapshot allocation failed (or the screen was resized):
                // clear instead of restoring stale cells.
                self.fillCells(0, self.cells.len);
            }
            self.in_alt = false;
            self.restoreCursor();
        }
    }

    fn fullReset(self: *LegacyScreen) void {
        self.state = .ground;
        self.resetCsi();
        self.utf8_len = 0;
        self.utf8_need = 0;
        self.resetSgr();
        self.autowrap = true;
        self.cursor_visible = true;
        self.scroll_top = 0;
        self.scroll_bottom = self.height - 1;
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.pending_wrap = false;
    }

    fn putCodepoint(self: *LegacyScreen, cp: u21) void {
        if (isZeroWidth(cp)) return;
        if (self.pending_wrap) {
            self.pending_wrap = false;
            self.cursor_x = 0;
            self.lineFeed();
        }
        const x = self.cursor_x;
        const y = self.cursor_y;
        const char: u16 = if (cp > 0xFFFF) '?' else @intCast(cp);
        self.setCell(x, y, char, self.currentAttr());
        if (x < self.width - 1) {
            self.cursor_x = x + 1;
        } else if (self.autowrap) {
            self.pending_wrap = true;
        }
    }

    fn setCell(self: *LegacyScreen, x: u16, y: u16, char: u16, attr: u16) void {
        self.cells[@as(usize, y) * @as(usize, self.width) + @as(usize, x)] = .{
            .Char = .{ .UnicodeChar = char },
            .Attributes = attr,
        };
        self.dirty = true;
    }

    fn charAt(self: *const LegacyScreen, x: u16, y: u16) u16 {
        return self.cells[@as(usize, y) * @as(usize, self.width) + @as(usize, x)].Char.UnicodeChar;
    }

    fn attrAt(self: *const LegacyScreen, x: u16, y: u16) u16 {
        return self.cells[@as(usize, y) * @as(usize, self.width) + @as(usize, x)].Attributes;
    }

    /// win32 attribute for a cell at write time: bold ORs foreground
    /// intensity, inverse swaps the color nibbles, underline sets
    /// COMMON_LVB_UNDERSCORE.
    fn currentAttr(self: *const LegacyScreen) u16 {
        var fg = self.fg;
        var bg = self.bg;
        if (self.bold) fg |= 0x8;
        if (self.inverse) std.mem.swap(u16, &fg, &bg);
        var attr = (bg << 4) | fg;
        if (self.underline) attr |= 0x8000;
        return attr;
    }

    /// Erase uses the plain current colors (no bold/underline/inverse).
    fn eraseAttr(self: *const LegacyScreen) u16 {
        return (self.fg & 0xF) | ((self.bg & 0xF) << 4);
    }

    fn fillCells(self: *LegacyScreen, offset: usize, len: usize) void {
        std.debug.assert(offset + len <= self.cells.len);
        const attr = self.eraseAttr();
        for (self.cells[offset..][0..len]) |*cell| {
            cell.* = .{ .Char = .{ .UnicodeChar = ' ' }, .Attributes = attr };
        }
        self.dirty = true;
    }

    fn moveCursor(self: *LegacyScreen, x: u16, y: u16) void {
        self.cursor_x = @min(x, self.width - 1);
        self.cursor_y = @min(y, self.height - 1);
        self.pending_wrap = false;
    }

    fn moveCursorRel(self: *LegacyScreen, dx: i32, dy: i32) void {
        const x = std.math.clamp(@as(i32, self.cursor_x) + dx, 0, @as(i32, self.width) - 1);
        const y = std.math.clamp(@as(i32, self.cursor_y) + dy, 0, @as(i32, self.height) - 1);
        self.cursor_x = @intCast(x);
        self.cursor_y = @intCast(y);
        self.pending_wrap = false;
    }

    fn saveCursor(self: *LegacyScreen) void {
        self.saved_x = self.cursor_x;
        self.saved_y = self.cursor_y;
    }

    fn restoreCursor(self: *LegacyScreen) void {
        self.cursor_x = @min(self.saved_x, self.width - 1);
        self.cursor_y = @min(self.saved_y, self.height - 1);
        self.pending_wrap = false;
    }

    fn lineFeed(self: *LegacyScreen) void {
        if (self.cursor_y == self.scroll_bottom) {
            self.scrollUp(1);
        } else if (self.cursor_y < self.height - 1) {
            self.cursor_y += 1;
        }
    }

    fn reverseIndex(self: *LegacyScreen) void {
        if (self.cursor_y == self.scroll_top) {
            self.scrollDown(1);
        } else if (self.cursor_y > 0) {
            self.cursor_y -= 1;
        }
    }

    fn scrollUp(self: *LegacyScreen, count: u16) void {
        const top = self.scroll_top;
        const bottom = self.scroll_bottom;
        if (bottom <= top) return;
        const region_rows = bottom - top + 1;
        const shift: u16 = @min(count, region_rows);
        const stride: usize = self.width;
        const move_rows: usize = region_rows - shift;
        if (move_rows > 0) {
            const dst = @as(usize, top) * stride;
            const src = @as(usize, top + shift) * stride;
            std.mem.copyForwards(CHAR_INFO, self.cells[dst..][0 .. move_rows * stride], self.cells[src..][0 .. move_rows * stride]);
        }
        const blank = @as(usize, bottom - shift + 1) * stride;
        self.fillCells(blank, @as(usize, shift) * stride);
    }

    fn scrollDown(self: *LegacyScreen, count: u16) void {
        const top = self.scroll_top;
        const bottom = self.scroll_bottom;
        if (bottom <= top) return;
        const region_rows = bottom - top + 1;
        const shift: u16 = @min(count, region_rows);
        const stride: usize = self.width;
        const move_rows: usize = region_rows - shift;
        if (move_rows > 0) {
            const src = @as(usize, top) * stride;
            const dst = @as(usize, top + shift) * stride;
            std.mem.copyBackwards(CHAR_INFO, self.cells[dst..][0 .. move_rows * stride], self.cells[src..][0 .. move_rows * stride]);
        }
        const blank = @as(usize, top) * stride;
        self.fillCells(blank, @as(usize, shift) * stride);
    }

    fn insertLines(self: *LegacyScreen, count: u16) void {
        if (self.cursor_y < self.scroll_top or self.cursor_y > self.scroll_bottom) return;
        const stride: usize = self.width;
        const region_rows = self.scroll_bottom - self.cursor_y + 1;
        const shift: u16 = @min(count, region_rows);
        const move_rows: usize = region_rows - shift;
        if (move_rows > 0) {
            const src = @as(usize, self.cursor_y) * stride;
            const dst = @as(usize, self.cursor_y + shift) * stride;
            std.mem.copyBackwards(CHAR_INFO, self.cells[dst..][0 .. move_rows * stride], self.cells[src..][0 .. move_rows * stride]);
        }
        const blank = @as(usize, self.cursor_y) * stride;
        self.fillCells(blank, @as(usize, shift) * stride);
    }

    fn deleteLines(self: *LegacyScreen, count: u16) void {
        if (self.cursor_y < self.scroll_top or self.cursor_y > self.scroll_bottom) return;
        const stride: usize = self.width;
        const region_rows = self.scroll_bottom - self.cursor_y + 1;
        const shift: u16 = @min(count, region_rows);
        const move_rows: usize = region_rows - shift;
        if (move_rows > 0) {
            const src = @as(usize, self.cursor_y + shift) * stride;
            const dst = @as(usize, self.cursor_y) * stride;
            std.mem.copyForwards(CHAR_INFO, self.cells[dst..][0 .. move_rows * stride], self.cells[src..][0 .. move_rows * stride]);
        }
        const blank = @as(usize, self.scroll_bottom - shift + 1) * stride;
        self.fillCells(blank, @as(usize, shift) * stride);
    }

    fn insertChars(self: *LegacyScreen, count: u16) void {
        const stride: usize = self.width;
        const row = @as(usize, self.cursor_y) * stride;
        const from = @as(usize, self.cursor_x);
        const avail = stride - from;
        const shift: usize = @min(count, avail);
        const move = avail - shift;
        if (move > 0) {
            std.mem.copyBackwards(CHAR_INFO, self.cells[row + from + shift ..][0..move], self.cells[row + from ..][0..move]);
        }
        self.fillCells(row + from, shift);
    }

    fn deleteChars(self: *LegacyScreen, count: u16) void {
        const stride: usize = self.width;
        const row = @as(usize, self.cursor_y) * stride;
        const from = @as(usize, self.cursor_x);
        const avail = stride - from;
        const shift: usize = @min(count, avail);
        const move = avail - shift;
        if (move > 0) {
            std.mem.copyForwards(CHAR_INFO, self.cells[row + from ..][0..move], self.cells[row + from + shift ..][0..move]);
        }
        self.fillCells(row + from + move, shift);
    }

    fn eraseDisplay(self: *LegacyScreen, mode: u16) void {
        const stride: usize = self.width;
        switch (mode) {
            0 => {
                const row = @as(usize, self.cursor_y) * stride;
                self.fillCells(row + self.cursor_x, stride - self.cursor_x);
                if (self.cursor_y < self.height - 1) {
                    const below = @as(usize, self.cursor_y + 1) * stride;
                    self.fillCells(below, @as(usize, self.height - self.cursor_y - 1) * stride);
                }
            },
            1 => {
                if (self.cursor_y > 0) self.fillCells(0, @as(usize, self.cursor_y) * stride);
                const row = @as(usize, self.cursor_y) * stride;
                self.fillCells(row, self.cursor_x + 1);
            },
            else => self.fillCells(0, self.cells.len),
        }
    }

    fn eraseLine(self: *LegacyScreen, mode: u16) void {
        const stride: usize = self.width;
        const row = @as(usize, self.cursor_y) * stride;
        switch (mode) {
            0 => self.fillCells(row + self.cursor_x, stride - self.cursor_x),
            1 => self.fillCells(row, self.cursor_x + 1),
            else => self.fillCells(row, stride),
        }
    }

    fn eraseChars(self: *LegacyScreen, count: u16) void {
        const stride: usize = self.width;
        const row = @as(usize, self.cursor_y) * stride;
        const from = @as(usize, self.cursor_x);
        self.fillCells(row + from, @min(count, stride - from));
    }

    /// Grow/shrink to a new console window size, keeping the top-left overlap
    /// and invalidating state that no longer maps (cursor, scroll region,
    /// alt snapshot).
    fn resize(self: *LegacyScreen, new_width: u16, new_height: u16) void {
        if (new_width == 0 or new_height == 0) return;
        if (new_width == self.width and new_height == self.height) return;

        const new_cells = self.allocator.alloc(CHAR_INFO, @as(usize, new_width) * @as(usize, new_height)) catch return;
        const copy_width: usize = @min(self.width, new_width);
        const copy_height: usize = @min(self.height, new_height);
        const attr = self.eraseAttr();
        for (new_cells) |*cell| {
            cell.* = .{ .Char = .{ .UnicodeChar = ' ' }, .Attributes = attr };
        }
        for (0..copy_height) |y| {
            const src = y * @as(usize, self.width);
            const dst = y * @as(usize, new_width);
            @memcpy(new_cells[dst..][0..copy_width], self.cells[src..][0..copy_width]);
        }

        self.allocator.free(self.cells);
        self.cells = new_cells;
        self.width = new_width;
        self.height = new_height;
        self.cursor_x = @min(self.cursor_x, new_width - 1);
        self.cursor_y = @min(self.cursor_y, new_height - 1);
        self.saved_x = @min(self.saved_x, new_width - 1);
        self.saved_y = @min(self.saved_y, new_height - 1);
        self.scroll_top = 0;
        self.scroll_bottom = new_height - 1;
        self.pending_wrap = false;
        if (self.alt_cells) |alt| {
            if (alt.len != new_cells.len) {
                self.allocator.free(alt);
                self.alt_cells = null;
            }
        }
        self.dirty = true;
    }

    /// Pragmatic zero-width set: combining marks, bidi/ZW controls, variation
    /// selectors, tags, and skin-tone modifiers are folded into the cell that
    /// precedes them (Win32 cells cannot render them separately).
    fn isZeroWidth(cp: u21) bool {
        const zero_width_ranges = [_]struct { u21, u21 }{
            .{ 0x0300, 0x036F }, // combining diacritical marks
            .{ 0x0483, 0x0489 },
            .{ 0x0591, 0x05BD },
            .{ 0x0610, 0x061A },
            .{ 0x064B, 0x065F },
            .{ 0x0670, 0x0670 },
            .{ 0x06D6, 0x06DC },
            .{ 0x0E31, 0x0E31 },
            .{ 0x0E34, 0x0E3A },
            .{ 0x0E47, 0x0E4E },
            .{ 0x1AB0, 0x1AFF },
            .{ 0x1DC0, 0x1DFF },
            .{ 0x200B, 0x200F }, // ZW space/non-joiner/ZWJ/bidi marks
            .{ 0x202A, 0x202E },
            .{ 0x2060, 0x2064 },
            .{ 0x20D0, 0x20FF },
            .{ 0xFE00, 0xFE0F }, // variation selectors
            .{ 0xFE20, 0xFE2F },
            .{ 0xFEFF, 0xFEFF },
            .{ 0x1F3FB, 0x1F3FF }, // skin tone modifiers
            .{ 0xE0020, 0xE007F }, // tag characters
            .{ 0xE0100, 0xE01EF }, // variation selectors supplement
        };
        for (zero_width_ranges) |range| {
            if (cp >= range[0] and cp <= range[1]) return true;
        }
        return false;
    }
};

/// ANSI palette index (0-15) to the matching win32 color pattern: ANSI stores
/// red in bit 0 and blue in bit 2, win32 the other way around.
fn ansiIndexToWinNibble(index: u16) u16 {
    return ((index & 1) << 2) | (index & 2) | ((index & 4) >> 2) | (index & 8);
}

/// Nearest ANSI-16 palette slot (as a win32 nibble) for an RGB triple.
fn nearestAnsi16Nibble(r: u8, g: u8, b: u8) u16 {
    const target = ansi.u8RgbToRgba(r, g, b);
    var best_index: usize = 0;
    var best_distance = ansi.colorDistanceSquared(target, ansi.u8RgbToRgba(ansi.ANSI16_RGB[0][0], ansi.ANSI16_RGB[0][1], ansi.ANSI16_RGB[0][2]));
    for (ansi.ANSI16_RGB[1..], 1..) |rgb, index| {
        const distance = ansi.colorDistanceSquared(target, ansi.u8RgbToRgba(rgb[0], rgb[1], rgb[2]));
        if (distance < best_distance) {
            best_distance = distance;
            best_index = index;
        }
    }
    return ansiIndexToWinNibble(@intCast(best_index));
}

test "LegacyScreen renders plain text and tracks the cursor" {
    var screen = try LegacyScreen.init(std.testing.allocator, 10, 3, 0x07);
    defer screen.deinit();

    screen.feed("Hi");
    try std.testing.expectEqual(@as(u16, 'H'), screen.charAt(0, 0));
    try std.testing.expectEqual(@as(u16, 'i'), screen.charAt(1, 0));
    try std.testing.expectEqual(@as(u16, 2), screen.cursor_x);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor_y);
    try std.testing.expect(screen.dirty);
}

test "LegacyScreen moves the cursor with CUP" {
    var screen = try LegacyScreen.init(std.testing.allocator, 20, 10, 0x07);
    defer screen.deinit();

    screen.feed("\x1b[5;10H");
    try std.testing.expectEqual(@as(u16, 9), screen.cursor_x);
    try std.testing.expectEqual(@as(u16, 4), screen.cursor_y);
}

test "LegacyScreen maps SGR colors onto win16 attributes" {
    var screen = try LegacyScreen.init(std.testing.allocator, 10, 3, 0x07);
    defer screen.deinit();

    screen.feed("\x1b[31mA");
    try std.testing.expectEqual(@as(u16, 4), screen.attrAt(0, 0) & 0xF);

    screen.feed("\x1b[38;2;255;0;0mB");
    try std.testing.expectEqual(@as(u16, 12), screen.attrAt(1, 0) & 0xF);

    screen.feed("\x1b[0mC");
    try std.testing.expectEqual(@as(u16, 7), screen.attrAt(2, 0) & 0xF);
    try std.testing.expectEqual(@as(u16, 0), screen.attrAt(2, 0) >> 4);
}

test "LegacyScreen erases with ED and EL" {
    var screen = try LegacyScreen.init(std.testing.allocator, 4, 2, 0x07);
    defer screen.deinit();

    screen.feed("abcd\r\nefgh");
    screen.feed("\x1b[1;3H\x1b[K");
    try std.testing.expectEqual(@as(u16, 'a'), screen.charAt(0, 0));
    try std.testing.expectEqual(@as(u16, 'b'), screen.charAt(1, 0));
    try std.testing.expectEqual(@as(u16, ' '), screen.charAt(2, 0));
    try std.testing.expectEqual(@as(u16, ' '), screen.charAt(3, 0));
    try std.testing.expectEqual(@as(u16, 'e'), screen.charAt(0, 1));

    screen.feed("\x1b[2J");
    for (0..4) |x| {
        for (0..2) |y| {
            try std.testing.expectEqual(@as(u16, ' '), screen.charAt(@intCast(x), @intCast(y)));
        }
    }
}

test "LegacyScreen swaps buffers on the alternate screen" {
    var screen = try LegacyScreen.init(std.testing.allocator, 6, 2, 0x07);
    defer screen.deinit();

    screen.feed("ab");
    screen.feed("\x1b[?1049h");
    try std.testing.expectEqual(@as(u16, ' '), screen.charAt(0, 0));

    screen.feed("\x1b[Hxy");
    try std.testing.expectEqual(@as(u16, 'x'), screen.charAt(0, 0));
    try std.testing.expectEqual(@as(u16, 'y'), screen.charAt(1, 0));

    screen.feed("\x1b[?1049l");
    try std.testing.expectEqual(@as(u16, 'a'), screen.charAt(0, 0));
    try std.testing.expectEqual(@as(u16, 'b'), screen.charAt(1, 0));
    try std.testing.expectEqual(@as(u16, 2), screen.cursor_x);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor_y);
}

test "LegacyScreen swallows OSC and DCS strings" {
    var screen = try LegacyScreen.init(std.testing.allocator, 10, 3, 0x07);
    defer screen.deinit();

    screen.feed("\x1b]0;title\x07Hi");
    try std.testing.expectEqual(@as(u16, 'H'), screen.charAt(0, 0));
    try std.testing.expectEqual(@as(u16, 2), screen.cursor_x);

    screen.feed("\x1bP+q4d73\x1b\\Ok");
    try std.testing.expectEqual(@as(u16, 'O'), screen.charAt(2, 0));
    try std.testing.expectEqual(@as(u16, 'k'), screen.charAt(3, 0));
    try std.testing.expectEqual(@as(u16, 4), screen.cursor_x);
}

test "LegacyScreen wraps at the right edge" {
    var screen = try LegacyScreen.init(std.testing.allocator, 4, 2, 0x07);
    defer screen.deinit();

    screen.feed("abcde");
    try std.testing.expectEqual(@as(u16, 'd'), screen.charAt(3, 0));
    try std.testing.expectEqual(@as(u16, 'e'), screen.charAt(0, 1));
    try std.testing.expectEqual(@as(u16, 1), screen.cursor_x);
    try std.testing.expectEqual(@as(u16, 1), screen.cursor_y);
}

test "LegacyScreen scrolls at the bottom of the scroll region" {
    var screen = try LegacyScreen.init(std.testing.allocator, 4, 2, 0x07);
    defer screen.deinit();

    screen.feed("abcd\r\n"); // row 0 full, cursor at (0,1)
    screen.feed("efgh"); // row 1 full, wrap pending
    screen.feed("\r\nxy"); // line feed at the bottom scrolls the region

    try std.testing.expectEqual(@as(u16, 'e'), screen.charAt(0, 0));
    try std.testing.expectEqual(@as(u16, 'f'), screen.charAt(1, 0));
    try std.testing.expectEqual(@as(u16, 'h'), screen.charAt(3, 0));
    try std.testing.expectEqual(@as(u16, 'x'), screen.charAt(0, 1));
    try std.testing.expectEqual(@as(u16, 'y'), screen.charAt(1, 1));
}

test "LegacyScreen keeps parser state across writes" {
    var screen = try LegacyScreen.init(std.testing.allocator, 10, 3, 0x07);
    defer screen.deinit();

    screen.feed("\x1b[3");
    screen.feed("1mZ");
    try std.testing.expectEqual(@as(u16, 'Z'), screen.charAt(0, 0));
    try std.testing.expectEqual(@as(u16, 4), screen.attrAt(0, 0) & 0xF);
}

test "LegacyScreen decodes UTF-8 and skips zero-width marks" {
    var screen = try LegacyScreen.init(std.testing.allocator, 10, 3, 0x07);
    defer screen.deinit();

    screen.feed("e\xCC\x81"); // e + combining acute forms one cell
    try std.testing.expectEqual(@as(u16, 'e'), screen.charAt(0, 0));
    try std.testing.expectEqual(@as(u16, 1), screen.cursor_x);

    screen.feed("\xC3\xA9"); // é
    try std.testing.expectEqual(@as(u16, 0xE9), screen.charAt(1, 0));
    try std.testing.expectEqual(@as(u16, 2), screen.cursor_x);

    screen.feed("\xF0\x9F\x98\x80"); // non-BMP falls back to '?'
    try std.testing.expectEqual(@as(u16, '?'), screen.charAt(2, 0));
    try std.testing.expectEqual(@as(u16, 3), screen.cursor_x);
}

test "LegacyScreen toggles cursor visibility and saves the cursor" {
    var screen = try LegacyScreen.init(std.testing.allocator, 10, 3, 0x07);
    defer screen.deinit();

    try std.testing.expect(screen.cursor_visible);
    screen.feed("\x1b[?25l");
    try std.testing.expect(!screen.cursor_visible);
    screen.feed("\x1b[?25h");
    try std.testing.expect(screen.cursor_visible);

    screen.feed("\x1b[3;4H\x1b[s\x1b[1;1H\x1b[u");
    try std.testing.expectEqual(@as(u16, 3), screen.cursor_x);
    try std.testing.expectEqual(@as(u16, 2), screen.cursor_y);
}

test "LegacyScreen swallows private-mode sequences without mutating cells" {
    var screen = try LegacyScreen.init(std.testing.allocator, 6, 2, 0x07);
    defer screen.deinit();

    screen.feed("ab");
    screen.feed("\x1b[<0;10;5M\x1b[>4;1m\x1b[6n");
    try std.testing.expectEqual(@as(u16, 'a'), screen.charAt(0, 0));
    try std.testing.expectEqual(@as(u16, 'b'), screen.charAt(1, 0));
    try std.testing.expectEqual(@as(u16, 2), screen.cursor_x);
    try std.testing.expectEqual(@as(u16, 7), screen.attrAt(0, 0) & 0xF);
}

pub const StdoutOutput = struct {
    stdout: std.Io.File,
    stdoutBuffer: [4096]u8 = undefined,
    utf16Buffer: [UTF16_BUFFER_SIZE]u16 = undefined,
    windowsConsole: bool,
    /// Set when stdout is a conhost that cannot interpret VT sequences
    /// (Windows < 10, including XP). Frames are parsed into `legacy` cells and
    /// blitted with WriteConsoleOutputW instead of being written as ANSI.
    legacy: ?LegacyScreen = null,
    failed: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: Allocator) StdoutOutput {
        return initForFile(allocator, std.Io.File.stdout());
    }

    fn initForFile(allocator: Allocator, stdout: std.Io.File) StdoutOutput {
        var self: StdoutOutput = .{
            .stdout = stdout,
            .windowsConsole = isWindowsConsole(stdout),
        };
        if (self.windowsConsole and !supportsVirtualTerminal(stdout)) {
            self.legacy = LegacyScreen.initForConsole(allocator, stdout) catch null;
        }
        return self;
    }

    pub fn deinit(self: *StdoutOutput) void {
        if (self.legacy) |*legacy| {
            legacy.deinit();
            self.legacy = null;
        }
    }

    pub fn bufferedOutput(self: *StdoutOutput) BufferedOutput {
        return .{
            .ctx = self,
            .write_fn = write,
            .thread_safe = true,
        };
    }

    fn write(ctx: *anyopaque, data: []const u8) void {
        if (data.len == 0) return;

        const self: *StdoutOutput = @ptrCast(@alignCast(ctx));
        if (builtin.os.tag == .windows) {
            if (self.windowsConsole) {
                if (self.legacy != null) {
                    self.writeLegacy(data);
                } else {
                    self.writeWindowsConsole(data);
                }
                return;
            }
        }

        self.writeBytes(data);
    }

    fn writeBytes(self: *StdoutOutput, data: []const u8) void {
        var stdoutWriter = self.stdout.writerStreaming(io, &self.stdoutBuffer);
        const w = &stdoutWriter.interface;
        w.writeAll(data) catch {
            self.failed.store(true, .release);
            return;
        };
        w.flush() catch {
            self.failed.store(true, .release);
        };
    }

    fn writeWindowsConsole(self: *StdoutOutput, data: []const u8) void {
        // Frames and control writes are complete UTF-8 units. Drop malformed
        // input rather than partially emitting an ANSI sequence to the console.
        if (!std.unicode.utf8ValidateSlice(data)) return;

        var input = data;
        while (input.len > 0) {
            const chunk = utf8ToUtf16Chunk(&self.utf16Buffer, input) catch unreachable;
            std.debug.assert(chunk.input_len > 0);
            if (!self.writeWindowsConsoleUtf16(self.utf16Buffer[0..chunk.output_len])) return;
            input = input[chunk.input_len..];
        }
    }

    fn writeWindowsConsoleUtf16(self: *StdoutOutput, data: []const u16) bool {
        var remaining = data;
        while (remaining.len > 0) {
            var written: std.os.windows.DWORD = 0;
            if (!WindowsConsole.WriteConsoleW(
                self.stdout.handle,
                remaining.ptr,
                @intCast(remaining.len),
                &written,
                null,
            ).toBool() or written == 0) return false;
            remaining = remaining[@intCast(written)..];
        }
        return true;
    }

    fn writeLegacy(self: *StdoutOutput, data: []const u8) void {
        // Frames and control writes are complete UTF-8 units. Drop malformed
        // input so the shadow screen never diverges from a write the console
        // would not have received either (parity with writeWindowsConsole).
        if (!std.unicode.utf8ValidateSlice(data)) return;

        self.legacy.?.feed(data);
        self.flushLegacy();
    }

    /// Blit the shadow window to the console. The window rect is re-read every
    /// flush so resizes (and manual scroll of the console buffer) are picked
    /// up; a failed blit keeps `dirty` set so the next write retries.
    fn flushLegacy(self: *StdoutOutput) void {
        if (self.legacy == null) return;
        const legacy = &self.legacy.?;
        if (!legacy.dirty) return;

        var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (!WindowsConsole.GetConsoleScreenBufferInfo(self.stdout.handle, &info).toBool()) {
            self.failed.store(true, .release);
            return;
        }

        const win_w: u16 = @intCast(@max(@as(i32, info.srWindow.Right) - @as(i32, info.srWindow.Left) + 1, 1));
        const win_h: u16 = @intCast(@max(@as(i32, info.srWindow.Bottom) - @as(i32, info.srWindow.Top) + 1, 1));
        legacy.resize(win_w, win_h);

        var region = info.srWindow;
        const cells_blitted = WindowsConsole.WriteConsoleOutputW(
            self.stdout.handle,
            legacy.cells.ptr,
            .{ .X = @intCast(legacy.width), .Y = @intCast(legacy.height) },
            .{ .X = 0, .Y = 0 },
            &region,
        ).toBool();

        const max_x: i32 = @max(@as(i32, info.dwSize.X) - 1, 0);
        const max_y: i32 = @max(@as(i32, info.dwSize.Y) - 1, 0);
        const cursor_placed = WindowsConsole.SetConsoleCursorPosition(self.stdout.handle, .{
            .X = @intCast(std.math.clamp(@as(i32, info.srWindow.Left) + @as(i32, legacy.cursor_x), 0, max_x)),
            .Y = @intCast(std.math.clamp(@as(i32, info.srWindow.Top) + @as(i32, legacy.cursor_y), 0, max_y)),
        }).toBool();
        const cursor_info = CONSOLE_CURSOR_INFO{
            .dwSize = 25,
            .bVisible = std.os.windows.BOOL.fromBool(legacy.cursor_visible),
        };
        const cursor_state_placed = WindowsConsole.SetConsoleCursorInfo(self.stdout.handle, &cursor_info).toBool();

        if (cells_blitted and cursor_placed and cursor_state_placed) {
            legacy.dirty = false;
        } else {
            self.failed.store(true, .release);
        }
    }
};

test "StdoutOutput leaves the Windows console output code page unchanged" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    if (!isWindowsConsole(std.Io.File.stdout())) return error.SkipZigTest;

    const original_code_page = WindowsConsole.GetConsoleOutputCP();
    if (original_code_page == 0) return error.SkipZigTest;
    defer _ = WindowsConsole.SetConsoleOutputCP(original_code_page);

    if (!WindowsConsole.SetConsoleOutputCP(437).toBool()) return error.SkipZigTest;

    var stdout_output = StdoutOutput.init(std.testing.allocator);
    defer stdout_output.deinit();
    try std.testing.expect(stdout_output.windowsConsole);
    try std.testing.expectEqual(@as(u32, 437), WindowsConsole.GetConsoleOutputCP());
}

test "StdoutOutput preserves bytes for redirected output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "stdout", .{ .read = true });
    defer file.close(std.testing.io);
    try std.testing.expect(!isWindowsConsole(file));

    var stdout_output = StdoutOutput.initForFile(std.testing.allocator, file);
    defer stdout_output.deinit();
    const expected = "\x1b[31mAé東😀\x1b[0m";
    const split = expected.len / 2;
    stdout_output.bufferedOutput().write(expected[0..split]);
    stdout_output.bufferedOutput().write(expected[split..]);

    var actual: [expected.len]u8 = undefined;
    const actual_len = try file.readPositionalAll(std.testing.io, &actual, 0);
    try std.testing.expectEqual(expected.len, actual_len);
    try std.testing.expectEqualStrings(expected, &actual);
}

pub const MemoryOutput = struct {
    allocator: Allocator,
    bytes: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: Allocator) MemoryOutput {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryOutput) void {
        self.bytes.deinit(self.allocator);
    }

    pub fn bufferedOutput(self: *MemoryOutput) BufferedOutput {
        return .{ .ctx = self, .write_fn = write };
    }

    fn write(ctx: *anyopaque, data: []const u8) void {
        const self: *MemoryOutput = @ptrCast(@alignCast(ctx));
        self.bytes.appendSlice(self.allocator, data) catch {};
    }
};

fn BackendWriter(
    comptime Backend: type,
    comptime append: fn (*Backend, []const u8) error{BufferFull}!void,
) type {
    return struct {
        const Writer = @This();

        backend: *Backend,
        interface: std.Io.Writer,

        fn init(backend: *Backend) Writer {
            return .{
                .backend = backend,
                .interface = .{
                    .vtable = &.{ .drain = drain },
                    .buffer = &.{},
                },
            };
        }

        pub fn write(self: Writer, data: []const u8) error{BufferFull}!usize {
            var copy = self;
            return copy.interface.write(data) catch return error.BufferFull;
        }

        pub fn writeAll(self: Writer, data: []const u8) error{BufferFull}!void {
            var copy = self;
            return copy.interface.writeAll(data) catch return error.BufferFull;
        }

        pub fn writeByte(self: Writer, byte: u8) error{BufferFull}!void {
            var copy = self;
            return copy.interface.writeByte(byte) catch return error.BufferFull;
        }

        pub fn print(self: Writer, comptime format: []const u8, args: anytype) error{BufferFull}!void {
            var copy = self;
            return copy.interface.print(format, args) catch return error.BufferFull;
        }

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
            var written: usize = 0;

            for (data[0 .. data.len - 1]) |slice| {
                append(self.backend, slice) catch return error.WriteFailed;
                written += slice.len;
            }

            const pattern = data[data.len - 1];
            for (0..splat) |_| {
                append(self.backend, pattern) catch return error.WriteFailed;
                written += pattern.len;
            }
            return written;
        }
    };
}

/// Tagged union dispatching to BufferedBackend or FeedBackend.
pub const OutputBackend = union(enum) {
    buffered: BufferedBackend,
    feed: FeedBackend,

    /// Synchronously emit a pre-built byte sequence (setup/shutdown/query).
    pub fn writeOut(self: *OutputBackend, data: []const u8) void {
        switch (self.*) {
            inline else => |*b| b.writeOut(data),
        }
    }

    /// Synchronously emit multiple pre-built byte sequences.
    pub fn writeOutMultiple(self: *OutputBackend, data_slices: []const []const u8) void {
        switch (self.*) {
            inline else => |*b| b.writeOutMultiple(data_slices),
        }
    }

    /// Prepare the backend for a new frame. Feed backends can return skipped
    /// when the durable queue is over its high-water mark or still owns pending
    /// bytes from an earlier frame.
    pub fn prepareFrame(self: *OutputBackend) WriteStatus {
        switch (self.*) {
            inline else => |*b| return b.prepareFrame(),
        }
    }

    /// Transition batches must publish captured output before terminal state changes.
    /// Feed high water limits ordinary frames, not these ordered control writes.
    pub fn prepareControlFrame(self: *OutputBackend) WriteStatus {
        switch (self.*) {
            .feed => |*b| {
                b.feed.commit() catch return .skipped;
                return .ok;
            },
            .buffered => |*b| return b.prepareFrame(),
        }
    }

    /// Non-mutating high-water check. Rendering uses `prepareFrame()` so pending
    /// bytes from earlier writes can be committed before deciding to skip.
    pub fn shouldSkipFrame(self: *OutputBackend) bool {
        switch (self.*) {
            inline else => |*b| return b.shouldSkipFrame(),
        }
    }

    pub fn supportsThreading(self: *OutputBackend) bool {
        switch (self.*) {
            inline else => |*b| return b.supportsThreading(),
        }
    }

    pub fn setUseThread(self: *OutputBackend, use_thread: bool) void {
        switch (self.*) {
            inline else => |*b| b.setUseThread(use_thread),
        }
    }

    pub fn isUseThread(self: *OutputBackend) bool {
        switch (self.*) {
            inline else => |*b| return b.isUseThread(),
        }
    }

    /// Microseconds spent on the last write (populated after endFrame).
    pub fn getLastWriteTimeUs(self: *OutputBackend) ?f64 {
        switch (self.*) {
            inline else => |*b| return b.lastWriteTimeUs,
        }
    }

    /// Write a backend-specific debug dump into `out`. Called from the
    /// `dumpOutputBuffer` helper on `CliRenderer`; keeps backend-specific
    /// formatting internal so the renderer never switches on the tag.
    pub fn dumpTo(self: *OutputBackend, out: anytype) void {
        switch (self.*) {
            inline else => |*b| b.dumpTo(out),
        }
    }

    pub fn deinit(self: *OutputBackend) void {
        switch (self.*) {
            inline else => |*b| b.deinit(),
        }
    }
};

/// Backend that stages frame bytes in per-renderer buffers and flushes them to
/// an injected byte output when a frame is committed.
///
/// Owns the double buffers and optional render-thread state so each renderer
/// has isolated output storage.
pub const BufferedBackend = struct {
    const BufferId = enum { A, B };

    /// Number of consecutive frames that fit in the default buffer before an
    /// oversized buffer is shrunk back to OUTPUT_BUFFER_SIZE. Keeps a workload
    /// of sustained large frames from realloc-churning while still returning
    /// spike memory once frames are consistently small again.
    const SHRINK_AFTER_SMALL_FRAMES = 64;

    allocator: Allocator,
    output: BufferedOutput,
    ownedStdoutOutput: ?*StdoutOutput = null,
    ownedMemoryOutput: ?*MemoryOutput = null,

    outputA: []u8,
    outputB: []u8,
    outputLenA: usize = 0,
    outputLenB: usize = 0,
    activeBuffer: BufferId = .A,
    lastCommittedBuffer: BufferId = .A,
    hasCommittedFrame: bool = false,
    /// Set when frame bytes were dropped because a buffer could not grow.
    /// endFrame consumes it and reports the frame as failed so the renderer
    /// forces a full repaint instead of trusting the committed cell diff.
    frameWriteFailed: bool = false,
    smallFrameStreak: u32 = 0,

    useThread: bool = false,
    renderThread: ?std.Thread = null,
    renderMutex: std.Io.Mutex = .init,
    renderCondition: std.Io.Condition = .init,
    renderRequested: bool = false,
    shouldTerminate: bool = false,
    renderInProgress: bool = false,

    // Handoff buffer for the render thread
    currentOutputBuffer: []u8 = &[_]u8{},
    currentOutputLen: usize = 0,

    lastWriteTimeUs: ?f64 = null,

    pub fn create(allocator: Allocator, output: BufferedOutput) !BufferedBackend {
        const a_buf = try allocator.alloc(u8, OUTPUT_BUFFER_SIZE);
        errdefer allocator.free(a_buf);
        const b_buf = try allocator.alloc(u8, OUTPUT_BUFFER_SIZE);
        errdefer allocator.free(b_buf);

        return BufferedBackend{
            .allocator = allocator,
            .output = output,
            .outputA = a_buf,
            .outputB = b_buf,
        };
    }

    pub fn createStdout(allocator: Allocator) !BufferedBackend {
        const stdoutOutput = try allocator.create(StdoutOutput);
        errdefer allocator.destroy(stdoutOutput);
        stdoutOutput.* = StdoutOutput.init(allocator);
        errdefer stdoutOutput.deinit();

        var backend = try BufferedBackend.create(allocator, stdoutOutput.bufferedOutput());
        backend.ownedStdoutOutput = stdoutOutput;
        return backend;
    }

    pub fn createMemory(allocator: Allocator) !BufferedBackend {
        const memoryOutput = try allocator.create(MemoryOutput);
        errdefer allocator.destroy(memoryOutput);
        memoryOutput.* = MemoryOutput.init(allocator);

        var backend = try BufferedBackend.create(allocator, memoryOutput.bufferedOutput());
        backend.ownedMemoryOutput = memoryOutput;
        return backend;
    }

    /// Frees with the allocator captured at create time. The buffers may have
    /// been realloc-grown by frame writes, so freeing them with any other
    /// allocator would be undefined behavior.
    pub fn deinit(self: *BufferedBackend) void {
        if (self.renderThread) |thread| {
            self.renderMutex.lockUncancelable(io);
            while (self.renderInProgress) {
                self.renderCondition.waitUncancelable(io, &self.renderMutex);
            }
            self.shouldTerminate = true;
            // Do NOT set renderRequested — the thread should wake, see
            // shouldTerminate, and exit without a final spurious write of
            // the stale last-frame buffer. Previously setting renderRequested
            // here caused a stale frame to be emitted AFTER the shutdown
            // ANSI sequence had already restored the terminal.
            self.renderCondition.signal(io);
            self.renderMutex.unlock(io);
            thread.join();
            self.renderThread = null;
        }

        self.allocator.free(self.outputA);
        self.allocator.free(self.outputB);
        if (self.ownedStdoutOutput) |stdoutOutput| {
            stdoutOutput.deinit();
            self.allocator.destroy(stdoutOutput);
            self.ownedStdoutOutput = null;
        }
        if (self.ownedMemoryOutput) |memoryOutput| {
            memoryOutput.deinit();
            self.allocator.destroy(memoryOutput);
            self.ownedMemoryOutput = null;
        }
    }

    pub fn shouldSkipFrame(_: *BufferedBackend) bool {
        return false;
    }

    pub fn prepareFrame(self: *BufferedBackend) WriteStatus {
        if (!self.useThread) return .ok;
        if (!self.renderMutex.tryLock()) return .skipped;
        defer self.renderMutex.unlock(io);
        if (self.renderInProgress) return .skipped;
        return .ok;
    }

    pub fn supportsThreading(self: *BufferedBackend) bool {
        return self.output.thread_safe;
    }

    pub fn isUseThread(self: *BufferedBackend) bool {
        return self.useThread;
    }

    pub fn setUseThread(self: *BufferedBackend, use_thread: bool) void {
        if (use_thread and !self.supportsThreading()) return;
        if (self.useThread == use_thread) return;

        if (use_thread) {
            if (self.renderThread == null) {
                self.renderThread = std.Thread.spawn(.{}, renderThreadFn, .{self}) catch |err| {
                    std.log.warn("Failed to spawn render thread: {}, falling back to non-threaded mode", .{err});
                    self.useThread = false;
                    return;
                };
            }
        } else {
            if (self.renderThread) |thread| {
                self.renderMutex.lockUncancelable(io);
                while (self.renderInProgress) {
                    self.renderCondition.waitUncancelable(io, &self.renderMutex);
                }
                self.shouldTerminate = true;
                // Wake the thread with a terminate-only signal; do not set
                // renderRequested (that would replay the stale buffer).
                self.renderCondition.signal(io);
                self.renderMutex.unlock(io);

                thread.join();
                self.renderThread = null;
                self.shouldTerminate = false;
                // Reset request/progress flags so a future setUseThread(true)
                // does not wake on a stale request.
                self.renderRequested = false;
                self.renderInProgress = false;
            }
        }

        self.useThread = use_thread;
    }

    pub const Writer = BackendWriter(BufferedBackend, bufferWrite);

    fn bufferWrite(self: *BufferedBackend, data: []const u8) error{BufferFull}!void {
        const buffer_len = if (self.activeBuffer == .A)
            &self.outputLenA
        else
            &self.outputLenB;
        const required = std.math.add(usize, buffer_len.*, data.len) catch {
            self.frameWriteFailed = true;
            return error.BufferFull;
        };

        const buffer = if (self.activeBuffer == .A) &self.outputA else &self.outputB;

        if (required > buffer.*.len) {
            const doubled_capacity = std.math.mul(usize, buffer.*.len, 2) catch required;
            const capacity = @max(required, doubled_capacity);
            buffer.* = self.allocator.realloc(buffer.*, capacity) catch {
                self.frameWriteFailed = true;
                return error.BufferFull;
            };
        }

        @memcpy(buffer.*[buffer_len.*..][0..data.len], data);
        buffer_len.* = required;
    }

    pub fn writer(self: *BufferedBackend) Writer {
        return .init(self);
    }

    pub fn beginFrame(self: *BufferedBackend) void {
        self.frameWriteFailed = false;
        self.maybeShrinkActiveBuffer();
        if (self.activeBuffer == .A) {
            self.outputLenA = 0;
        } else {
            self.outputLenB = 0;
        }
    }

    pub fn failFrame(self: *BufferedBackend) void {
        self.frameWriteFailed = true;
    }

    /// Give spike memory back once frames have been consistently small again.
    /// Runs at frame start when the active buffer is exclusively owned by the
    /// producer: in threaded mode the render thread only ever reads the buffer
    /// handed off at the previous endFrame, which is the other one.
    fn maybeShrinkActiveBuffer(self: *BufferedBackend) void {
        if (self.smallFrameStreak < SHRINK_AFTER_SMALL_FRAMES) return;
        const buffer = if (self.activeBuffer == .A) &self.outputA else &self.outputB;
        if (buffer.*.len <= OUTPUT_BUFFER_SIZE) return;
        buffer.* = self.allocator.realloc(buffer.*, OUTPUT_BUFFER_SIZE) catch return;
    }

    fn updateSmallFrameStreak(self: *BufferedBackend, frame_len: usize) void {
        if (frame_len <= OUTPUT_BUFFER_SIZE) {
            self.smallFrameStreak +|= 1;
        } else {
            self.smallFrameStreak = 0;
        }
    }

    pub fn endFrame(self: *BufferedBackend) WriteStatus {
        const frame_len = if (self.activeBuffer == .A) self.outputLenA else self.outputLenB;

        if (self.frameWriteFailed) {
            // Frame bytes were dropped mid-frame. Flushing the truncated ANSI
            // stream could leave the terminal inside an escape sequence, so
            // drop the partial frame entirely and report failure; the renderer
            // reacts by forcing a full repaint on the next frame.
            self.frameWriteFailed = false;
            self.smallFrameStreak = 0;
            return .failed;
        }

        self.updateSmallFrameStreak(frame_len);

        if (self.useThread and frame_len == 0) {
            self.lastCommittedBuffer = self.activeBuffer;
            self.hasCommittedFrame = true;
            return .ok;
        }
        const writeStart = std.Io.Clock.awake.now(io);
        const committed_buffer = self.activeBuffer;

        if (self.useThread) {
            self.renderMutex.lockUncancelable(io);
            while (self.renderInProgress) {
                self.renderCondition.waitUncancelable(io, &self.renderMutex);
            }

            // Hand off the just-written buffer to the render thread and flip
            // active to the other one for the next frame.
            if (self.activeBuffer == .A) {
                self.activeBuffer = .B;
                self.currentOutputBuffer = self.outputA;
                self.currentOutputLen = self.outputLenA;
            } else {
                self.activeBuffer = .A;
                self.currentOutputBuffer = self.outputB;
                self.currentOutputLen = self.outputLenB;
            }

            self.renderRequested = true;
            self.renderInProgress = true;
            self.renderCondition.signal(io);
            self.renderMutex.unlock(io);
        } else {
            const to_write = if (self.activeBuffer == .A)
                self.outputA[0..self.outputLenA]
            else
                self.outputB[0..self.outputLenB];
            self.output.write(to_write);
            self.lastWriteTimeUs = @as(f64, @floatFromInt(writeStart.untilNow(io, .awake).toMicroseconds()));
        }

        self.lastCommittedBuffer = committed_buffer;
        self.hasCommittedFrame = true;
        return .ok;
    }

    fn renderThreadFn(self: *BufferedBackend) void {
        while (true) {
            self.renderMutex.lockUncancelable(io);
            while (!self.renderRequested and !self.shouldTerminate) {
                self.renderCondition.waitUncancelable(io, &self.renderMutex);
            }

            // Terminate wins: when shouldTerminate is set, exit without
            // writing even if a render was also requested. This keeps
            // shutdown-ANSI the last thing on the wire.
            if (self.shouldTerminate) {
                self.renderMutex.unlock(io);
                break;
            }

            self.renderRequested = false;

            const outputData = self.currentOutputBuffer;
            const outputLen = self.currentOutputLen;

            const writeStart = std.Io.Clock.awake.now(io);

            self.output.write(outputData[0..outputLen]);

            self.lastWriteTimeUs = @as(f64, @floatFromInt(writeStart.untilNow(io, .awake).toMicroseconds()));
            self.renderInProgress = false;
            self.renderCondition.signal(io);
            self.renderMutex.unlock(io);
        }
    }

    pub fn writeOut(self: *BufferedBackend, data: []const u8) void {
        if (data.len == 0) return;

        if (self.useThread) {
            self.renderMutex.lockUncancelable(io);
            while (self.renderInProgress) {
                self.renderCondition.waitUncancelable(io, &self.renderMutex);
            }
            self.renderMutex.unlock(io);
        }

        self.output.write(data);
    }

    pub fn writeOutMultiple(self: *BufferedBackend, data_slices: []const []const u8) void {
        if (self.useThread) {
            self.renderMutex.lockUncancelable(io);
            while (self.renderInProgress) {
                self.renderCondition.waitUncancelable(io, &self.renderMutex);
            }
            self.renderMutex.unlock(io);
        }

        var totalLen: usize = 0;
        for (data_slices) |slice| {
            totalLen += slice.len;
        }
        if (totalLen == 0) return;

        for (data_slices) |slice| {
            self.output.write(slice);
        }
    }

    /// Write a debug dump of the last rendered output into `out`. The
    /// committed-buffer marker is explicit because non-threaded rendering does
    /// not flip the active buffer after each frame.
    pub fn dumpTo(self: *BufferedBackend, out: anytype) void {
        const last = if (self.hasCommittedFrame) blk: {
            const buf = if (self.lastCommittedBuffer == .A) self.outputA else self.outputB;
            const len = if (self.lastCommittedBuffer == .A) self.outputLenA else self.outputLenB;
            break :blk buf[0..len];
        } else &.{};

        if (last.len > 0) {
            out.writeAll(last) catch return;
        } else {
            out.writeAll("(no output rendered yet)\n") catch return;
        }
        out.writeAll("\n================\n") catch return;
        out.print("Buffer size: {d} bytes\n", .{last.len}) catch return;
        const active_label: []const u8 = if (self.activeBuffer == .A) "A" else "B";
        const committed_label: []const u8 = if (self.lastCommittedBuffer == .A) "A" else "B";
        out.print("Active buffer: {s}\n", .{active_label}) catch return;
        out.print("Last committed buffer: {s}\n", .{committed_label}) catch return;
    }
};

/// Backend that atomically publishes complete frames to a
/// `NativeSpanFeed.Stream`. The feed owns its chunk memory; the staging buffer
/// exists only to keep failed frames from exposing partial ANSI sequences.
///
/// Feed writes are in-memory ring-buffer ops with no I/O, so threading adds
/// synchronization cost without latency-hiding benefit. Backpressure is
/// exposed through `prepareFrame`: when the span queue is at its high-water
/// mark, frames are skipped before diffing while already queued bytes remain
/// durable and drain in order.
///
/// Zig tests that want to exercise the feed path should drain the feed directly.
pub const FeedBackend = struct {
    feed: *NativeSpanFeed.Stream,
    frameBytes: std.ArrayListUnmanaged(u8) = .empty,

    /// Set when staging a frame fails. No bytes from a failed frame are
    /// published; the renderer forces a later full repaint.
    frameWriteFailed: bool = false,

    lastWriteTimeUs: ?f64 = null,

    pub fn create(feed: *NativeSpanFeed.Stream) FeedBackend {
        return FeedBackend{ .feed = feed };
    }

    pub fn deinit(self: *FeedBackend) void {
        // Feed memory is owned by the TypeScript side.
        self.frameBytes.deinit(self.feed.allocator);
    }

    pub fn shouldSkipFrame(self: *FeedBackend) bool {
        const cap = self.feed.options.span_queue_capacity;
        if (cap == 0) return false;

        // Draining transfers spans to consumers; only releasing their chunk
        // references returns credit. Count queued and in-flight spans once each.
        var outstanding: u64 = 0;
        for (self.feed.stateBuffer()) |refcount| {
            outstanding += refcount;
            if (outstanding >= cap) return true;
        }
        return false;
    }

    pub fn prepareFrame(self: *FeedBackend) WriteStatus {
        self.frameWriteFailed = false;

        if (self.feed.hasPendingBytes()) {
            self.feed.commit() catch return .skipped;
            // Pending bytes belonged to an earlier frame/control write. Queue
            // them first and let the caller retry the new frame after drain.
            return .skipped;
        }

        if (self.shouldSkipFrame()) return .skipped;
        return .ok;
    }

    pub fn supportsThreading(_: *FeedBackend) bool {
        return false;
    }

    pub fn setUseThread(_: *FeedBackend, _: bool) void {
        // No-op: feed writes don't benefit from threading.
    }

    pub fn isUseThread(_: *FeedBackend) bool {
        return false;
    }

    pub const Writer = BackendWriter(FeedBackend, frameWrite);

    fn frameWrite(self: *FeedBackend, data: []const u8) error{BufferFull}!void {
        self.frameBytes.appendSlice(self.feed.allocator, data) catch {
            self.frameWriteFailed = true;
            return error.BufferFull;
        };
    }

    pub fn writer(self: *FeedBackend) Writer {
        return .init(self);
    }

    pub fn beginFrame(self: *FeedBackend) void {
        self.frameWriteFailed = false;
        self.frameBytes.clearRetainingCapacity();
    }

    pub fn failFrame(self: *FeedBackend) void {
        self.frameWriteFailed = true;
    }

    pub fn endFrame(self: *FeedBackend) WriteStatus {
        const writeStart = std.Io.Clock.awake.now(io);
        var status: WriteStatus = .ok;

        if (self.frameWriteFailed) {
            status = .failed;
        } else {
            self.feed.writeAtomic(self.frameBytes.items) catch {
                status = .failed;
            };
        }

        self.lastWriteTimeUs = @as(f64, @floatFromInt(writeStart.untilNow(io, .awake).toMicroseconds()));
        return status;
    }

    pub fn writeOut(self: *FeedBackend, data: []const u8) void {
        if (data.len == 0) return;
        // High-level renderers use a growable, uncapped feed. Manually bounded
        // low-level feeds intentionally get atomic best-effort control writes.
        self.feed.writeAtomic(data) catch {};
    }

    pub fn writeOutMultiple(self: *FeedBackend, data_slices: []const []const u8) void {
        var totalLen: usize = 0;
        for (data_slices) |slice| totalLen = std.math.add(usize, totalLen, slice.len) catch return;
        if (totalLen == 0) return;

        const data = self.feed.allocator.alloc(u8, totalLen) catch return;
        defer self.feed.allocator.free(data);
        var offset: usize = 0;
        for (data_slices) |slice| {
            @memcpy(data[offset .. offset + slice.len], slice);
            offset += slice.len;
        }
        self.feed.writeAtomic(data) catch {};
    }

    /// Write a debug dump placeholder. FeedBackend has no flat previous-frame
    /// slice — callers wanting feed bytes should drain the NativeSpanFeed.
    pub fn dumpTo(_: *FeedBackend, out: anytype) void {
        out.writeAll("(feed backend — drain spans from the NativeSpanFeed for output)\n") catch return;
        out.writeAll("\n================\n") catch return;
    }
};
