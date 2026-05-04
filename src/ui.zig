//! ui.zig — ANSI terminal rendering for mcpsync.
//!
//! Provides:
//!   • A style system (color on/off based on tty detection)
//!   • printBanner       — ASCII art header
//!   • printStatusTable  — the main status grid (tools × MCPs)
//!   • printSyncResult   — what changed after a sync
//!   • printServerList   — simple list of source-of-truth servers
//!   • printDiff         — what would change (dry-run)
//!   • printError / printSuccess / printInfo — inline messages

const std = @import("std");
const config = @import("config.zig");
const targets = @import("targets.zig");

// ── Style ─────────────────────────────────────────────────────────────────────

pub const Style = struct {
    reset: []const u8,
    bold: []const u8,
    dim: []const u8,
    red: []const u8,
    green: []const u8,
    yellow: []const u8,
    blue: []const u8,
    magenta: []const u8,
    cyan: []const u8,
    white: []const u8,

    pub fn status(self: Style, state: targets.ServerState) []const u8 {
        return switch (state) {
            .in_sync => self.green,
            .missing => self.red,
            .outdated => self.yellow,
            .foreign => self.dim,
        };
    }

    pub fn statusIcon(state: targets.ServerState) []const u8 {
        return switch (state) {
            .in_sync => "✓",
            .missing => "✗",
            .outdated => "~",
            .foreign => "·",
        };
    }

    pub fn statusLabel(state: targets.ServerState) []const u8 {
        return switch (state) {
            .in_sync => "in sync",
            .missing => "missing",
            .outdated => "outdated",
            .foreign => "foreign",
        };
    }
};

pub const color_on = Style{
    .reset = "\x1b[0m",
    .bold = "\x1b[1m",
    .dim = "\x1b[2m",
    .red = "\x1b[31m",
    .green = "\x1b[32m",
    .yellow = "\x1b[33m",
    .blue = "\x1b[34m",
    .magenta = "\x1b[35m",
    .cyan = "\x1b[36m",
    .white = "\x1b[97m",
};

pub const color_off = Style{
    .reset = "",
    .bold = "",
    .dim = "",
    .red = "",
    .green = "",
    .yellow = "",
    .blue = "",
    .magenta = "",
    .cyan = "",
    .white = "",
};

pub fn autoStyle() Style {
    // Check if stdout is a tty
    const isatty = struct {
        extern "c" fn isatty(fd: c_int) c_int;
    }.isatty;
    return if (isatty(1) != 0) color_on else color_off;
}

// ── Banner ────────────────────────────────────────────────────────────────────

pub fn printBanner(writer: anytype, s: Style, version: []const u8) !void {
    try writer.print(
        \\{s}{s}
        \\  ███╗   ███╗ ██████╗██████╗ {s}sync{s}
        \\  ████╗ ████║██╔════╝██╔══██╗
        \\  ██╔████╔██║██║     ██████╔╝
        \\  ██║╚██╔╝██║██║     ██╔═══╝
        \\  ██║ ╚═╝ ██║╚██████╗██║
        \\  ╚═╝     ╚═╝ ╚═════╝╚═╝  {s}v{s}  {s}a codegraff product{s}{s}
        \\
        \\  {s}MCP server sync for all your AI tools{s}
        \\
        \\
    , .{
        s.bold,    s.cyan,    // {s}{s}  — bold+cyan on
        s.white,   s.cyan,    // {s}sync{s}
        s.dim,     version,   // {s}v{s}
        s.magenta, s.dim,     // {s}a codegraff product{s}
        s.reset,              // {s}  — reset all
        s.dim,     s.reset,   // {s}MCP server sync...{s}
    });
}

// ── Status Table ─────────────────────────────────────────────────────────────

