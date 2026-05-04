//! main.zig — mcpsync CLI entry point
//!
//! Commands:
//!   mcpsync                  → status (default)
//!   mcpsync status           → show sync state table across all tools
//!   mcpsync sync             → apply source-of-truth to all installed tools
//!   mcpsync diff             → show what sync would change (dry-run)
//!   mcpsync list             → list MCPs in source of truth
//!   mcpsync add <name> [opts]→ add/update an MCP in source-of-truth then sync
//!   mcpsync remove <name>    → remove an MCP from source-of-truth then sync
//!   mcpsync init             → bootstrap ~/.mcpconfig.json from existing tool configs
//!   mcpsync help             → usage

const std = @import("std");
const config = @import("config.zig");
const targets_mod = @import("targets.zig");
const ui = @import("ui.zig");
const fio = @import("fio.zig");

const VERSION = "0.0.1";

// ── Raw-fd stdout writer (mirrors codedb Out pattern) ────────────────────────

extern "c" fn isatty(fd: c_int) c_int;
extern "c" fn write(fd: c_int, ptr: [*]const u8, len: usize) isize;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;


fn posixGetenv(name: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const ptr = getenv(@ptrCast(&buf)) orelse return null;
    return std.mem.span(ptr);
}

/// Thin wrapper: format + write to stdout fd via allocator.
/// Matches the anytype duck-typing used throughout ui.zig.
const Out = struct {
    alloc: std.mem.Allocator,

    pub fn print(self: Out, comptime fmt: []const u8, args: anytype) !void {
        const str = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(str);
        var rem = str;
        while (rem.len > 0) {
            const n = write(1, rem.ptr, rem.len);
            if (n <= 0) return error.WriteFailed;
            rem = rem[@intCast(n)..];
        }
    }

    pub fn writeAll(self: Out, data: []const u8) !void {
        _ = self;
        var rem = data;
        while (rem.len > 0) {
            const n = write(1, rem.ptr, rem.len);
            if (n <= 0) return error.WriteFailed;
            rem = rem[@intCast(n)..];
        }
    }

    pub fn writeByte(self: Out, b: u8) !void {
        _ = self;
        const buf = [1]u8{b};
        _ = write(1, &buf, 1);
    }
};

// ── Main ──────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.c_allocator;
    const out = Out{ .alloc = alloc };
    const s = if (isatty(1) != 0) ui.color_on else ui.color_off;

    // Read argv via the iterator API (safe under all optimization levels).
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(alloc);
    var it = std.process.Args.Iterator.init(init.args);
    while (it.next()) |arg| try args_list.append(alloc, arg);
    const args = args_list.items;

    const cmd = if (args.len >= 2) args[1] else "status";

    if (std.mem.eql(u8, cmd, "help") or
        std.mem.eql(u8, cmd, "--help") or
        std.mem.eql(u8, cmd, "-h"))
    {
        try printUsage(out, s);
        return;
    }

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        try out.print("mcpsync {s}\n", .{VERSION});
        return;
    }

    if (std.mem.eql(u8, cmd, "status")) {
        try cmdStatus(alloc, out, s);
    } else if (std.mem.eql(u8, cmd, "sync")) {
        try cmdSync(alloc, out, s, args[2..]);
    } else if (std.mem.eql(u8, cmd, "diff")) {
        try cmdDiff(alloc, out, s, args[2..]);
    } else if (std.mem.eql(u8, cmd, "list")) {
        try cmdList(alloc, out, s);
    } else if (std.mem.eql(u8, cmd, "add")) {
        try cmdAdd(alloc, out, s, args[2..]);
    } else if (std.mem.eql(u8, cmd, "remove") or std.mem.eql(u8, cmd, "rm")) {
        try cmdRemove(alloc, out, s, args[2..]);
    } else if (std.mem.eql(u8, cmd, "init")) {
        try cmdInit(alloc, out, s);
    } else if (args.len <= 1) {
        try cmdStatus(alloc, out, s);
    } else {
        try ui.printError(out, s, "Unknown command: {s}", .{cmd});
        try out.writeByte('\n');
        try printUsage(out, s);
        std.process.exit(1);
    }
}

// ── status ────────────────────────────────────────────────────────────────────

