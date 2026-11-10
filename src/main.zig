const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const resources = @import("resources.zig");
const Uart = @import("uart.zig").Uart(resources.Access);
const Guard = @import("lock.zig").Guard;
const State = struct { next: ?*State, allocation: a.DriverHeapAllocation, registration: u64, number: u32, starting: bool, uart: Uart };
var api: ?*const r4os.r4dev.DriverApi2 = null;
var cpu_heap: ?r4os.r4dev.DriverHeapContext = null;
var serial: ?r4os.r4dev.DriverSerialContext = null;
var head: ?*State = null;
var lines: [32]bool = .{false} ** 32;
var line_flags: [32]u32 = .{0} ** 32;
comptime {
    if (!@import("builtin").is_test) asm (r4os.technical2.driverEntriesAsm("serial_init", "serial_shutdown"));
}
fn state(raw: u64) *State {
    return @ptrFromInt(raw);
}
fn publish(s: *State, events: u32) void {
    if (events != 0) {
        const service = serial orelse return;
        _ = service.notify(s.registration, events);
    }
}
fn getConfig(raw: *const a.SerialConfig) ?a.SerialConfig {
    if (raw.version != 1 or raw.size < @sizeOf(a.SerialConfig)) return null;
    return raw.*;
}
fn opening(raw: u64, input: *const a.SerialConfig) callconv(.c) i32 {
    const s = state(raw);
    const cfg = getConfig(input) orelse return a.serial_error_invalid;
    const check = Guard.acquire();
    const starting = s.starting;
    check.release();
    if (starting) return a.serial_error_busy;
    if (s.uart.bus.activate() != 0) return a.serial_error_hardware;
    const guard = Guard.acquire();
    const result = s.uart.open(&cfg);
    guard.release();
    if (result == 0) publish(s, a.serial_event_state);
    return result;
}
fn configure(raw: u64, input: *const a.SerialConfig) callconv(.c) i32 {
    const s = state(raw);
    const cfg = getConfig(input) orelse return a.serial_error_invalid;
    const guard = Guard.acquire();
    const result = s.uart.configure(&cfg);
    guard.release();
    if (result == 0) publish(s, a.serial_event_state);
    return result;
}
fn reading(raw: u64, buffer: [*]u8, length: u32, out: *a.SerialTransfer) callconv(.c) i32 {
    const s = state(raw);
    const guard = Guard.acquire();
    const result = s.uart.read(buffer[0..length], out);
    out.status = result;
    if (result != 0 and out.completed != 0) out.flags |= a.serial_transfer_partial;
    guard.release();
    return result;
}
fn writing(raw: u64, buffer: [*]const u8, length: u32, out: *a.SerialTransfer) callconv(.c) i32 {
    const s = state(raw);
    const guard = Guard.acquire();
    const old = s.uart.tx_bytes;
    const result = s.uart.write(buffer[0..length], out);
    const events: u32 = if (s.uart.tx_bytes != old) a.serial_event_tx else 0;
    out.status = result;
    if (result != 0 and out.completed != 0) out.flags |= a.serial_transfer_partial;
    guard.release();
    publish(s, events);
    return result;
}
fn draining(raw: u64) callconv(.c) i32 {
    const s = state(raw);
    const guard = Guard.acquire();
    const result = s.uart.drain();
    guard.release();
    return result;
}
fn status(raw: u64, out: *a.SerialStatus) callconv(.c) i32 {
    const s = state(raw);
    const guard = Guard.acquire();
    s.uart.status(out);
    guard.release();
    return 0;
}
fn closing(raw: u64, flags: u32) callconv(.c) i32 {
    const s = state(raw);
    const guard = Guard.acquire();
    const result = s.uart.close(flags);
    guard.release();
    return result;
}
fn irq(number: u8, _: usize) callconv(.c) u32 {
    var handled = false;
    var next: ?*State = undefined;
    {
        const g = Guard.acquire();
        next = head;
        g.release();
    }
    while (next) |s| {
        const g = Guard.acquire();
        next = s.next;
        var events: u32 = 0;
        if (!s.starting and s.uart.bus.irq == number) {
            const result = s.uart.service();
            handled = handled or result.handled;
            events = result.events;
        }
        g.release();
        publish(s, events);
    }
    return if (handled) a.irq_result_handled else 0;
}
fn add(ctx: *const r4os.r4dev.DriverContext2, declaration: resources.Declaration) i32 {
    const heap = cpu_heap orelse return a.serial_error_owner;
    const service = serial orelse return a.serial_error_owner;
    var allocation: a.DriverHeapAllocation = .{};
    const allocated = heap.allocate(@sizeOf(State), @alignOf(State), &allocation);
    if (allocated != 0) return a.serial_error_no_memory;
    const s: *State = @ptrFromInt(allocation.cpu_address);
    @memset(std.mem.asBytes(s), 0);
    s.allocation = allocation;
    s.number = declaration.number;
    s.starting = true;
    s.uart.init(declaration.access);
    const d: a.SerialBackend = .{ .com_number = s.number, .resource_kind = s.uart.bus.kind, .resource_base = s.uart.bus.physical, .resource_length = s.uart.bus.bytes, .irq = s.uart.bus.irq, .capabilities = a.serial_cap_rx | a.serial_cap_tx | a.serial_cap_rts_cts | a.serial_cap_line_status | a.serial_cap_irq, .hardware_identity = s.uart.bus.identity, .context = @intFromPtr(s), .open = @intFromPtr(&opening), .configure = @intFromPtr(&configure), .read = @intFromPtr(&reading), .write = @intFromPtr(&writing), .drain = @intFromPtr(&draining), .status = @intFromPtr(&status), .close = @intFromPtr(&closing) };
    const registered = service.register(&d, &s.registration);
    if (registered != 0) {
        const released = heap.release(allocation.handle);
        if (released != 0) {
            const g = Guard.acquire();
            s.next = head;
            head = s;
            g.release();
        }
        return registered;
    }
    {
        const g = Guard.acquire();
        s.next = head;
        head = s;
        g.release();
    }
    // No other instance owns this registration. Reserved debug COM1 is never
    // probed here; its first normal open probes after the kernel grants admission.
    const allowed = service.admission(s.registration);
    var present = false;
    if (allowed == 0) {
        if (s.uart.bus.activate() != 0) return a.serial_error_hardware;
        const g = Guard.acquire();
        present = s.uart.probe();
        g.release();
    } else if (allowed == a.serial_error_busy) {
        present = true;
    } else {
        return allowed;
    }
    if (!present) {
        const removed = service.unregister(s.registration);
        if (removed != 0) return removed;
        s.registration = 0;
        {
            const g = Guard.acquire();
            std.debug.assert(head == s);
            head = s.next;
            g.release();
        }
        const released = heap.release(allocation.handle);
        if (released != 0) {
            const g = Guard.acquire();
            s.next = head;
            head = s;
            g.release();
            return released;
        }
        return 0;
    }
    const line = s.uart.bus.irq;
    if (lines[line]) {
        if (line_flags[line] != s.uart.bus.irq_flags) return a.serial_error_busy;
    } else {
        const result = ctx.irqRegister(line, irq, 0, s.uart.bus.irq_flags);
        if (result != 0) return result;
        lines[line] = true;
        line_flags[line] = s.uart.bus.irq_flags;
    }
    {
        const g = Guard.acquire();
        s.starting = false;
        g.release();
    }
    return 0;
}
fn declarations(ctx: *const r4os.r4dev.DriverContext2, text: []const u8, clock: u32) i32 {
    if (std.ascii.eqlIgnoreCase(text, "none")) return 0;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |entry| {
        if (entry.len == 0) return a.serial_error_invalid;
        const d = resources.parse(ctx, entry, clock) catch return a.serial_error_invalid;
        const result = add(ctx, d);
        if (result != 0) return result;
    }
    return 0;
}
export fn serial_init(input: *const r4os.r4dev.DriverApi2) callconv(.c) i32 {
    api = input;
    const ctx = r4os.r4dev.DriverContext2.init(input);
    if (!ctx.requires(.{ "heap_query", "serial_query", "get_option", "irq_register", "irq_unregister", "port_inb", "port_outb", "pci_device_at", "pci_device_count", "pci_map_bar", "pci_read_bar", "pci_read_config32", "pci_write_config32" })) return a.serial_error_unsupported;
    cpu_heap = ctx.heap() orelse return a.serial_error_unsupported;
    serial = ctx.serial() orelse return a.serial_error_unsupported;
    const raw_clock = std.mem.span(ctx.getOption("SERIAL", "clock"));
    const clock = if (raw_clock.len == 0) 115200 else std.fmt.parseInt(u32, raw_clock, 10) catch return a.serial_error_invalid;
    if (clock == 0) return a.serial_error_invalid;
    const configured = std.mem.span(ctx.getOption("SERIAL", "ports"));
    const ports = if (configured.len == 0) "1:3f8:4,2:2f8:3,3:3e8:4,4:2e8:3" else configured;
    const result = declarations(&ctx, ports, clock);
    if (result != 0) return result;
    const pci = std.mem.span(ctx.getOption("SERIAL", "pci"));
    if (pci.len != 0) {
        const extra = declarations(&ctx, pci, clock);
        if (extra != 0) return extra;
    }
    ctx.logInfo("SERIAL.R4D ready; dynamic COM catalog, debug claim retained");
    return 0;
}
export fn serial_shutdown() callconv(.c) i32 {
    const raw = api orelse return 0;
    const ctx = r4os.r4dev.DriverContext2.init(raw);
    const service = serial orelse return 0;
    const heap = cpu_heap orelse return a.serial_error_owner;
    // Exact port admission/wait draining belongs to unregister below; generic
    // module admission closes only after this DriverShutdown acknowledges.
    // A failed unregister/IRQ/heap release leaves the exact remaining list intact.
    var next = head;
    while (next) |s| {
        next = s.next;
        if (s.registration != 0) {
            const result = service.unregister(s.registration);
            if (result != 0) return result;
            s.registration = 0;
        }
    }
    for (0..32) |line| {
        if (lines[line]) {
            const result = ctx.irqUnregister(@intCast(line), irq, 0);
            if (result != 0) return result;
            lines[line] = false;
        }
    }
    while (head) |s| {
        const next_state = s.next;
        const handle = s.allocation.handle;
        const result = heap.release(handle);
        if (result != 0) return result;
        head = next_state;
    }
    api = null;
    cpu_heap = null;
    serial = null;
    return 0;
}

