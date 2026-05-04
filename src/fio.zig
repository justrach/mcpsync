//! fio.zig — Thin libc-based file I/O helpers for Zig 0.16.
//!
//! std.fs.cwd() is gone in 0.16 (replaced by std.Io.Dir.cwd(io)).
//! We avoid threading Io through everything by calling libc directly.

const std = @import("std");

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fclose(f: *anyopaque) c_int;
extern "c" fn fread(buf: *anyopaque, size: usize, count: usize, f: *anyopaque) usize;
extern "c" fn fwrite(buf: *const anyopaque, size: usize, count: usize, f: *anyopaque) usize;
extern "c" fn fseek(f: *anyopaque, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(f: *anyopaque) c_long;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
const F_OK: c_int = 0;

fn toSentinel(alloc: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const buf = try alloc.allocSentinel(u8, s.len, 0);
    @memcpy(buf[0..s.len], s);
    return buf;
}

/// Read an entire file into an allocated slice.  Returns error.FileNotFound if
/// the file does not exist.
pub fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const cpath = try toSentinel(alloc, path);
    defer alloc.free(cpath);

    const f = fopen(cpath, "rb") orelse return error.FileNotFound;
    defer _ = fclose(f);

    _ = fseek(f, 0, SEEK_END);
    const size: usize = @intCast(ftell(f));
    _ = fseek(f, 0, SEEK_SET);

    if (size > max_bytes) return error.FileTooBig;

    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    const n = fread(buf.ptr, 1, size, f);
    if (n != size) return error.ReadFailed;
    return buf;
}

/// Write bytes to a file, creating or truncating it.
pub fn writeFile(alloc: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const cpath = try toSentinel(alloc, path);
    defer alloc.free(cpath);

    const f = fopen(cpath, "wb") orelse return error.OpenFailed;
    const n = fwrite(data.ptr, 1, data.len, f);
    _ = fclose(f);
    if (n != data.len) return error.WriteFailed;
}

/// Atomic write: write to tmp path then rename.
pub fn writeFileAtomic(alloc: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const tmp = try std.fmt.allocPrint(alloc, "{s}.mcpsync.tmp", .{path});
    defer alloc.free(tmp);

    try writeFile(alloc, tmp, data);

    const ctmp = try toSentinel(alloc, tmp);
    defer alloc.free(ctmp);
    const cdst = try toSentinel(alloc, path);
    defer alloc.free(cdst);

    if (rename(ctmp, cdst) != 0) return error.RenameFailed;
}

/// Returns true if path exists.
pub fn pathExists(alloc: std.mem.Allocator, path: []const u8) !bool {
    const cpath = try toSentinel(alloc, path);
    defer alloc.free(cpath);
    return access(cpath, F_OK) == 0;
}

/// Create all directories in path (like mkdir -p).
pub fn makeDirPath(alloc: std.mem.Allocator, path: []const u8) !void {
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            const sub = path[0..i];
            const csub = try toSentinel(alloc, sub);
            defer alloc.free(csub);
            _ = mkdir(csub, 0o755); // ignore errors (already exists is fine)
        }
    }
}