fn cmdStatus(alloc: std.mem.Allocator, out: Out, s: ui.Style) !void {
    try ui.printBanner(out, s, VERSION);

    const src_path = try config.sourcePath(alloc);
    defer alloc.free(src_path);
    try ui.printSourcePath(out, s, src_path);

    // If the source-of-truth file doesn't exist yet, hint about init
    if (!(fio.pathExists(alloc, src_path) catch false)) {
        try ui.printInfo(out, s, "{s}~/.mcpconfig.json{s} not found.", .{ s.bold, s.reset });
        try ui.printInfo(out, s, "Run {s}mcpsync init{s} to bootstrap it from your existing tool configs.", .{ s.bold, s.reset });
        try out.writeByte('\n');
        return;
    }

    var reg = try config.load(alloc);
    defer reg.deinit();

    const tool_targets = try targets_mod.discoverAll(alloc);
    defer {
        for (tool_targets) |*t| t.deinit();
        alloc.free(tool_targets);
    }

    try ui.printStatusTable(out, alloc, s, &reg, tool_targets);
}

// ── sync ──────────────────────────────────────────────────────────────────────

fn cmdSync(alloc: std.mem.Allocator, out: Out, s: ui.Style, filter: []const []const u8) !void {
    try ui.printBanner(out, s, VERSION);

    var reg = try config.load(alloc);
    defer reg.deinit();

    const src_path = try config.sourcePath(alloc);
    defer alloc.free(src_path);
    try ui.printSourcePath(out, s, src_path);

    const tool_targets = try targets_mod.discoverAll(alloc);
    defer {
        for (tool_targets) |*t| t.deinit();
        alloc.free(tool_targets);
    }

    // Validate filter IDs up front
    for (filter) |id| {
        if (!targets_mod.isKnownId(id)) {
            try ui.printError(out, s, "Unknown tool '{s}'. Known tools: {s}", .{ id, targets_mod.knownIds() });
            std.process.exit(1);
        }
    }

    var actions: std.ArrayList(ui.SyncAction) = .empty;
    defer actions.deinit(alloc);
    var skipped: std.ArrayList([]const u8) = .empty;
    defer skipped.deinit(alloc);

    for (tool_targets) |*t| {
        // Skip if a filter was given and this tool isn't in it
        if (filter.len > 0 and !sliceContains(filter, t.id)) continue;

        // Skip tools whose config directory doesn't exist at all
        if (!t.present) {
            const dir_path = std.fs.path.dirname(t.config_path) orelse continue;
            const dir_exists = (fio.pathExists(alloc, dir_path) catch false);
            if (!dir_exists) {
                try skipped.append(alloc, t.display_name);
                continue;
            }
        }

        // Compute what changes for reporting
        for (reg.servers.items) |*srv| {
            const state = serverState(t, &reg, srv.name);
            switch (state) {
                .missing => try actions.append(alloc, .{
                    .target_name = t.display_name,
                    .server_name = srv.name,
                    .action = .added,
                }),
                .outdated => try actions.append(alloc, .{
                    .target_name = t.display_name,
                    .server_name = srv.name,
                    .action = .updated,
                }),
                .in_sync, .foreign => {},
            }
        }

        targets_mod.syncTarget(alloc, t, &reg) catch |err| {
            try ui.printError(out, s, "Failed to sync {s}: {s}", .{ t.display_name, @errorName(err) });
            continue;
        };
    }

    try ui.printSyncResult(out, s, actions.items, skipped.items);
}

fn sliceContains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| if (std.mem.eql(u8, s, needle)) return true;
    return false;
}

fn serverState(t: *const targets_mod.Target, reg: *const config.Registry, name: []const u8) targets_mod.ServerState {
    if (reg.get(name) == null) return .foreign;
    for (t.servers.items) |*local| {
        if (!std.mem.eql(u8, local.name, name)) continue;
        const src = reg.get(name).?;
        return if (src.eql(local.*)) .in_sync else .outdated;
    }
    return .missing;
}

// ── diff ──────────────────────────────────────────────────────────────────────

fn cmdDiff(alloc: std.mem.Allocator, out: Out, s: ui.Style, filter: []const []const u8) !void {
    try ui.printBanner(out, s, VERSION);

    var reg = try config.load(alloc);
    defer reg.deinit();

    const src_path = try config.sourcePath(alloc);
    defer alloc.free(src_path);
    try ui.printSourcePath(out, s, src_path);

    const all_targets = try targets_mod.discoverAll(alloc);
    defer {
        for (all_targets) |*t| t.deinit();
        alloc.free(all_targets);
    }

    // Validate filter IDs up front
    for (filter) |id| {
        if (!targets_mod.isKnownId(id)) {
            try ui.printError(out, s, "Unknown tool '{s}'. Known tools: {s}", .{ id, targets_mod.knownIds() });
            std.process.exit(1);
        }
    }

    // Build a filtered view (no extra allocation needed — just pointers into all_targets)
    var filtered: std.ArrayList(targets_mod.Target) = .empty;
    defer filtered.deinit(alloc);
    for (all_targets) |t| {
        if (filter.len == 0 or sliceContains(filter, t.id))
            try filtered.append(alloc, t);
    }

    try out.print("  {s}Pending changes:{s}\n\n", .{ s.bold, s.reset });
    try ui.printDiff(out, alloc, s, &reg, filtered.items);
}

