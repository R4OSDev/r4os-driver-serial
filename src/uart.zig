const std = @import("std");
const a = @import("r4os").abi;
// One resident instance per registered UART. The owner serializes calls/IRQ;
// this device implementation neither allocates, waits nor calls kernel owners.
pub fn Uart(comptime Bus: type) type {
    return struct {
        const Self = @This();
        pub const capacity: usize = 4096;
        bus: Bus,
        rx: [capacity]u8,
        tx: [capacity]u8,
        rh: usize,
        rt: usize,
        th: usize,
        tt: usize,
        config: a.SerialConfig,
        opened: bool,
        closing: bool,
        aborting: bool,
        known: bool,
        failed: bool,
        fifo: u8,
        rx_bytes: u64,
        tx_bytes: u64,
        rx_dropped: u64,
        tx_dropped: u64,
        line_errors: u64,
        unreported_drop: u64,
        error_bits: u8,
        pub fn init(self: *Self, bus: Bus) void {
            @memset(std.mem.asBytes(self), 0);
            self.bus = bus;
            self.config = .{};
            self.fifo = 1;
        }
        pub fn pendingRx(self: *const Self) usize {
            return self.rh -% self.rt;
        }
        pub fn pendingTx(self: *const Self) usize {
            return self.th -% self.tt;
        }
        pub fn probe(self: *Self) bool {
            const old = self.bus.read(7);
            defer self.bus.write(7, old);
            self.bus.write(7, 0x5a);
            if (self.bus.read(7) != 0x5a) return false;
            self.bus.write(7, 0xa5);
            self.known = self.bus.read(7) == 0xa5;
            return self.known;
        }
        fn decode(self: *const Self, c: *const a.SerialConfig) ?struct { div: u16, lcr: u8 } {
            if (c.version != 1 or c.size < @sizeOf(a.SerialConfig) or c.baud_rate == 0 or c.data_bits < 5 or c.data_bits > 8 or c.parity > 4 or (c.stop_bits != 1 and c.stop_bits != 2) or c.flow_control > 1 or c.flags != 0 or c.reserved0 != 0 or c.reserved1 != 0 or c.reserved2 != 0) return null;
            const base: u32 = self.bus.baudBase();
            const div: u32 = base / c.baud_rate;
            if (base % c.baud_rate != 0 or div == 0 or div > 65535) return null;
            const parity: u8 = switch (c.parity) {
                0 => 0,
                1 => 0x08,
                2 => 0x18,
                3 => 0x28,
                4 => 0x38,
                else => unreachable,
            };
            return .{ .div = @intCast(div), .lcr = (c.data_bits - 5) | parity | @as(u8, if (c.stop_bits == 2) 4 else 0) };
        }
        fn line(self: *Self) ?u8 {
            const s = self.bus.read(5);
            if (s == 0xff) {
                self.failed = true;
                return null;
            }
            if (s & 0x1e != 0) {
                self.line_errors +%= 1;
                self.error_bits |= s & 0x1e;
                if (s & 2 != 0) {
                    self.rx_dropped +%= 1;
                    self.unreported_drop +%= 1;
                }
            }
            return s;
        }
        fn receiverFlow(self: *Self) void {
            var mcr: u8 = 0x0b;
            if (self.config.flow_control == a.serial_flow_rts_cts and self.pendingRx() > capacity - 32) mcr &= ~@as(u8, 2);
            self.bus.write(4, mcr);
        }
        fn transmitAllowed(self: *Self) bool {
            return self.config.flow_control != a.serial_flow_rts_cts or self.bus.read(6) & 0x10 != 0;
        }
        fn interrupts(self: *Self) void {
            if (!self.opened or self.aborting) {
                self.bus.write(1, 0);
                return;
            }
            var ier: u8 = 0x05;
            if (self.config.flow_control == a.serial_flow_rts_cts) ier |= 0x08;
            // A low CTS must not leave an always-ready THRE interrupt asserted. Its
            // modem transition will rearm the pending software queue.
            if (self.pendingTx() != 0 and self.transmitAllowed()) ier |= 2;
            self.bus.write(1, ier);
        }
        fn setup(self: *Self, c: *const a.SerialConfig, bits: anytype) void {
            self.bus.write(1, 0);
            self.bus.write(3, bits.lcr | 0x80);
            self.bus.write(0, @truncate(bits.div));
            self.bus.write(1, @truncate(bits.div >> 8));
            self.bus.write(3, bits.lcr);
            self.config = c.*;
            self.receiverFlow();
            self.interrupts();
        }
        pub fn open(self: *Self, c: *const a.SerialConfig) i32 {
            const bits = self.decode(c) orelse return a.serial_error_unsupported;
            if (self.opened) return a.serial_error_busy;
            if (!self.known and !self.probe()) return a.serial_error_not_found;
            self.rh = 0;
            self.rt = 0;
            self.th = 0;
            self.tt = 0;
            self.closing = false;
            self.aborting = false;
            self.failed = false;
            self.error_bits = 0;
            self.unreported_drop = 0;
            self.bus.write(1, 0);
            self.bus.write(2, 0xc7);
            self.fifo = if (self.bus.read(2) & 0xc0 == 0xc0) 16 else 1;
            // Configuration writes have no separate UART completion. An admitted open
            // retains the device even if a later LSR detects loss; only close can release.
            self.opened = true;
            self.setup(c, bits);
            return 0;
        }
        pub fn configure(self: *Self, c: *const a.SerialConfig) i32 {
            const bits = self.decode(c) orelse return a.serial_error_unsupported;
            if (!self.opened or self.closing) return a.serial_error_closed;
            const s = self.line() orelse return a.serial_error_hardware;
            if (self.pendingRx() != 0 or self.pendingTx() != 0 or s & 0x61 != 0x60) return a.serial_error_busy;
            self.setup(c, bits);
            return 0;
        }
        fn receive(self: *Self) u32 {
            var events: u32 = 0;
            var rounds: usize = 0;
            while (rounds < 256) : (rounds += 1) {
                const s = self.line() orelse return events | a.serial_event_error;
                if (s & 0x1e != 0) events |= a.serial_event_error;
                if (s & 1 == 0) break;
                const byte = self.bus.read(0);
                self.rx_bytes +%= 1;
                if (self.pendingRx() == capacity) {
                    self.rx_dropped +%= 1;
                    self.unreported_drop +%= 1;
                    events |= a.serial_event_error;
                } else {
                    self.rx[self.rh & (capacity - 1)] = byte;
                    self.rh +%= 1;
                    events |= a.serial_event_rx;
                }
            }
            self.receiverFlow();
            return events;
        }
        fn pump(self: *Self) u32 {
            const s = self.line() orelse return a.serial_event_error;
            if (self.pendingTx() == 0 or s & 0x20 == 0 or !self.transmitAllowed()) {
                self.interrupts();
                return 0;
            }
            const n: usize = @min(self.pendingTx(), @as(usize, self.fifo));
            for (0..n) |_| {
                self.bus.write(0, self.tx[self.tt & (capacity - 1)]);
                self.tt +%= 1;
                self.tx_bytes +%= 1;
            }
            self.interrupts();
            return a.serial_event_tx;
        }
        pub fn service(self: *Self) struct { events: u32, handled: bool } {
            if (!self.opened or self.aborting or self.failed) return .{ .events = 0, .handled = false };
            var events: u32 = 0;
            var n: usize = 0;
            while (n < 64) : (n += 1) {
                const iir = self.bus.read(2);
                if (iir & 1 != 0) break;
                switch (iir & 0x0e) {
                    0x04, 0x0c, 0x06 => events |= self.receive(),
                    0x02 => events |= self.pump(),
                    0x00 => {
                        _ = self.bus.read(6);
                        events |= a.serial_event_modem | self.pump();
                    },
                    else => break,
                }
                if (self.failed) {
                    self.bus.write(1, 0);
                    events |= a.serial_event_error;
                    break;
                }
            }
            if (n == 64 and self.bus.read(2) & 1 == 0) {
                self.failed = true;
                self.bus.write(1, 0);
                events |= a.serial_event_error;
            }
            return .{ .events = events, .handled = n != 0 };
        }
        pub fn read(self: *Self, out: []u8, info: *a.SerialTransfer) i32 {
            info.* = .{ .requested = @intCast(out.len) };
            if (!self.opened or self.closing) return a.serial_error_closed;
            const n: usize = @min(out.len, self.pendingRx());
            for (out[0..n]) |*b| {
                b.* = self.rx[self.rt & (capacity - 1)];
                self.rt +%= 1;
            }
            info.completed = @intCast(n);
            if (!self.failed) self.receiverFlow();
            if (self.unreported_drop != 0) {
                info.overflows = self.unreported_drop;
                self.unreported_drop = 0;
                info.flags |= a.serial_transfer_overflow;
                return a.serial_error_overflow;
            }
            if (self.error_bits != 0) {
                self.error_bits = 0;
                info.flags |= a.serial_transfer_line_error;
                return a.serial_error_hardware;
            }
            if (self.failed) return a.serial_error_hardware;
            return if (n != 0 or out.len == 0) 0 else a.serial_error_would_block;
        }
        pub fn write(self: *Self, data: []const u8, info: *a.SerialTransfer) i32 {
            info.* = .{ .requested = @intCast(data.len) };
            if (!self.opened or self.closing) return a.serial_error_closed;
            if (self.failed) return a.serial_error_hardware;
            const n: usize = @min(data.len, capacity - self.pendingTx());
            for (data[0..n]) |b| {
                self.tx[self.th & (capacity - 1)] = b;
                self.th +%= 1;
            }
            info.completed = @intCast(n);
            _ = self.pump();
            if (self.failed) return a.serial_error_hardware;
            return if (n != 0 or data.len == 0) 0 else a.serial_error_would_block;
        }
        pub fn drain(self: *Self) i32 {
            if (!self.opened) return a.serial_error_closed;
            if (self.failed) return a.serial_error_hardware;
            const s = self.line() orelse return a.serial_error_hardware;
            return if (self.pendingTx() == 0 and s & 0x60 == 0x60) 0 else a.serial_error_would_block;
        }
        pub fn close(self: *Self, flags: u32) i32 {
            if (!self.opened) return 0;
            if (flags & ~a.serial_close_abort != 0) return a.serial_error_invalid;
            self.closing = true;
            if (flags & a.serial_close_abort != 0 and !self.aborting) {
                self.aborting = true;
                self.bus.write(1, 0);
                self.tx_dropped +%= self.pendingTx();
                self.tt = self.th;
                self.bus.write(2, 0x07);
            }
            const s = self.line() orelse return a.serial_error_hardware;
            if (self.pendingTx() != 0 or s & 0x60 != 0x60) return a.serial_error_would_block;
            self.bus.write(1, 0);
            self.bus.write(4, 0);
            self.bus.write(2, 0x07);
            self.rx_dropped +%= self.pendingRx();
            self.rt = self.rh;
            self.opened = false;
            self.closing = false;
            self.aborting = false;
            return 0;
        }
        pub fn status(self: *Self, out: *a.SerialStatus) void {
            var lsr: u8 = 0;
            var msr: u8 = 0;
            if (self.opened) {
                lsr = self.line() orelse 0xff;
                msr = self.bus.read(6);
                if (!self.failed) self.interrupts();
            }
            out.* = .{ .flags = (if (self.opened) @as(u32, a.serial_port_open) else 0) | (if (self.closing) @as(u32, a.serial_port_closing) else 0) | (if (self.failed) @as(u32, a.serial_port_hardware_error) else 0) | (if (self.fifo == 16) @as(u32, a.serial_port_fifo) else 0), .line_status = lsr, .modem_status = msr, .rx_pending = @intCast(self.pendingRx()), .tx_pending = @intCast(self.pendingTx()), .baud_rate = self.config.baud_rate, .rx_bytes = self.rx_bytes, .tx_bytes = self.tx_bytes, .rx_dropped = self.rx_dropped, .tx_dropped = self.tx_dropped, .line_errors = self.line_errors, .last_error = if (self.failed) a.serial_error_hardware else 0 };
        }
    };
}
