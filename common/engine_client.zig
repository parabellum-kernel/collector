const std = @import("std");
const Allocator = std.mem.Allocator;
const JobEnvelope = @import("envelope.zig").JobEnvelope;

const c = std.c;

/// Lightweight HTTP client communicating from standalone collectors to the Parabellum engine.
pub const EngineClient = struct {
    allocator: Allocator,
    engine_url: []const u8,

    pub fn init(allocator: Allocator, engine_url: []const u8) !EngineClient {
        const owned_url = try allocator.dupe(u8, engine_url);
        return .{
            .allocator = allocator,
            .engine_url = owned_url,
        };
    }

    pub fn deinit(self: *EngineClient) void {
        self.allocator.free(self.engine_url);
        self.* = undefined;
    }

    /// Pings the Parabellum engine (`/v1/health` or `/v1/jobs`) to verify connectivity.
    pub fn isOnline(self: *EngineClient) bool {
        const parsed = parseHostPort(self.engine_url);
        const fd = connectToHost(self.allocator, parsed.host, parsed.port) orelse return false;
        defer _ = c.close(fd);

        var req_buf: [512]u8 = undefined;
        const req = std.fmt.bufPrint(&req_buf, "GET /v1/health HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{parsed.host}) catch return false;
        if (c.send(fd, req.ptr, req.len, 0) <= 0) return false;

        var resp_buf: [256]u8 = undefined;
        const n = c.recv(fd, &resp_buf, resp_buf.len - 1, 0);
        if (n <= 0) return false;

        return (std.mem.indexOf(u8, resp_buf[0..@intCast(n)], "HTTP/1.") != null);
    }

    /// Delivers a `JobEnvelope` to the Parabellum engine endpoint (`POST /v1/jobs`).
    /// Returns `true` if delivered successfully, `false` if engine is unreachable.
    pub fn sendJob(self: *EngineClient, job: JobEnvelope) bool {
        const json_body = job.toJson(self.allocator) catch return false;
        defer self.allocator.free(json_body);

        const parsed = parseHostPort(self.engine_url);
        const fd = connectToHost(self.allocator, parsed.host, parsed.port) orelse return false;
        defer _ = c.close(fd);

        const header = std.fmt.allocPrint(
            self.allocator,
            "POST /v1/jobs HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ parsed.host, json_body.len },
        ) catch return false;
        defer self.allocator.free(header);

        if (!sendAll(fd, header)) return false;
        if (!sendAll(fd, json_body)) return false;

        var resp_buf: [256]u8 = undefined;
        const n = c.recv(fd, &resp_buf, resp_buf.len - 1, 0);
        if (n <= 0) return false;

        const resp_slice = resp_buf[0..@intCast(n)];
        if (std.mem.indexOf(u8, resp_slice, "HTTP/1.1 2") != null or std.mem.indexOf(u8, resp_slice, "HTTP/1.0 2") != null) {
            return true;
        }
        return false;
    }

    pub fn parseHostPort(raw_url: []const u8) struct { host: []const u8, port: u16 } {
        var url = raw_url;
        if (std.mem.startsWith(u8, url, "http://")) {
            url = url["http://".len..];
        } else if (std.mem.startsWith(u8, url, "https://")) {
            url = url["https://".len..];
        }
        if (std.mem.indexOfScalar(u8, url, '/')) |slash_idx| {
            url = url[0..slash_idx];
        }

        if (std.mem.indexOfScalar(u8, url, ':')) |colon_idx| {
            const host = url[0..colon_idx];
            const port_str = url[colon_idx + 1 ..];
            const port = std.fmt.parseInt(u16, port_str, 10) catch 8080;
            return .{ .host = host, .port = port };
        }
        return .{ .host = url, .port = 8080 };
    }

    fn connectToHost(allocator: Allocator, host: []const u8, port: u16) ?c_int {
        const host_z = allocator.dupeSentinel(u8, host, 0) catch return null;
        defer allocator.free(host_z);

        var port_buf: [16:0]u8 = undefined;
        const port_z = std.fmt.bufPrintSentinel(&port_buf, "{d}", .{port}, 0) catch return null;

        var hints: c.addrinfo = std.mem.zeroes(c.addrinfo);
        hints.family = c.AF.UNSPEC;
        hints.socktype = c.SOCK.STREAM;

        var res: ?*c.addrinfo = null;
        if (@intFromEnum(c.getaddrinfo(host_z.ptr, port_z.ptr, &hints, &res)) != 0 or res == null) {
            return null;
        }
        defer if (res) |r| c.freeaddrinfo(r);

        var cur = res;
        while (cur) |ai| : (cur = ai.next) {
            const fd = c.socket(@bitCast(ai.family), @bitCast(ai.socktype), @bitCast(ai.protocol));
            if (fd < 0) continue;

            var tv = c.timeval{ .sec = 1, .usec = 0 };
            _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVTIMEO, &tv, @sizeOf(c.timeval));
            _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.SNDTIMEO, &tv, @sizeOf(c.timeval));

            if (ai.addr) |addr| {
                if (c.connect(fd, addr, ai.addrlen) == 0) {
                    return fd;
                }
            }
            _ = c.close(fd);
        }
        return null;
    }

    fn sendAll(fd: c_int, data: []const u8) bool {
        var sent: usize = 0;
        while (sent < data.len) {
            const rc = c.send(fd, data.ptr + sent, data.len - sent, 0);
            if (rc <= 0) return false;
            sent += @intCast(rc);
        }
        return true;
    }
};