/// Print the full status grid: rows = MCP servers, cols = tools.
pub fn printStatusTable(
    writer: anytype,
    alloc: std.mem.Allocator,
    s: Style,
    reg: *const config.Registry,
    tool_targets: []const targets.Target,
) !void {
    if (reg.servers.items.len == 0) {
        try writer.print("  {s}No MCP servers in source of truth.{s}\n\n", .{ s.dim, s.reset });
        try writer.print("  Run {s}mcpsync add <name> --cmd <path>{s} to add one.\n\n", .{ s.bold, s.reset });
        return;
    }

    // Collect all server names (source-of-truth + foreign)
    var all_names: std.ArrayList([]const u8) = .empty;
    defer all_names.deinit(alloc);

    for (reg.servers.items) |*srv| try all_names.append(alloc, srv.name);

    // Add foreign names from targets
    outer: for (tool_targets) |*t| {
        for (t.servers.items) |*local| {
            if (reg.get(local.name) != null) continue;
            for (all_names.items) |n| {
                if (std.mem.eql(u8, n, local.name)) continue :outer;
            }
            try all_names.append(alloc, local.name);
        }
    }

    // Column widths
    const name_col_w: usize = blk: {
        var max: usize = 6; // "SERVER"
        for (all_names.items) |n| max = @max(max, n.len);
        break :blk max + 2;
    };
    const tool_col_w: usize = 12;

    // Header row
    try writer.print("  {s}{s}{s:<[4]}{s}", .{ s.bold, s.dim, "SERVER", s.reset, name_col_w });
    for (tool_targets) |t| {
        try writer.print("{s}{s}{s:<[4]}{s}", .{ s.bold, s.blue, t.display_name, s.reset, tool_col_w });
    }
    try writer.writeByte('\n');

    // Divider
    try writer.writeAll("  ");
    var dw: usize = 0;
    while (dw < name_col_w) : (dw += 1) try writer.writeByte('-');
    for (tool_targets) |_| {
        var tw: usize = 0;
        while (tw < tool_col_w) : (tw += 1) try writer.writeByte('-');
    }
    try writer.writeByte('\n');

    // Data rows
    for (all_names.items) |name| {
        const is_foreign_to_src = reg.get(name) == null;
        const row_color = if (is_foreign_to_src) s.dim else s.white;
        try writer.print("  {s}{s:<[3]}{s}", .{ row_color, name, s.reset, name_col_w });

        for (tool_targets) |*t| {
            if (!t.present) {
                try writer.print("{s}{s:<[3]}{s}", .{ s.dim, "—", s.reset, tool_col_w });
                continue;
            }
            const state = computeState(t, reg, name);
            const col = s.status(state);
            const icon = Style.statusIcon(state);
            try writer.print("{s}{s}{s}{s:<[5]}{s}", .{
                col,
                icon, " ",
                Style.statusLabel(state),
                s.reset,
                tool_col_w - 2,
            });
        }
        try writer.writeByte('\n');
    }

    try writer.writeByte('\n');

    // Legend
    try writer.print(
        "  {s}Legend:{s}  {s}✓ in sync{s}  {s}✗ missing{s}  {s}~ outdated{s}  {s}· foreign (not managed){s}\n\n",
        .{
            s.dim,          s.reset,
            s.green,        s.reset,
            s.red,          s.reset,
            s.yellow,       s.reset,
            s.dim,          s.reset,
        },
    );
}

fn computeState(t: *const targets.Target, reg: *const config.Registry, name: []const u8) targets.ServerState {
    // foreign to source-of-truth
    if (reg.get(name) == null) return .foreign;

    // find in target
    for (t.servers.items) |*local| {
        if (!std.mem.eql(u8, local.name, name)) continue;
        const src = reg.get(name).?;
        return if (src.eql(local.*)) .in_sync else .outdated;
    }
    return .missing;
}

// ── Sync Result ───────────────────────────────────────────────────────────────

pub const SyncAction = struct {
    target_name: []const u8,
    server_name: []const u8,
    action: enum { added, updated, skipped },
};

pub fn printSyncResult(
    writer: anytype,
    s: Style,
    actions: []const SyncAction,
    targets_skipped: []const []const u8,
) !void {
    if (actions.len == 0 and targets_skipped.len == 0) {
        try writer.print("  {s}✓ Everything is already in sync.{s}\n\n", .{ s.green, s.reset });
        return;
    }

    var added: usize = 0;
    var updated: usize = 0;

    for (actions) |a| {
        switch (a.action) {
            .added => {
                try writer.print("  {s}+{s} {s:<16} → {s}\n", .{ s.green, s.reset, a.server_name, a.target_name });
                added += 1;
            },
            .updated => {
                try writer.print("  {s}~{s} {s:<16} ↻ {s}\n", .{ s.yellow, s.reset, a.server_name, a.target_name });
                updated += 1;
            },
            .skipped => {},
        }
    }

    for (targets_skipped) |t| {
        try writer.print("  {s}·{s} {s} {s}(not installed, skipped){s}\n", .{ s.dim, s.reset, t, s.dim, s.reset });
    }

    try writer.writeByte('\n');
    try writer.print(
        "  {s}Done.{s}  {s}{d} added{s}  {s}{d} updated{s}\n\n",
        .{ s.bold, s.reset, s.green, added, s.reset, s.yellow, updated, s.reset },
    );
}