// Exact production Access/Uart and callback bodies with a register peer.
// Only privileged IF manipulation is excluded by builtin.is_test in Guard.
const TestPort = struct {
    var registers: [8]u8 = @splat(0);
    var stuck = false;
    var iir_reads: usize = 0;
    fn input(port: u16) callconv(.c) u8 {
        const index = port - 0x2f8;
        if (index == 2) {
            iir_reads += 1;
            return if (stuck) 2 else 0xc1;
        }
        return registers[index];
    }
    fn output(port: u16, value: u8) callconv(.c) void {
        registers[port - 0x2f8] = value;
    }
    fn setup(table: *r4os.r4dev.DriverApi2, node: *State) !void {
        registers = @splat(0);
        registers[5] = 0x60;
        stuck = false;
        iir_reads = 0;
        @memset(std.mem.asBytes(table), 0);
        table.magic = r4os.technical2.abi.driver_magic;
        table.version = r4os.technical2.abi.driver_version;
        table.size = @sizeOf(@TypeOf(table.*));
        table.port_inb = input;
        table.port_outb = output;
        node.* = .{ .next = null, .allocation = .{}, .registration = 0, .number = 2, .starting = false, .uart = undefined };
        node.uart.init(.{ .api = table, .kind = a.serial_resource_io, .base = 0x2f8, .physical = 0x2f8, .bytes = 8, .irq = 3, .irq_flags = 0 });
        try std.testing.expectEqual(@as(i32, 0), node.uart.open(&.{}));
    }
};

