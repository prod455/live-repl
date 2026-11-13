# live-repl

The line shows its meaning before Enter.

In an ordinary terminal, Enter runs the line and only then is there an answer. Here the source reads the line on every key. When the sentence already has a meaning, that meaning appears. When the line could become other sentences, those branches appear with it. Enter does not calculate and does not choose: it keeps what is already on screen and opens the next line. Tab is what enters a branch.

This fits any source that can infer. A calculation, a command, a filter, a search. The library does not know the domain.

## Contract

`infer` returns:

- `held` empty while the sentence is still open. The screen stays quiet.
- `held` set at the moment a meaning exists. No Enter.
- `branches` for the other possible sentences. Each branch can carry its own meaning.

`keep` runs only on Enter, so the source can remember (the last number, the chosen command) and say whether another line follows or the session ends.

The slices must stay alive until the next `infer` or `keep`.

```zig
fn infer(context: *anyopaque, line: []const u8) live_repl.Inference {
    _ = context;
    if (std.mem.eql(u8, line, "2+3")) return .{ .held = "= 5" };
    return .{};
}
```

## Keys

| Key | Effect |
| --- | --- |
| text | changes the line and asks for meaning again |
| Tab | the line becomes the selected branch |
| Up and Down | move between branches |
| Enter | keeps the line and opens another |
| Esc or Ctrl+C | closes |

In a pipe, without a console, the line arrives whole. Live meaning needs the Windows console. Zig 0.17.1.

## Example

`zig build run` infers commands. `h` is still a branch. `help` already holds its meaning. `quit` on Enter ends the session.

## License

MIT.