// ── list ──────────────────────────────────────────────────────────────────────

fn cmdList(alloc: std.mem.Allocator, out: Out, s: ui.Style) !void {
    try ui.printBanner(out, s, VERSION);

    var reg = try config.load(alloc);
    defer reg.deinit();

    const src_path = try config.sourcePath(alloc);
    defer alloc.free(src_path);
    try ui.printSourcePath(out, s, src_path);

    try out.print("  {s}Source-of-truth MCP servers:{s}\n\n", .{ s.bold, s.reset });
    try ui.printServerList(out, s, &reg);
}

// ── add ───────────────────────────────────────────────────────────────────────

fn cmdAdd(alloc: std.mem.Allocator, out: Out, s: ui.Style, raw_args: []const []const u8) !void {
    if (raw_args.len == 0) {
        try ui.printError(out, s, "Usage: mcpsync add <name> --cmd <path> [--args a b ...] [--url <url>]", .{});
        std.process.exit(1);
    }

    const name = raw_args[0];
    var cmd_path: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var arg_list: std.ArrayList([]const u8) = .empty;
    defer arg_list.deinit(alloc);

    var i: usize = 1;
    while (i < raw_args.len) : (i += 1) {
        const a = raw_args[i];
        if (std.mem.eql(u8, a, "--cmd") or std.mem.eql(u8, a, "-c")) {
            i += 1;
            if (i >= raw_args.len) {
                try ui.printError(out, s, "--cmd requires a value", .{});
                std.process.exit(1);
            }
            cmd_path = raw_args[i];
        } else if (std.mem.eql(u8, a, "--url") or std.mem.eql(u8, a, "-u")) {
            i += 1;
            if (i >= raw_args.len) {
                try ui.printError(out, s, "--url requires a value", .{});
                std.process.exit(1);
            }
            url = raw_args[i];
        } else if (std.mem.eql(u8, a, "--args") or std.mem.eql(u8, a, "-a")) {
            i += 1;
            while (i < raw_args.len and !std.mem.startsWith(u8, raw_args[i], "--")) : (i += 1) {
                try arg_list.append(alloc, raw_args[i]);
            }
            i -%= 1;
        } else {
            try ui.printError(out, s, "Unknown flag: {s}", .{a});
            std.process.exit(1);
        }
    }

    if (cmd_path == null and url == null) {
        try ui.printError(out, s, "Provide either --cmd <path> or --url <url>", .{});
        std.process.exit(1);
    }

    var reg = try config.load(alloc);
    defer reg.deinit();

    const existed = reg.get(name) != null;
    const srv = config.Server{
        .name = name,
        .command = cmd_path,
        .url = url,
        .args = arg_list.items,
        .transport = if (url != null) "sse" else "stdio",
    };
    try reg.add(srv);
    try config.save(alloc, &reg);

    if (existed) {
        try ui.printSuccess(out, s, "Updated {s}{s}{s} in source of truth", .{ s.bold, name, s.reset });
    } else {
        try ui.printSuccess(out, s, "Added {s}{s}{s} to source of truth", .{ s.bold, name, s.reset });
    }
    try out.writeByte('\n');
    try cmdSync(alloc, out, s, &.{});
}

// ── remove ────────────────────────────────────────────────────────────────────

fn cmdRemove(alloc: std.mem.Allocator, out: Out, s: ui.Style, raw_args: []const []const u8) !void {
    if (raw_args.len == 0) {
        try ui.printError(out, s, "Usage: mcpsync remove <name>", .{});
        std.process.exit(1);
    }

    const name = raw_args[0];

    var reg = try config.load(alloc);
    defer reg.deinit();

    if (!reg.remove(name)) {
        try ui.printError(out, s, "Server '{s}' not found in source of truth", .{name});
        std.process.exit(1);
    }

    try config.save(alloc, &reg);
    try ui.printSuccess(out, s, "Removed {s}{s}{s} from source of truth", .{ s.bold, name, s.reset });
    try out.writeByte('\n');
    try cmdSync(alloc, out, s, &.{});
}

// ── init ──────────────────────────────────────────────────────────────────────