test "SERIAL actual write callback reports partial hardware failure and retains UART until physical drain" {
    var table: r4os.r4dev.DriverApi2 = undefined;
    var node: State = undefined;
    try TestPort.setup(&table, &node);
    TestPort.registers[5] = 0xff;
    var result: a.SerialTransfer = .{};
    const rc = writing(@intFromPtr(&node), "ABCD", 4, &result);
    try std.testing.expectEqual(a.serial_error_hardware, rc);
    try std.testing.expectEqual(rc, result.status);
    try std.testing.expectEqual(@as(u32, 4), result.completed);
    try std.testing.expect(result.flags & a.serial_transfer_partial != 0);
    try std.testing.expect(node.uart.opened);
    try std.testing.expectEqualStrings("ABCD", node.uart.tx[0..4]);
    try std.testing.expectEqual(a.serial_error_hardware, node.uart.close(a.serial_close_abort));
    try std.testing.expect(node.uart.opened);
    TestPort.registers[5] = 0x20; // THRE is not the physical TEMT receipt.
    try std.testing.expectEqual(a.serial_error_would_block, node.uart.close(a.serial_close_abort));
    try std.testing.expect(node.uart.opened);
    try std.testing.expectEqual(@as(u64, 4), node.uart.tx_dropped);
    TestPort.registers[5] = 0x60;
    try std.testing.expectEqual(@as(i32, 0), node.uart.close(a.serial_close_abort));
    try std.testing.expect(!node.uart.opened);
}

