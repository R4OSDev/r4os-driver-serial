const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
pub const Access = struct {
    api: *const a.DriverApi,
    kind: u32,
    base: u64,
    physical: u64,
    bytes: u64,
    irq: u8,
    irq_flags: u32,
    shift: u3 = 0,
    width: u8 = 1,
    clock: u32 = 115200,
    identity: [64]u8 = .{0} ** 64,
    pci: ?a.PciDeviceInfo = null,
    decode_mask: u32 = 0,
    pub fn activate(self: *const Access) i32 {
        const info = self.pci orelse return 0;
        const ctx = r4os.r4dev.DriverContext.init(self.api);
        const command = ctx.pciReadConfig32(info, 4) & 0xffff;
        if (command & self.decode_mask == self.decode_mask) return 0;
        return ctx.pciWriteConfig32(info, 4, command | self.decode_mask);
    }
    pub fn read(self: *const Access, index: u8) u8 {
        const off: usize = @as(usize, index) << self.shift;
        if (self.kind == a.serial_resource_io) return self.api.port_inb(@intCast(self.base + off));
        if (self.width == 4) {
            const p: *volatile u32 = @ptrFromInt(self.base + off);
            return @truncate(p.*);
        }
        const p: *volatile u8 = @ptrFromInt(self.base + off);
        return p.*;
    }
    pub fn write(self: *const Access, index: u8, value: u8) void {
        const off: usize = @as(usize, index) << self.shift;
        if (self.kind == a.serial_resource_io) {
            self.api.port_outb(@intCast(self.base + off), value);
            return;
        }
        if (self.width == 4) {
            const p: *volatile u32 = @ptrFromInt(self.base + off);
            p.* = value;
        } else {
            const p: *volatile u8 = @ptrFromInt(self.base + off);
            p.* = value;
        }
    }
    pub fn baudBase(self: *const Access) u32 {
        return self.clock;
    }
};
pub const Declaration = struct { number: u32, access: Access };
fn parseValue(part: ?[]const u8, base: u8) !u32 {
    return std.fmt.parseInt(u32, part orelse return error.InvalidResource, base) catch error.InvalidResource;
}
// A declaration supplies stable logical identity; iteration/free-slot order
// never supplies COM numbers. PCI resources are mapped only after exact BDF/BAR
// confirmation; this is deliberately not a universal PCI UART detector.
pub fn parse(ctx: *const r4os.r4dev.DriverContext, text: []const u8, clock: u32) !Declaration {
    var parts = std.mem.splitScalar(u8, text, ':');
    const number = try parseValue(parts.next(), 10);
    const kind = parts.next() orelse return error.InvalidResource;
    if (number == 0) return error.InvalidResource;
    var access: Access = undefined;
    if (!std.mem.eql(u8, kind, "P")) {
        const base = try parseValue(kind, 16);
        const irq = try parseValue(parts.next(), 10);
        if (base == 0 or base > 65528 or base & 7 != 0 or irq >= 32 or irq == 0 or irq == 1 or irq == 12 or parts.next() != null) return error.InvalidResource;
        access = .{ .api = ctx.api, .kind = a.serial_resource_io, .base = base, .physical = base, .bytes = 8, .irq = @intCast(irq), .irq_flags = a.irq_flag_shared, .clock = clock };
        _ = try std.fmt.bufPrint(access.identity[0..63], "ISA_{X:0>4}", .{base});
    } else {
        const k = try parseValue(parts.next(), 10);
        const b = try parseValue(parts.next(), 10);
        const d = try parseValue(parts.next(), 10);
        const f = try parseValue(parts.next(), 10);
        const bar = try parseValue(parts.next(), 10);
        const off = try parseValue(parts.next(), 16);
        const irq = try parseValue(parts.next(), 10);
        const shift = try parseValue(parts.next(), 10);
        const width = try parseValue(parts.next(), 10);
        if (k > 255 or b > 255 or d > 31 or f > 7 or bar > 5 or irq >= 32 or irq == 0 or irq == 1 or irq == 12 or shift > 3 or (width != 1 and width != 4) or parts.next() != null) return error.InvalidResource;
        var info: a.PciDeviceInfo = .{};
        var found = false;
        var i: u32 = 0;
        while (i < ctx.pciDeviceCount()) : (i += 1) {
            if (ctx.pciDeviceAt(i, &info) == 0 and info.bus_kind == k and info.bus == b and info.device == d and info.function == f) {
                found = true;
                break;
            }
        }
        if (!found or info.class_code != 7 or (info.subclass != 0 and info.subclass != 2) or info.interrupt_line != irq) return error.UnconfirmedPciUart;
        const raw = ctx.pciReadBar(info, @intCast(bar));
        const span: u32 = (@as(u32, 7) << @intCast(shift)) + width;
        const total = std.math.add(u32, off, span) catch return error.InvalidResource;
        if (raw & 1 != 0) {
            if (shift != 0 or width != 1) return error.InvalidResource;
            const base = (raw & 0xfffffffc) + @as(u64, off);
            if (base + span > 65536) return error.InvalidResource;
            access = .{ .api = ctx.api, .kind = a.serial_resource_io, .base = base, .physical = base, .bytes = span, .irq = @intCast(irq), .irq_flags = a.irq_flag_shared | a.irq_flag_level_low, .clock = clock, .pci = info, .decode_mask = 1 };
        } else {
            if (raw == 0 or (width == 4 and (shift < 2 or off & 3 != 0))) return error.InvalidResource;
            var region: a.MmioRegion = .{};
            if (ctx.pciMapBar(info, @intCast(bar), total, 0, &region) != 0 or region.virt_addr == 0 or region.bytes < total) return error.PciMapping;
            if (width == 4 and (region.virt_addr + off) & 3 != 0) return error.PciMapping;
            access = .{ .api = ctx.api, .kind = a.serial_resource_mmio, .base = region.virt_addr + off, .physical = region.phys_addr + off, .bytes = span, .irq = @intCast(irq), .irq_flags = a.irq_flag_shared | a.irq_flag_level_low, .shift = @intCast(shift), .width = @intCast(width), .clock = clock, .pci = info, .decode_mask = 2 };
        }
        _ = try std.fmt.bufPrint(access.identity[0..63], "PCI_{X}_{X:0>2}_{X}_{X}_{X}_{X}", .{ k, b, d, f, bar, off });
    }
    return .{ .number = number, .access = access };
}
