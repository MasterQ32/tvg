const std = @import("std");

const tvg = @import("tvg.zig");

fn JoinLength(comptime T: type) comptime_int {
    const info = @typeInfo(T);

    var len: usize = 0;
    inline for (info.Struct.fields) |fld| {
        len += @typeInfo(fld.field_type).Array.len;
    }
    return len;
}

fn join(list: anytype) [JoinLength(@TypeOf(list))]u8 {
    const T = @TypeOf(list);
    const info = @typeInfo(T);

    var array = [1]u8{0x55} ** JoinLength(T);

    comptime var offset: usize = 0;
    inline for (info.Struct.fields) |fld, i| {
        const len = @typeInfo(fld.field_type).Array.len;

        std.mem.copy(u8, array[offset .. offset + len], &list[i]);
        offset += len;
    }

    return array;
}

fn writeU16(buf: *[2]u8, value: u16) void {
    buf[0] = @truncate(u8, value >> 0);
    buf[1] = @truncate(u8, value >> 8);
}

pub const Gradient = struct {
    point_0: tvg.Point,
    point_1: tvg.Point,
    color_0: u7,
    color_1: u7,
};

pub const StyleSpec = enum(u2) {
    flat = 0,
    linear = 1,
    radial = 2,
};

fn StyleType(comptime spec: StyleSpec) type {
    return switch (spec) {
        .flat => u7,
        .linear => Gradient,
        .radial => Gradient,
    };
}

fn uint16(v: u16) [2]u8 {
    var buf: [2]u8 = undefined;
    writeU16(&buf, v);
    return buf;
}

pub const Range = enum {
    /// unit takes only 8 bit
    reduced,
    /// unit uses 16 bit,
    default,
    // unit uses 32 bit,
    //enhanced,
};

