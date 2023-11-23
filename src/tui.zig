const std = @import("std");
const color = @import("color.zig");
const date = @import("date.zig");
const main = @import("main.zig");

const LocalDate = date.LocalDate;
const Rgb = color.Rgb;

const UBOX = "\u{2588}";
const UDASHLONG = "\u{2504}";
const UDOT = "\u{30FB}";
const ULINE = "\u{2501}";
const UMESH = "\u{2591}";

const default_margin: usize = 1;

fn startColor(w: anytype, rgb: Rgb) void {
    w.print("\x1b[38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }) catch unreachable;
}

fn endColor(w: anytype) void {
    w.writeAll("\x1b[0m") catch unreachable;
}

const Glyph = enum {
    box,
    mesh,
    dash,
    line,
    space,
};

fn drawGlyph(w: anytype, glyph: Glyph, rgb: ?Rgb) void {
    if (rgb) |c| {
        startColor(w, c);
    }
    const str = switch (glyph) {
        .box => UBOX,
        .mesh => UMESH,
        .dash => UDASHLONG,
        .line => ULINE,
        .space => " ",
    };
    w.writeAll(str) catch unreachable;
    w.writeAll(str) catch unreachable;
    if (rgb) |_| {
        endColor(w);
    }
}

fn drawGlyphs(w: anytype, glyph: Glyph, rgb: Rgb, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        drawGlyph(w, glyph, rgb);
    }
}

fn indent(w: anytype, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        w.writeByte(' ') catch unreachable;
    }
}

fn verticalSpace(w: anytype, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        w.writeByte('\n') catch unreachable;
    }
    indent(w, default_margin);
}

pub fn drawHeader(w: anytype, ctx: *const DrawContext) !void {
    var month: ?usize = null;
    var day = ctx.start;

    var day_buf = std.mem.zeroes([256]u8);
    var day_fba = std.io.fixedBufferStream(&day_buf);
    var dw = day_fba.writer();

    var weekday_buf = std.mem.zeroes([256]u8);
    var weekday_fba = std.io.fixedBufferStream(&weekday_buf);
    var wdw = weekday_fba.writer();

    indent(w, ctx.max_prelude_len + default_margin);
    while (day.compare(ctx.end) != .gt) : (day = day.next()) {
        if (month == null or day.month != month) {
            month = day.month;
            try w.print("{d:<4}", .{month.?});
        } else {
            try w.writeAll("    ");
        }
        try dw.print("{d:<4}", .{day.day});
        try wdw.print("{s:<4}", .{@tagName(date.getWeekdayFromEpoch(day.toEpoch()))});
    }

    try w.writeAll("\n");
    indent(w, ctx.max_prelude_len + default_margin);
    try w.writeAll(day_fba.getWritten());

    try w.writeAll("\n");
    indent(w, ctx.max_prelude_len + default_margin);
    try w.writeAll(weekday_fba.getWritten());
}

fn formatPrelude(index: usize, chain: *const main.Chain) []const u8 {
    return main.scratchPrint("({d}{s}) {s}", .{ index + 1, if (chain.isActive()) "" else "/s", chain.name[0..chain.name_len] });
}

