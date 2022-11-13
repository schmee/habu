const std = @import("std");

pub const sand = Rgb{ .r = 222, .g = 211, .b = 195 };
pub const white = Rgb{ .r = 255, .g = 255, .b = 255 };

pub const Rgb = extern struct {
    r: u8,
    g: u8,
    b: u8,

    const Self = @This();

    pub fn toHex(self: Self) [7]u8 {
        var buf: [7]u8 = undefined;
        buf[0] = '#';
        _ = std.fmt.bufPrint(buf[1..], "{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b }) catch unreachable;
        return buf;
    }

    pub fn fromHex(str: []const u8) !Rgb {
        if (str.len != 6) return error.InvalidLength;
        return .{
            .r = try std.fmt.parseInt(u8, str[0..2], 16),
            .g = try std.fmt.parseInt(u8, str[2..4], 16),
            .b = try std.fmt.parseInt(u8, str[4..6], 16),
        };
    }
};

pub const colors = blk: {
    const hex_codes = [_]*const[6]u8{
        "7e7af5", // 1
        "ec3dc0", // 3
        "c67533", // 5
        "509a28", // 7
        "289988", // 9
        "bb5df4", // 2
        "f34b62", // 4
        "898f25", // 6
        "299d46", // 8
        "378ed5", // 10
    };
    var cs: [hex_codes.len]Rgb = undefined;
    for (hex_codes, &cs) |s, *c| {
        c.* = Rgb.fromHex(s) catch unreachable;
    }
    break :blk cs;
};


// Generated by https://huey.design/
// Starting color: 483FF3, Hue families: 12, Tints & Shades: 6
// $blue-0: #d3d2fb;
// $blue-1: #a9a7f8;
// $blue-2: #7e7af5;
// $blue-3: #5149f3;
// $blue-4: #332dae;
// $blue-5: #1d1960;
// $purple-0: #e5cdfa;
// $purple-1: #cf99f7;
// $purple-2: #bb5df4;
// $purple-3: #9534c9;
// $purple-4: #642387;
// $purple-5: #37134b;
// $fuschia-0: #fac7e9;
// $fuschia-1: #f68ad5;
// $fuschia-2: #ec3dc0;
// $fuschia-3: #af2d8f;
// $fuschia-4: #761e60;
// $fuschia-5: #421136;
// $amaranth-0: #facace;
// $amaranth-1: #f6929c;
// $amaranth-2: #f34b62;
// $amaranth-3: #ba3045;
// $amaranth-4: #7d202e;
// $amaranth-5: #45121a;
// $orange-0: #f9cdb7;
// $orange-1: #f49957;
// $orange-2: #c67533;
// $orange-3: #925626;
// $orange-4: #623a19;
// $orange-5: #351f0e;
// $yellow-0: #d6de3a;
// $yellow-1: #afb62f;
// $yellow-2: #898f25;
// $yellow-3: #666a1b;
// $yellow-4: #454712;
// $yellow-5: #26280a;
// $pistachio-0: #7cf03e;
// $pistachio-1: #66c433;
// $pistachio-2: #509a28;
// $pistachio-3: #3b721e;
// $pistachio-4: #274c14;
// $pistachio-5: #162a0b;
// $malachite_green-0: #4df373;
// $malachite_green-1: #34c859;
// $malachite_green-2: #299d46;
// $malachite_green-3: #1e7433;
// $malachite_green-4: #144e23;
// $malachite_green-5: #0b2b13;
// $opal-0: #3eeed4;
// $opal-1: #32c3ad;
// $opal-2: #289988;
// $opal-3: #1d7165;
// $opal-4: #144c44;
// $opal-5: #0b2a25;
// $azure-0: #bfd8f9;
// $azure-1: #73b3f5;
// $azure-2: #378ed5;
// $azure-3: #29699d;
// $azure-4: #1b4669;
// $azure-5: #0f263a;