test "SERIAL actual read callback retains completed bytes with overflow and exact partial flags" {
    var table: r4os.r4dev.DriverApi2 = undefined;
    var node: State = undefined;
    try TestPort.setup(&table, &node);
    node.uart.rx[0] = 'Z';
    node.uart.rh = 1;
    node.uart.unreported_drop = 3;
    var bytes: [8]u8 = @splat(0xcd);
    var result: a.SerialTransfer = .{};
    const rc = reading(@intFromPtr(&node), &bytes, bytes.len, &result);
    try std.testing.expectEqual(a.serial_error_overflow, rc);
    try std.testing.expectEqual(rc, result.status);
    try std.testing.expectEqual(@as(u32, 1), result.completed);
    try std.testing.expectEqual(@as(u64, 3), result.overflows);
    try std.testing.expect(result.flags & (a.serial_transfer_partial | a.serial_transfer_overflow) == a.serial_transfer_partial | a.serial_transfer_overflow);
    try std.testing.expectEqual(@as(u8, 'Z'), bytes[0]);
    for (bytes[1..]) |byte| try std.testing.expectEqual(@as(u8, 0xcd), byte);
    try std.testing.expectEqual(@as(u64, 0), node.uart.unreported_drop);
}

test "SERIAL stuck IRQ is bounded and disables the source without pretending UART close" {
    var table: r4os.r4dev.DriverApi2 = undefined;
    var node: State = undefined;
    try TestPort.setup(&table, &node);
    TestPort.stuck = true;
    TestPort.iir_reads = 0;
    const result = node.uart.service();
    try std.testing.expectEqual(@as(usize, 65), TestPort.iir_reads);
    try std.testing.expect(result.handled and result.events & a.serial_event_error != 0);
    try std.testing.expect(node.uart.failed and node.uart.opened);
    try std.testing.expectEqual(@as(u8, 0), TestPort.registers[1]);
    TestPort.registers[5] = 0x20;
    try std.testing.expectEqual(a.serial_error_would_block, node.uart.close(0));
    try std.testing.expect(node.uart.opened);
    TestPort.registers[5] = 0x60;
    try std.testing.expectEqual(@as(i32, 0), node.uart.close(0));
}
