const std = @import("std");
const Io = std.Io;

pub const Branch = struct {
    /// The line becomes this text if the branch is accepted.
    text: []const u8,
    /// That branch's meaning, visible before Enter.
    held: []const u8 = "",
};

pub const Inference = struct {
    /// Meaning of the line as it stands. Empty means the sentence is not closed yet.
    held: []const u8 = "",
    /// Other sentences this line could become. Tab accepts the selected one.
    branches: []const Branch = &.{},
};

pub const After = enum {
    /// The kept line stays on screen. The next one starts empty.
    another,
    /// The session ends.
    enough,
};

pub const Source = struct {
    context: *anyopaque,
    /// Called on every key. The meaning belongs here, not in Enter.
    infer: *const fn (context: *anyopaque, line: []const u8) Inference,
    /// The screen already showed the meaning. The source only remembers and decides whether to continue.
    keep: *const fn (context: *anyopaque, line: []const u8) After,
};

pub fn run(init: std.process.Init, source: Source) !void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    if (consoleInput()) {
        try runLive(stdout, source);
    } else {
        try runLines(init.io, stdout, source);
    }
}

fn heldOf(inference: Inference, line: []const u8) []const u8 {
    if (inference.held.len > 0) return inference.held;
    for (inference.branches) |branch| {
        if (std.mem.eql(u8, branch.text, line)) return branch.held;
    }
    return "";
}

const max_line = 4096;
const max_visible = 8;

const Line = struct {
    buf: [max_line]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    fn text(self: *const Line) []const u8 {
        return self.buf[0..self.len];
    }

    fn insert(self: *Line, bytes: []const u8) bool {
        if (bytes.len == 0) return true;
        if (self.len + bytes.len > self.buf.len) return false;
        const tail = self.len - self.cursor;
        if (tail > 0) {
            std.mem.copyBackwards(
                u8,
                self.buf[self.cursor + bytes.len ..][0..tail],
                self.buf[self.cursor..][0..tail],
            );
        }
        @memcpy(self.buf[self.cursor..][0..bytes.len], bytes);
        self.cursor += bytes.len;
        self.len += bytes.len;
        return true;
    }

    fn backspace(self: *Line) void {
        if (self.cursor == 0) return;
        const start = stepBack(self.text(), self.cursor);
        const removed = self.cursor - start;
        const tail = self.len - self.cursor;
        if (tail > 0) {
            std.mem.copyForwards(u8, self.buf[start..][0..tail], self.buf[self.cursor..][0..tail]);
        }
        self.len -= removed;
        self.cursor = start;
    }

    fn deleteForward(self: *Line) void {
        if (self.cursor >= self.len) return;
        const next = stepForward(self.text(), self.cursor);
        const removed = next - self.cursor;
        const tail = self.len - next;
        if (tail > 0) {
            std.mem.copyForwards(u8, self.buf[self.cursor..][0..tail], self.buf[next..][0..tail]);
        }
        self.len -= removed;
    }

    fn moveLeft(self: *Line) void {
        self.cursor = stepBack(self.text(), self.cursor);
    }

    fn moveRight(self: *Line) void {
        self.cursor = stepForward(self.text(), self.cursor);
    }

    fn replaceAll(self: *Line, replacement: []const u8) bool {
        if (replacement.len > self.buf.len) return false;
        @memcpy(self.buf[0..replacement.len], replacement);
        self.len = replacement.len;
        self.cursor = replacement.len;
        return true;
    }
};

fn stepBack(text: []const u8, index: usize) usize {
    if (index == 0) return 0;
    var i = index - 1;
    while (i > 0 and text[i] & 0b1100_0000 == 0b1000_0000) i -= 1;
    return i;
}

fn stepForward(text: []const u8, index: usize) usize {
    if (index >= text.len) return text.len;
    const width = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
    const next = index + width;
    return if (next > text.len) text.len else next;
}

