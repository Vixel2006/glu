const tcp = @import("../transport/tcp.zig");

pub const Config = tcp.Config;
pub const TcpErr = tcp.TcpErr;

pub const Listener = struct {
    fd: i32,
    port: u16,
    config: Config,

    pub fn listen(port: u16, config: Config) TcpErr!Listener {
        const r = try tcp.listen(port, config);
        return .{ .fd = r.fd, .port = r.port, .config = config };
    }

    pub fn accept(self: *Listener) TcpErr!Connection {
        const client_fd = try tcp.accept(self.fd, self.config);
        return .{ .fd = client_fd };
    }

    pub fn deinit(self: *Listener) void {
        tcp.close(self.fd);
    }
};

pub const Connection = struct {
    fd: i32,

    pub fn connect(host: []const u8, port: u16, config: Config) TcpErr!Connection {
        const fd = try tcp.connect(host, port, config);
        return .{ .fd = fd };
    }

    pub fn send(self: *Connection, data: []const u8) TcpErr!void {
        try tcp.send(self.fd, data);
    }

    pub fn receive(self: *Connection, buffer: []u8) TcpErr!usize {
        return tcp.receive(self.fd, buffer);
    }

    pub fn deinit(self: *Connection) void {
        tcp.close(self.fd);
    }
};