fn drawChain(comptime kind: main.Kind, w: anytype, ctx: *DrawContext, chain: *const main.Chain, links: []const main.Link, index: usize) !void {
    if (ctx.max_prelude_len > 0) {
        const prelude = formatPrelude(index, chain);
        const padding = ctx.max_prelude_len - prelude.len;
        try w.writeAll(prelude);
        var i: usize = 0;
        while (i < padding) : (i += 1) {
            try w.writeByte(' ');
        }
    }

    var i: usize = 0;
    const items = while (i < links.len) : (i += 1) {
        if (links[i].toLocalDate().compare(ctx.start) != .lt)
            break links[i..];
    } else return;

    const week_info: struct { link_count: [date.max_weeks_per_year + 1]u8, index: usize } = if (kind == .weekly) blk: {
        const start_of_week = ctx.start.atStartOfWeek();
        var j: usize = 0;
        const items_full_week = while (j < links.len) : (j += 1) {
            if (links[j].toLocalDate().compare(start_of_week) != .lt)
                break links[j..];
        } else unreachable;

        var weeks = std.mem.zeroes([date.max_weeks_per_year + 1]u8);
        for (items_full_week) |item| {
            const week = date.getWeekNumberFromEpoch(item.localAtStartOfDay());
            weeks[week] += 1;
        }
        break :blk .{ .link_count = weeks, .index = j };
    } else undefined;

    var items_index: usize = 0;
    var day = ctx.start;
    var seen_so_far: usize = if (kind == .weekly) i - week_info.index else 0;
    while (day.compare(ctx.end) != .gt) {
        const end = items_index == items.len - 1;
        const link = items[items_index];
        if (day.compare(ctx.end) == .gt) break;
        const linked_on_day = link.toLocalDate().compare(day) == .eq;
        const next_day = day.next();
        defer day = next_day;

        const link_color = if (link.tags != 0)
            chain.tagColor(link.tags)
        else
            chain.color;
        switch (kind) {
            .daily => {
                const next = if (end) false else items[items_index + 1].toLocalDate().compare(next_day) == .eq;

                if (linked_on_day) {
                    drawGlyph(w, .box, link_color);
                    if (next) {
                        drawGlyph(w, .line, color.sand);
                    } else {
                        if (!end)
                            drawGlyph(w, .space, null);
                    }
                    items_index += 1;
                    if (items_index == items.len)
                        break;
                } else {
                    drawGlyph(w, .space, null);
                    drawGlyph(w, .space, null);
                }
            },
            .weekly => {
                const week = @as(u8, @intCast(date.getWeekNumberFromEpoch(day.toEpoch())));
                const next_week = (week + 1) % date.max_weeks_per_year;
                const prev_week = (week + date.max_weeks_per_year - 1) % date.max_weeks_per_year;

                const this_week_count = week_info.link_count[week];
                const this_week_linked = this_week_count >= chain.min_days;
                const next_week_linked = week_info.link_count[next_week] >= chain.min_days;
                const prev_week_linked = week_info.link_count[prev_week] >= chain.min_days;

                if (linked_on_day)
                    seen_so_far += 1;

                const should_draw_link = this_week_linked and
                    ((prev_week_linked and seen_so_far == 0) or
                    (seen_so_far > 0 and seen_so_far < this_week_count) or
                    (next_week_linked and seen_so_far >= this_week_count));

                if (linked_on_day) {
                    drawGlyph(w, .box, link_color);

                    if (should_draw_link) {
                        drawGlyph(w, .line, color.sand);
                    } else {
                        drawGlyph(w, .space, null);
                    }

                    items_index += 1;
                    if (items_index == items.len)
                        break;
                } else {
                    if (should_draw_link) {
                        drawGlyph(w, .line, color.sand);
                        drawGlyph(w, .line, color.sand);
                    } else {
                        drawGlyph(w, .space, null);
                        drawGlyph(w, .space, null);
                    }
                }
                if (date.getWeekdayFromEpoch(day.toEpoch()) == .sun) {
                    seen_so_far = 0;
                }
            },
        }
    }
}

const DrawContext = struct {
    start: LocalDate,
    end: LocalDate,
    row_offset: usize,
    max_prelude_len: usize,
};

pub fn drawChains(chains: []const *main.Chain, links: []const main.Link, start: LocalDate, end: LocalDate) !void {
    const sow = std.io.getStdOut().writer();
    var buffered_writer = std.io.bufferedWriter(sow);
    var w = buffered_writer.writer();
    var ctx: DrawContext = .{
        .row_offset = 0,
        .start = start,
        .end = end,
        .max_prelude_len = blk: {
            var max_prelude_len: usize = 0;
            for (chains, 0..) |chain, i| {
                // TODO: don't format this twice (once here and once on print)
                max_prelude_len = @max(max_prelude_len, formatPrelude(i, chain).len);
            }
            // +2 here to ensure same spacing between prelude and chains everywhere
            break :blk max_prelude_len + 2;
        },
    };

    w.writeByte('\n') catch unreachable;
    try drawHeader(w, &ctx);
    verticalSpace(w, 1);

    // TODO: better way of doing this
    for (chains, 0..) |chain, i| {
        var link_index: usize = 0;
        while (link_index < links.len and links[link_index].chain_id != chain.id) : (link_index += 1) {}
        const link_start = link_index;
        while (link_index < links.len) {
            const link = links[link_index];
            if (link.chain_id == chain.id) {
                link_index += 1;
            } else {
                break;
            }
        }
        const ls = links[link_start..link_index];

        switch (chain.kind) {
            inline else => |kind| try drawChain(kind, w, &ctx, chain, ls, i),
        }
        verticalSpace(w, 2);
    }
    w.writeByte('\n') catch unreachable;
    buffered_writer.flush() catch unreachable;
}