fn columns(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

fn windowStart(count: usize, selected: usize, maxn: usize) usize {
    if (count <= maxn) return 0;
    const half = maxn / 2;
    var start: usize = if (selected > half) selected - half else 0;
    if (start + maxn > count) start = count - maxn;
    return start;
}

fn moveSelection(selected: usize, count: usize, down: bool) usize {
    if (count == 0) return 0;
    if (down) {
        if (selected + 1 >= count) return 0;
        return selected + 1;
    }
    if (selected == 0) return count - 1;
    return selected - 1;
}

const windows = std.os.windows;

const STD_INPUT_HANDLE: windows.DWORD = @bitCast(@as(i32, -10));
const STD_OUTPUT_HANDLE: windows.DWORD = @bitCast(@as(i32, -11));
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: windows.DWORD = 0x0004;
const KEY_EVENT: windows.WORD = 0x0001;
const VK_BACK: windows.WORD = 0x08;
const VK_TAB: windows.WORD = 0x09;
const VK_RETURN: windows.WORD = 0x0D;
const VK_ESCAPE: windows.WORD = 0x1B;
const VK_HOME: windows.WORD = 0x24;
const VK_LEFT: windows.WORD = 0x25;
const VK_UP: windows.WORD = 0x26;
const VK_RIGHT: windows.WORD = 0x27;
const VK_DOWN: windows.WORD = 0x28;
const VK_DELETE: windows.WORD = 0x2E;
const VK_C: windows.WORD = 0x43;

extern "kernel32" fn GetStdHandle(nStdHandle: windows.DWORD) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn GetConsoleMode(hConsoleHandle: windows.HANDLE, lpMode: *windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: windows.HANDLE, dwMode: windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ReadConsoleInputW(
    hConsoleInput: windows.HANDLE,
    lpBuffer: *INPUT_RECORD,
    nLength: windows.DWORD,
    lpNumberOfEventsRead: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

const KEY_EVENT_RECORD = extern struct {
    bKeyDown: windows.BOOL,
    wRepeatCount: windows.WORD,
    wVirtualKeyCode: windows.WORD,
    wVirtualScanCode: windows.WORD,
    UnicodeChar: windows.WCHAR,
    dwControlKeyState: windows.DWORD,
};

const INPUT_RECORD = extern struct {
    EventType: windows.WORD,
    reserved: windows.WORD = 0,
    KeyEvent: KEY_EVENT_RECORD,
};

fn consoleInput() bool {
    var mode: windows.DWORD = undefined;
    return GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), &mode).toBool();
}

fn runLive(stdout: *Io.Writer, source: Source) !void {
    const out_handle = GetStdHandle(STD_OUTPUT_HANDLE);
    var out_mode: windows.DWORD = undefined;
    const restore = GetConsoleMode(out_handle, &out_mode).toBool();
    if (restore) _ = SetConsoleMode(out_handle, out_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    defer if (restore) {
        _ = SetConsoleMode(out_handle, out_mode);
    };

    const in_handle = GetStdHandle(STD_INPUT_HANDLE);
    var line = Line{};
    var selected: usize = 0;
    var inference = source.infer(source.context, line.text());
    selected = clamp(selected, inference.branches.len);
    try draw(stdout, &line, inference, selected, true);

    while (true) {
        var record: INPUT_RECORD = undefined;
        var read_count: windows.DWORD = 0;
        if (!ReadConsoleInputW(in_handle, &record, 1, &read_count).toBool() or read_count == 0) return error.Unexpected;
        if (record.EventType != KEY_EVENT or record.KeyEvent.bKeyDown == .FALSE) continue;

        const key = record.KeyEvent;
        const ctrl = (key.dwControlKeyState & 0x000C) != 0;
        if (ctrl and (key.wVirtualKeyCode == VK_C or key.UnicodeChar == 3)) {
            try finish(stdout, &line, inference, selected);
            return;
        }

        var edited = false;
        var repeats = key.wRepeatCount;
        if (repeats == 0) repeats = 1;

        switch (key.wVirtualKeyCode) {
            VK_ESCAPE => {
                try finish(stdout, &line, inference, selected);
                return;
            },
            VK_RETURN => {
                const current = line.text();
                if (current.len == 0) continue;
                try draw(stdout, &line, inference, selected, false);
                try stdout.writeAll("\n");
                try stdout.flush();
                if (source.keep(source.context, current) == .enough) return;
                line = .{};
                selected = 0;
                edited = true;
            },
            VK_TAB => {
                if (inference.branches.len == 0) continue;
                if (!line.replaceAll(inference.branches[selected].text)) continue;
                edited = true;
            },
            VK_UP => {
                selected = moveSelection(selected, inference.branches.len, false);
            },
            VK_DOWN => {
                selected = moveSelection(selected, inference.branches.len, true);
            },
            VK_LEFT => while (repeats > 0) : (repeats -= 1) line.moveLeft(),
            VK_RIGHT => while (repeats > 0) : (repeats -= 1) line.moveRight(),
            VK_HOME => line.cursor = 0,
            VK_DELETE => {
                while (repeats > 0) : (repeats -= 1) line.deleteForward();
                edited = true;
            },
            VK_BACK => {
                while (repeats > 0) : (repeats -= 1) line.backspace();
                edited = true;
            },
            else => {
                if (ctrl) continue;
                var encoded: [4]u8 = undefined;
                const bytes = encodeKey(key.UnicodeChar, &encoded) orelse continue;
                while (repeats > 0) : (repeats -= 1) {
                    if (!line.insert(bytes)) break;
                }
                edited = true;
            },
        }

        if (edited) {
            inference = source.infer(source.context, line.text());
            selected = clamp(selected, inference.branches.len);
        }
        try draw(stdout, &line, inference, selected, true);
    }
}

fn finish(stdout: *Io.Writer, line: *const Line, inference: Inference, selected: usize) !void {
    try draw(stdout, line, inference, selected, false);
    try stdout.writeAll("\n");
    try stdout.flush();
}

fn clamp(selected: usize, count: usize) usize {
    if (count == 0 or selected >= count) return 0;
    return selected;
}

fn encodeKey(unit: u16, out: *[4]u8) ?[]u8 {
    if (unit < 32 or (unit > 0xD7FF and unit < 0xE000)) return null;
    const len = std.unicode.utf8Encode(unit, out) catch return null;
    return out[0..len];
}

fn draw(
    stdout: *Io.Writer,
    line: *const Line,
    inference: Inference,
    selected: usize,
    show_list: bool,
) !void {
    const branches = inference.branches;
    const start = windowStart(branches.len, selected, max_visible);
    const shown = @min(max_visible, branches.len - start);
    const more = branches.len - (start + shown);
    const list_lines: usize = if (show_list and branches.len > 0) shown + @intFromBool(more > 0) else 0;
    const held = heldOf(inference, line.text());

    try stdout.writeAll("\r\x1b[J> ");
    try stdout.writeAll(line.text());
    if (held.len > 0) {
        try stdout.writeAll("  ");
        try stdout.writeAll(held);
    }

    if (list_lines > 0) {
        for (branches[start..][0..shown], start..) |item, index| {
            if (index == selected) {
                try stdout.writeAll("\n\x1b[7m> ");
                try stdout.writeAll(item.text);
                try stdout.writeAll("\x1b[0m");
            } else {
                try stdout.writeAll("\n  ");
                try stdout.writeAll(item.text);
            }
            if (item.held.len > 0) {
                try stdout.writeAll("  \x1b[2m");
                try stdout.writeAll(item.held);
                try stdout.writeAll("\x1b[0m");
            }
        }
        if (more > 0) try stdout.print("\n  +{d}", .{more});
        try stdout.print("\x1b[{d}A", .{list_lines});
    }

    try stdout.print("\x1b[{d}G", .{3 + columns(line.text()[0..line.cursor])});
    try stdout.flush();
}

fn runLines(io: Io, stdout: *Io.Writer, source: Source) !void {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_file: Io.File.Reader = .initStreaming(.stdin(), io, &stdin_buffer);
    const stdin = &stdin_file.interface;

    while (true) {
        try stdout.writeAll("> ");
        try stdout.flush();
        const raw = stdin.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try stdout.writeAll("line too long\n");
                try stdout.flush();
                continue;
            },
            else => |e| return e,
        } orelse return;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const inference = source.infer(source.context, line);
        const held = heldOf(inference, line);
        if (held.len > 0) {
            try stdout.writeAll(held);
            try stdout.writeAll("\n");
        }
        for (inference.branches, 0..) |item, index| {
            if (index == max_visible) break;
            try stdout.print("  {s}", .{item.text});
            if (item.held.len > 0) try stdout.print("  {s}", .{item.held});
            try stdout.writeAll("\n");
        }
        try stdout.flush();
        if (source.keep(source.context, line) == .enough) return;
    }
}