/// Bootstrap ~/.mcpconfig.json by collecting the union of all MCP servers
/// already configured across every installed tool.  Additive: if the file
/// already exists its entries are preserved and new ones are merged in.
fn cmdInit(alloc: std.mem.Allocator, out: Out, s: ui.Style) !void {
    try ui.printBanner(out, s, VERSION);

    const src_path = try config.sourcePath(alloc);
    defer alloc.free(src_path);
    try ui.printSourcePath(out, s, src_path);

    // Load existing registry (empty if file doesn't exist yet)
    var reg = try config.load(alloc);
    defer reg.deinit();

    const tool_targets = try targets_mod.discoverAll(alloc);
    defer {
        for (tool_targets) |*t| t.deinit();
        alloc.free(tool_targets);
    }

    var added: usize = 0;

    // Walk every tool and absorb all servers not yet in the registry
    for (tool_targets) |*t| {
        if (!t.present) continue;
        for (t.servers.items) |*srv| {
            if (reg.get(srv.name) != null) continue; // already known
            try reg.add(srv.*);
            try ui.printSuccess(out, s, "Imported {s}{s}{s} from {s}", .{ s.bold, srv.name, s.reset, t.display_name });
            added += 1;
        }
    }

    if (added == 0 and reg.servers.items.len == 0) {
        try ui.printInfo(out, s, "No MCP servers found in any installed tool.", .{});
        try ui.printInfo(out, s, "Use {s}mcpsync add <name> --cmd <path>{s} to add one.", .{ s.bold, s.reset });
        try out.writeByte('\n');
        return;
    }

    try config.save(alloc, &reg);

    try out.writeByte('\n');
    if (added > 0) {
        try ui.printSuccess(out, s, "Wrote {s}{d} server(s){s} to {s}~/.mcpconfig.json{s}", .{ s.bold, reg.servers.items.len, s.reset, s.bold, s.reset });
    } else {
        try ui.printSuccess(out, s, "{s}~/.mcpconfig.json{s} already up to date ({d} servers)", .{ s.bold, s.reset, reg.servers.items.len });
    }
    try out.writeByte('\n');
}

// ── usage ─────────────────────────────────────────────────────────────────────

fn printUsage(out: Out, s: ui.Style) !void {
    try ui.printBanner(out, s, VERSION);
    try out.print(
        \\  {s}USAGE{s}
        \\    mcpsync {s}[command]{s}
        \\
        \\  {s}COMMANDS{s}
        \\    {s}status{s}                    Show sync state across all tools {s}(default){s}
        \\    {s}sync{s} [tool ...]           Apply source-of-truth to all tools, or named tools only
        \\    {s}diff{s} [tool ...]           Preview what sync would change (optionally for named tools)
        \\    {s}list{s}                      List MCP servers in source of truth
        \\    {s}init{s}                      Bootstrap ~/.mcpconfig.json from existing tools
        \\    {s}add{s} <name> [flags]        Add or update a server in source of truth
        \\    {s}remove{s} <name>             Remove a server from source of truth
        \\    {s}help{s}                      Show this message
        \\
    , .{
        s.bold, s.reset,
        s.dim,  s.reset,
        s.bold, s.reset,
        s.cyan, s.reset, s.dim, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
    });
    try out.print(
        \\  {s}ADD FLAGS{s}
        \\    {s}--cmd{s}  <path>             Path to the MCP server binary
        \\    {s}--args{s} <a> [<b> ...]      Arguments passed to the binary
        \\    {s}--url{s}  <url>              URL for HTTP/SSE transport
        \\
        \\  {s}TOOLS{s}
        \\    codex, claude, gemini, devin, graff, forge, cursor, windsurf, opencode
        \\
        \\  {s}EXAMPLES{s}
        \\    mcpsync init
        \\    mcpsync sync
        \\    mcpsync sync codex claude
        \\    mcpsync diff graff
        \\    mcpsync add myserver --cmd ~/bin/myserver --args mcp
        \\    mcpsync add remotemcp --url https://mcp.example.com/mcp
        \\    mcpsync remove myserver
        \\
        \\  {s}SOURCE OF TRUTH{s}
        \\    ~/.mcpconfig.json  (owned by mcpsync; tool configs are additive targets)
        \\
        \\
    , .{
        s.bold, s.reset, // ADD FLAGS
        s.cyan, s.reset, // --cmd
        s.cyan, s.reset, // --args
        s.cyan, s.reset, // --url
        s.bold, s.reset, // TOOLS
        s.bold, s.reset, // EXAMPLES
        s.bold, s.reset, // SOURCE OF TRUTH
    });
}