pub fn drawChainDetails(chain: *const main.Chain, links: []const main.Link, start: LocalDate, end: LocalDate) !void {
    const sow = std.io.getStdOut().writer();
    var buffered_writer = std.io.bufferedWriter(sow);
    var w = buffered_writer.writer();
    var ctx: DrawContext = .{
        .row_offset = 0,
        .start = start,
        .end = end,
        .max_prelude_len = 0,
    };

    w.writeByte('\n') catch unreachable;
    try drawHeader(w, &ctx);
    verticalSpace(w, 1);
    switch (chain.kind) {
        inline else => |kind| try drawChain(kind, w, &ctx, chain, links, 0),
    }
    verticalSpace(w, 2);

    const stats = main.computeStats(chain, links);
    writeText(w, "Details", "");
    writeText(w, "  Id:", main.scratchPrint("{d}", .{chain.id}));
    writeText(w, "  Name:", main.scratchPrint("{s}", .{chain.name[0..chain.name_len]}));
    writeText(w, "  Color:", main.scratchPrint("{s}", .{chain.color.toHex()}));
    writeText(w, "  Kind:", main.scratchPrint("{s}", .{@tagName(chain.kind)}));
    writeText(w, "  Created:", main.scratchPrint("{s}", .{LocalDate.fromEpoch(chain.created).asString()}));
    writeText(w, "  Stopped:", main.scratchPrint("{s}", .{if (chain.isActive()) "false" else &LocalDate.fromEpoch(chain.stopped).asString()}));
    writeText(w, "  Fulfillment:", main.scratchPrint("{s}", .{std.mem.sliceTo(&stats.fulfillment, 0)}));
    writeText(w, "  Longest streak:", main.scratchPrint("{d}", .{stats.longest_streak}));
    writeText(w, "  Times broken:", main.scratchPrint("{d}", .{stats.times_broken}));
    writeText(w, "  Longest gap:", main.scratchPrint("{d}", .{stats.longest_gap}));
    verticalSpace(w, 1);

    const first_timestamp = if (links.len > 0) &LocalDate.fromEpoch(links[0].local()).asString() else "N/A";
    const last_timestamp = if (links.len > 0) &LocalDate.fromEpoch(links[links.len - 1].local()).asString() else "N/A";
    writeText(w, "Links", "");
    writeText(w, "  Number of links:", main.scratchPrint("{d}", .{links.len}));
    writeText(w, "  First timestamp:", main.scratchPrint("{s}", .{first_timestamp}));
    writeText(w, "  Last timestamp:", main.scratchPrint("{s}", .{last_timestamp}));

    buffered_writer.flush() catch unreachable;
}

fn writeText(w: anytype, left: []const u8, right: []const u8) void {
    const cols = 40;
    const padding = cols - left.len - right.len;

    w.writeAll(left) catch unreachable;
    indent(w, padding);
    w.writeAll(right) catch unreachable;
    w.writeByte('\n') catch unreachable;
    indent(w, default_margin);
}

pub fn drawLinkDetails(chain: *const main.Chain, links: []const main.Link, link_index: usize) !void {
    const sow = std.io.getStdOut().writer();
    var buffered_writer = std.io.bufferedWriter(sow);
    const w = buffered_writer.writer();
    const cols: usize = 40;
    const mid = cols / 2;
    const in = mid - 3;
    const link = links[link_index];
    const link_color = if (link.tags != 0)
        chain.tagColor(link.tags)
    else
        chain.color;

    verticalSpace(w, default_margin);
    indent(w, in);
    drawGlyphs(w, .box, link_color, 3);
    verticalSpace(w, 1);

    indent(w, in - 6);

    // TODO: check if the left link exists (it might be unlinked)
    const has_left_link = link_index > 0;
    if (has_left_link) {
        drawGlyph(w, .dash, color.sand);
        drawGlyph(w, .mesh, chain.color);
        drawGlyph(w, .line, color.sand);
    } else {
        indent(w, 6);
    }

    drawGlyphs(w, .box, link_color, 3);

    // TODO: check if the right link exists (it might be unlinked)
    const has_right_link = link_index < links.len - 1;
    if (has_right_link) {
        drawGlyph(w, .line, color.sand);
        drawGlyph(w, .mesh, chain.color);
        drawGlyph(w, .dash, color.sand);
    }

    verticalSpace(w, 1);

    indent(w, in);
    drawGlyphs(w, .box, link_color, 3);

    verticalSpace(w, 2);

    writeText(w, "Chain ID:", main.scratchPrint("{d}", .{link.chain_id}));
    const created_str = date.LocalDateTime.fromEpoch(link.local()).asString();
    writeText(w, "Created:", main.scratchPrint("{s}", .{created_str}));

    const tags_str = if (link.tags == 0) blk: {
        break :blk main.scratchPrint("[]", .{});
    } else blk: {
        var buf = std.mem.zeroes([main.max_tags * main.tag_name_max_len]u8);
        var fba = std.io.fixedBufferStream(&buf);
        const bw = fba.writer();
        const tags = chain.getTags();
        var link_tags = link.tags;
        const n_tags = @popCount(link_tags);
        for (tags, 1..) |tag, i| {
            const has_tag = link_tags & 1 == 1;
            if (has_tag) {
                try bw.writeAll(tag.getName());
                if (i != n_tags)
                    try bw.writeAll(",");
            }
            link_tags >>= 1;
        }
        break :blk main.scratchPrint("{s}", .{fba.getWritten()});
    };
    writeText(w, "Tags: ", tags_str);

    buffered_writer.flush() catch unreachable;
}