test "insert and delete in the middle of the line" {
    var line = Line{};
    try std.testing.expect(line.insert("abcd"));
    line.cursor = 2;
    try std.testing.expect(line.insert("XY"));
    try std.testing.expectEqualStrings("abXYcd", line.text());
    line.backspace();
    try std.testing.expectEqualStrings("abXcd", line.text());
    try std.testing.expectEqual(@as(usize, 3), line.cursor);
}

test "backspace removes one utf-8 character" {
    var line = Line{};
    try std.testing.expect(line.insert("é"));
    try std.testing.expectEqual(@as(usize, 2), line.len);
    line.backspace();
    try std.testing.expectEqual(@as(usize, 0), line.len);
}

test "tab replaces the line with the chosen branch" {
    var line = Line{};
    try std.testing.expect(line.insert("he"));
    const items = [_]Branch{
        .{ .text = "help", .held = "help" },
        .{ .text = "hello", .held = "hi" },
    };
    try std.testing.expect(line.replaceAll(items[1].text));
    try std.testing.expectEqualStrings("hello", line.text());
    try std.testing.expectEqual(@as(usize, 5), line.cursor);
}

test "arrows wrap the selection" {
    try std.testing.expectEqual(@as(usize, 1), moveSelection(0, 3, true));
    try std.testing.expectEqual(@as(usize, 0), moveSelection(2, 3, true));
    try std.testing.expectEqual(@as(usize, 2), moveSelection(0, 3, false));
}

test "a line's meaning does not wait for enter" {
    const branches = [_]Branch{
        .{ .text = "help", .held = "list" },
        .{ .text = "hello", .held = "hi" },
    };
    try std.testing.expectEqualStrings("", heldOf(.{ .branches = &branches }, "he"));
    try std.testing.expectEqualStrings("list", heldOf(.{ .branches = &branches }, "help"));
    try std.testing.expectEqualStrings("= 5", heldOf(.{ .held = "= 5" }, "2+3"));
}

test "the window follows the selected branch" {
    try std.testing.expectEqual(@as(usize, 0), windowStart(10, 1, 8));
    try std.testing.expectEqual(@as(usize, 2), windowStart(10, 9, 8));
}
