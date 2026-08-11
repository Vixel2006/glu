const std = @import("std");
const builtin = @import("builtin");

pub const Fiber = struct {
    ctx: Context,
    state: State,

    const State = enum(u32) {
        READY,
        RUNNING,
        WAITING,
        DEAD,
    };

    const Context = switch (builtin.cpu.arch) {
        .aarch64 => struct {
            sp: u64,
            fp: u64,
            pc: u64,
        },
        .x86_64 => struct {
            rsp: u64,
            rbp: u64,
            rip: u64,
        },
        else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
    };

    pub const Switch = struct { old: *Context, new: *Context };

    pub inline fn context_switch(s: *const Switch) *const Switch {
        return switch (builtin.cpu.arch) {
            .x86_64 => asm volatile (
                \\ movq 0(%%rsi), %%rax
                \\ movq 8(%%rsi), %%rcx
                \\ leaq 0f(%%rip), %%rdx
                \\ movq %%rsp, 0(%%rax)
                \\ movq %%rbp, 8(%%rax)
                \\ movq %%rdx, 16(%%rax)
                \\ movq 0(%%rcx), %%rsp
                \\ movq 8(%%rcx), %%rbp
                \\ jmpq *16(%%rcx)
                \\ 0:
                : [output] "={rsi}" (-> *const Switch),
                : [input] "{rsi}" (s),
                : .{
                  .rax = true,
                  .rcx = true,
                  .rdx = true,
                  .rbx = true,
                  .rsi = true,
                  .rdi = true,
                  .r8 = true,
                  .r9 = true,
                  .r10 = true,
                  .r11 = true,
                  .r12 = true,
                  .r13 = true,
                  .r14 = true,
                  .r15 = true,
                  .mm0 = true,
                  .mm1 = true,
                  .mm2 = true,
                  .mm3 = true,
                  .mm4 = true,
                  .mm5 = true,
                  .mm6 = true,
                  .mm7 = true,
                  .zmm0 = true,
                  .zmm1 = true,
                  .zmm2 = true,
                  .zmm3 = true,
                  .zmm4 = true,
                  .zmm5 = true,
                  .zmm6 = true,
                  .zmm7 = true,
                  .zmm8 = true,
                  .zmm9 = true,
                  .zmm10 = true,
                  .zmm11 = true,
                  .zmm12 = true,
                  .zmm13 = true,
                  .zmm14 = true,
                  .zmm15 = true,
                  .zmm16 = true,
                  .zmm17 = true,
                  .zmm18 = true,
                  .zmm19 = true,
                  .zmm20 = true,
                  .zmm21 = true,
                  .zmm22 = true,
                  .zmm23 = true,
                  .zmm24 = true,
                  .zmm25 = true,
                  .zmm26 = true,
                  .zmm27 = true,
                  .zmm28 = true,
                  .zmm29 = true,
                  .zmm30 = true,
                  .zmm31 = true,
                  .fpsr = true,
                  .fpcr = true,
                  .mxcsr = true,
                  .rflags = true,
                  .dirflag = true,
                  .memory = true,
                }),
            else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
        };
    }
};
