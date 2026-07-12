const udp = @import("../transport/udp.zig");

pub const SocketConfig = udp.SocketConfig;
pub const ReceiveResult = udp.ReceiveResult;
pub const UdpErr = udp.UdpErr;

pub const Socket = struct {
    fd: c_int,
    port: u16,
    connected: bool,

    pub fn bind(port: u16, config: SocketConfig) UdpErr!Socket {
        const r = try udp.bind(port, config);
        return .{ .fd = r.fd, .port = r.port, .connected = false };
    }

    pub fn connect(self: *Socket, host: []const u8, port: u16) UdpErr!void {
        try udp.connect(self.fd, host, port);
        self.connected = true;
    }

    pub fn send(self: *Socket, data: []const u8) UdpErr!usize {
        if (!self.connected) return UdpErr.NotConnected;
        return udp.send(self.fd, data);
    }

    pub fn receive(self: *Socket, buffer: []u8) UdpErr!usize {
        if (!self.connected) return UdpErr.NotConnected;
        return udp.receive(self.fd, buffer);
    }

    pub fn sendTo(self: *Socket, host: []const u8, port: u16, data: []const u8) UdpErr!usize {
        return udp.sendTo(self.fd, host, port, data);
    }

    pub fn receiveFrom(self: *Socket, buffer: []u8) UdpErr!ReceiveResult {
        return udp.receiveFrom(self.fd, buffer);
    }

    pub fn joinMulticast(self: *Socket, group: []const u8) UdpErr!void {
        try udp.joinMulticast(self.fd, group);
    }

    pub fn leaveMulticast(self: *Socket, group: []const u8) UdpErr!void {
        try udp.leaveMulticast(self.fd, group);
    }

    pub fn deinit(self: *Socket) void {
        udp.close(self.fd);
    }
};
