const std = @import("std");
const live_repl = @import("live_repl");

const catalog = [_]live_repl.Branch{
    .{ .text = "help", .held = "lists the commands" },
    .{ .text = "hello", .held = "says hello" },
    .{ .text = "time", .held = "shows the local time" },
    .{ .text = "clear", .held = "clears the line" },
    .{ .text = "quit", .held = "closes" },
};

const App = struct {
    matches: [catalog.len]live_repl.Branch = undefined,
    count: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    var app = App{};
    try live_repl.run(init, .{
        .context = @ptrCast(&app),
        .infer = infer,
        .keep = keep,
    });
}

fn infer(context: *anyopaque, line: []const u8) live_repl.Inference {
    const app: *App = @ptrCast(@alignCast(context));
    app.count = 0;
    var held: []const u8 = "";
    for (catalog) |item| {
        if (line.len == 0 or std.mem.startsWith(u8, item.text, line)) {
            app.matches[app.count] = item;
            app.count += 1;
        }
        if (std.mem.eql(u8, item.text, line)) held = item.held;
    }
    return .{
        .held = held,
        .branches = app.matches[0..app.count],
    };
}

fn keep(context: *anyopaque, line: []const u8) live_repl.After {
    _ = context;
    if (std.mem.eql(u8, line, "quit")) return .enough;
    return .another;
}