// ── Diff ─────────────────────────────────────────────────────────────────────

pub fn printDiff(
    writer: anytype,
    alloc: std.mem.Allocator,
    s: Style,
    reg: *const config.Registry,
    tool_targets: []const targets.Target,
) !void {
    var any = false;

    for (tool_targets) |*t| {
        const states = try t.computeStates(alloc, reg);
        defer {
            for (states) |*ts| alloc.free(ts.name);
            alloc.free(states);
        }

        var tool_header_printed = false;

        for (states) |ts| {
            if (ts.state == .in_sync or ts.state == .foreign) continue;

            if (!tool_header_printed) {
                try writer.print("  {s}{s}{s}:\n", .{ s.bold, t.display_name, s.reset });
                tool_header_printed = true;
                any = true;
            }

            switch (ts.state) {
                .missing => try writer.print(
                    "    {s}+ {s}{s}  {s}(will add){s}\n",
                    .{ s.green, ts.name, s.reset, s.dim, s.reset },
                ),
                .outdated => try writer.print(
                    "    {s}~ {s}{s}  {s}(will update){s}\n",
                    .{ s.yellow, ts.name, s.reset, s.dim, s.reset },
                ),
                else => {},
            }
        }
        if (tool_header_printed) try writer.writeByte('\n');
    }

    if (!any) {
        try writer.print("  {s}✓ Nothing to do — all tools are in sync.{s}\n\n", .{ s.green, s.reset });
    } else {
        try writer.print("  Run {s}mcpsync sync{s} to apply.\n\n", .{ s.bold, s.reset });
    }
}

// ── Server List ───────────────────────────────────────────────────────────────

pub fn printServerList(writer: anytype, s: Style, reg: *const config.Registry) !void {
    if (reg.servers.items.len == 0) {
        try writer.print("  {s}No servers configured.{s}\n\n", .{ s.dim, s.reset });
        return;
    }

    try writer.print("  {s}{s:<20}{s:<36}  {s}TRANSPORT{s}\n", .{
        s.bold,
        "NAME",
        "COMMAND / URL",
        s.dim, s.reset,
    });
    try writer.writeAll("  ");
    var i: usize = 0;
    while (i < 70) : (i += 1) try writer.writeByte('-');
    try writer.writeByte('\n');

    for (reg.servers.items) |srv| {
        const desc: []const u8 = if (srv.command) |c| c else if (srv.url) |u| u else "(none)";
        const transport = srv.transport orelse if (srv.url != null) "sse/http" else "stdio";
        try writer.print("  {s}{s:<20}{s}{s:<36}  {s}{s}{s}\n", .{
            s.cyan, srv.name,
            s.reset, desc,
            s.dim, transport, s.reset,
        });
        if (srv.args.len > 0) {
            try writer.writeAll("  ");
            var j: usize = 0;
            while (j < 20) : (j += 1) try writer.writeByte(' ');
            try writer.print("{s}args: ", .{s.dim});
            for (srv.args, 0..) |a, ai| {
                const comma: []const u8 = if (ai + 1 < srv.args.len) " " else "";
                try writer.print("{s}{s}", .{ a, comma });
            }
            try writer.print("{s}\n", .{s.reset});
        }
    }
    try writer.writeByte('\n');
}

// ── Inline messages ───────────────────────────────────────────────────────────

pub fn printSuccess(writer: anytype, s: Style, comptime fmt: []const u8, args: anytype) !void {
    try writer.print("  {s}✓{s} ", .{ s.green, s.reset });
    try writer.print(fmt, args);
    try writer.writeByte('\n');
}

pub fn printError(writer: anytype, s: Style, comptime fmt: []const u8, args: anytype) !void {
    try writer.print("  {s}✗{s} ", .{ s.red, s.reset });
    try writer.print(fmt, args);
    try writer.writeByte('\n');
}

pub fn printInfo(writer: anytype, s: Style, comptime fmt: []const u8, args: anytype) !void {
    try writer.print("  {s}·{s} ", .{ s.dim, s.reset });
    try writer.print(fmt, args);
    try writer.writeByte('\n');
}

pub fn printSourcePath(writer: anytype, s: Style, path: []const u8) !void {
    try writer.print(
        "  {s}Source of truth:{s} {s}{s}{s}\n\n",
        .{ s.dim, s.reset, s.bold, path, s.reset },
    );
}
