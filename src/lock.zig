// Short driver metadata/register owner. No kernel callback, wait, allocation or
// notification while held: IRQ Runtime->driver and task driver->Runtime never
// form a cycle. Saving IF before acquisition also covers same-CPU IRQ entry.
var owned: u8 = 0;
pub const Guard = struct {
    flags: u64,
    pub fn acquire() Guard {
        const flags = asm volatile ("pushfq; popq %[flags]; cli"
            : [flags] "=r" (-> u64),
            :
            : .{ .memory = true });
        while (@cmpxchgWeak(u8, &owned, 0, 1, .acquire, .monotonic) != null) {
            asm volatile ("pause");
        }
        return .{ .flags = flags };
    }
    pub fn release(self: Guard) void {
        @atomicStore(u8, &owned, 0, .release);
        if (self.flags & 0x200 != 0) asm volatile ("sti" ::: .{ .memory = true });
    }
};