// TODO: Add 8 or 16 bit precision option
pub fn create(comptime scale: tvg.Scale, comptime range: Range) type {
    const sUNIT = switch (range) {
        .reduced => 1,
        .default => 2,
    };
    const sPOINT = 2 * sUNIT;
    const sGRADIENT = 2 * sPOINT + 2;

    return struct {
        pub fn unit(value: f32) [sUNIT]u8 {
            const val = @bitCast(u16, scale.map(value).raw());
            switch (range) {
                .reduced => {
                    if (val >= 0x100) unreachable;
                    return [1]u8{@truncate(u8, val)};
                },
                .default => {
                    var buf: [2]u8 = undefined;
                    writeU16(&buf, val);
                    return buf;
                },
            }
        }

        pub fn byte(val: u8) [1]u8 {
            return [1]u8{val};
        }

        fn command(cmd: tvg.format.Command) [1]u8 {
            return [1]u8{@enumToInt(cmd)};
        }

        pub fn uint(num: u7) [1]u8 {
            return byte(num);
        }

        pub fn point(x: f32, y: f32) [sPOINT]u8 {
            return join(.{ unit(x), unit(y) });
        }

        pub fn header(width: u16, height: u16) [4 + 2 * sUNIT]u8 {
            return join(.{
                tvg.magic_number,
                byte(tvg.current_version),
                byte(@enumToInt(scale) | (if (range == .reduced) @as(u8, 0x20) else 0)),
                if (range == .default) uint16(width) else byte(if (width == 256) @as(u8, 0) else @intCast(u8, width)),
                if (range == .default) uint16(height) else byte(if (height == 256) @as(u8, 0) else @intCast(u8, height)),
            });
        }

        pub fn colorTable(comptime colors: []const tvg.Color) [2 + 4 * colors.len]u8 {
            var buf: [2 + 4 * colors.len]u8 = undefined;
            std.mem.set(u8, &buf, 0x55);
            writeU16(buf[0..2], @intCast(u16, colors.len));
            for (colors) |c, i| {
                buf[2 + 4 * i + 0] = c.r;
                buf[2 + 4 * i + 1] = c.g;
                buf[2 + 4 * i + 2] = c.b;
                buf[2 + 4 * i + 3] = c.a;
            }
            return buf;
        }

        fn countAndStyle(items: usize, style_type: StyleSpec) [1]u8 {
            std.debug.assert(items > 0);
            std.debug.assert(items <= 64);

            const style = @enumToInt(style_type);

            return .{(@as(u8, style) << 6) | if (items == 64) @as(u6, 0) else @truncate(u6, items)};
        }

        fn gradient(grad: Gradient) [sGRADIENT]u8 {
            return join(.{
                point(grad.point_0.x, grad.point_0.y),
                point(grad.point_1.x, grad.point_1.y),
                byte(grad.color_0),
                byte(grad.color_1),
            });
        }

        fn byteSize(self: StyleSpec) usize {
            return switch (self) {
                .flat => 1,
                .linear, .radial => sGRADIENT,
            };
        }

        fn encodeStyle(comptime style_type: StyleSpec, value: StyleType(style_type)) [byteSize(style_type)]u8 {
            return switch (style_type) {
                .flat => byte(value),
                .linear, .radial => gradient(value),
            };
        }

        pub fn fillPolygon(num_items: usize, comptime style_type: StyleSpec, style: StyleType(style_type)) [2 + byteSize(style_type)]u8 {
            return join(.{ command(.fill_polygon), countAndStyle(num_items, style_type), encodeStyle(style_type, style) });
        }

        pub fn fillRectangles(num_items: usize, comptime style_type: StyleSpec, style: StyleType(style_type)) [2 + byteSize(style_type)]u8 {
            return join(.{ command(.fill_rectangles), countAndStyle(num_items, style_type), encodeStyle(style_type, style) });
        }

        pub fn fillPath(segment_count: usize, comptime style_type: StyleSpec, style: StyleType(style_type)) [2 + byteSize(style_type)]u8 {
            return join(.{ command(.fill_path), countAndStyle(segment_count, style_type), encodeStyle(style_type, style) });
        }

        pub fn drawLines(num_items: usize, line_width: f32, comptime style_type: StyleSpec, style: StyleType(style_type)) [4 + byteSize(style_type)]u8 {
            return join(.{ command(.draw_lines), countAndStyle(num_items, style_type), encodeStyle(style_type, style), unit(line_width) });
        }

        pub fn drawLineLoop(num_items: usize, line_width: f32, comptime style_type: StyleSpec, style: StyleType(style_type)) [4 + byteSize(style_type)]u8 {
            return join(.{ command(.draw_line_loop), countAndStyle(num_items - 1, style_type), encodeStyle(style_type, style), unit(line_width) });
        }

        pub fn drawLineStrip(num_items: usize, line_width: f32, comptime style_type: StyleSpec, style: StyleType(style_type)) [4 + byteSize(style_type)]u8 {
            return join(.{ command(.draw_line_strip), countAndStyle(num_items - 1, style_type), encodeStyle(style_type, style), unit(line_width) });
        }

        pub fn drawPath(segment_count: usize, line_width: f32, comptime style_type: StyleSpec, style: StyleType(style_type)) [4 + byteSize(style_type)]u8 {
            return join(.{ command(.draw_line_path), countAndStyle(segment_count, style_type), encodeStyle(style_type, style), unit(line_width) });
        }

        pub fn outlineFillPolygon(
            num_items: usize,
            line_width: f32,
            comptime fill_style_type: StyleSpec,
            fill_style: StyleType(fill_style_type),
            comptime line_style_type: StyleSpec,
            line_style: StyleType(line_style_type),
        ) [5 + byteSize(fill_style_type) + byteSize(line_style_type)]u8 {
            return join(.{ command(.outline_fill_polygon), countAndStyle(num_items, fill_style_type), byte(@enumToInt(line_style_type)), encodeStyle(line_style_type, line_style), encodeStyle(fill_style_type, fill_style), unit(line_width) });
        }

        pub fn outlineFillRectangles(
            num_items: usize,
            line_width: f32,
            comptime fill_style_type: StyleSpec,
            fill_style: StyleType(fill_style_type),
            comptime line_style_type: StyleSpec,
            line_style: StyleType(line_style_type),
        ) [5 + byteSize(fill_style_type) + byteSize(line_style_type)]u8 {
            return join(.{ command(.outline_fill_rectangles), countAndStyle(num_items, fill_style_type), byte(@enumToInt(line_style_type)), encodeStyle(line_style_type, line_style), encodeStyle(fill_style_type, fill_style), unit(line_width) });
        }

        pub fn outlineFillPath(
            segment_count: usize,
            line_width: f32,
            comptime fill_style_type: StyleSpec,
            fill_style: StyleType(fill_style_type),
            comptime line_style_type: StyleSpec,
            line_style: StyleType(line_style_type),
        ) [5 + byteSize(fill_style_type) + byteSize(line_style_type)]u8 {
            return join(.{ command(.outline_fill_path), countAndStyle(segment_count, fill_style_type), byte(@enumToInt(line_style_type)), encodeStyle(line_style_type, line_style), encodeStyle(fill_style_type, fill_style), unit(line_width) });
        }

        pub fn rectangle(x: f32, y: f32, w: f32, h: f32) [4 * sUNIT]u8 {
            return join(.{ unit(x), unit(y), unit(w), unit(h) });
        }

        pub const path = struct {
            pub fn line(x: f32, y: f32) [1 + sPOINT]u8 {
                return join(.{ byte(0), point(x, y) });
            }

            pub fn horiz(x: f32) [1 + sUNIT]u8 {
                return join(.{ byte(1), unit(x) });
            }

            pub fn vert(y: f32) [1 + sUNIT]u8 {
                return join(.{ byte(2), unit(y) });
            }

            pub fn bezier(c0x: f32, c0y: f32, c1x: f32, c1y: f32, p1x: f32, p1y: f32) [1 + 3 * sPOINT]u8 {
                return join(.{ byte(3), point(c0x, c0y), point(c1x, c1y), point(p1x, p1y) });
            }

            pub fn arc_circle(radius: f32, large_arc: bool, sweep: bool, p1x: f32, p1y: f32) [2 + sUNIT + sPOINT]u8 {
                const flag: u8 = (if (large_arc) @as(u8, 1) else 0) | (if (sweep) @as(u8, 2) else 0);
                return join(.{ byte(4), byte(flag), unit(radius), point(p1x, p1y) });
            }

            pub fn arc_ellipse(radius_x: f32, radius_y: f32, rotation: f32, large_arc: bool, sweep: bool, p1x: f32, p1y: f32) [2 + 3 * sUNIT + sPOINT]u8 {
                const flag: u8 = (if (large_arc) @as(u8, 1) else 0) | (if (sweep) @as(u8, 2) else 0);
                return join(.{ byte(5), byte(flag), unit(radius_x), unit(radius_y), unit(rotation), point(p1x, p1y) });
            }

            pub fn close() [1]u8 {
                return byte(6);
            }
        };

        pub const end_of_document = [1]u8{0x00};
    };
}

const test_builder = create(.@"1/256", .default);

test "join" {
    std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 1, 2, 3, 4, 5, 6, 7 },
        &join(.{ [_]u8{ 1, 2 }, [_]u8{ 3, 4, 5, 6 }, [_]u8{7} }),
    );
}

test "Builder.unit" {
    std.testing.expectEqualSlices(u8, &[_]u8{ 0, 1 }, &create(.@"1/256", .default).unit(1));
    std.testing.expectEqualSlices(u8, &[_]u8{ 0, 1 }, &create(.@"1/16", .default).unit(16));
    std.testing.expectEqualSlices(u8, &[_]u8{ 0, 2 }, &create(.@"1/16", .default).unit(32));
    std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0 }, &create(.@"1/1", .default).unit(1));
}

test "Builder.byte" {
    std.testing.expectEqual([_]u8{1}, test_builder.byte(1));
    std.testing.expectEqual([_]u8{4}, test_builder.byte(4));
    std.testing.expectEqual([_]u8{255}, test_builder.byte(255));
}
