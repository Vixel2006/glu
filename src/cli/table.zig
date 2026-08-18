const std = @import("std");
const assert = std.debug.assert;
const constants = @import("../constants.zig");

/// One column of a `Table`: its header and horizontal alignment.
pub const Column = struct {
    header: []const u8,
    right: bool = false,
};

/// An aligned column table over fixed-size buffers.
///
/// Rows are copied into fixed storage so each column can be sized to its
/// widest cell, then `render` writes a header row, a dashed separator, and
/// the data rows to a writer. No dynamic allocation.
pub const Table = struct {
    columns: []const Column,
    widths: [constants.MAX_COLUMNS]usize,
    row_count: usize = 0,
    cells: [constants.MAX_ROWS][constants.MAX_COLUMNS][constants.MAX_CELL]u8,
    cell_len: [constants.MAX_ROWS][constants.MAX_COLUMNS]usize,

    pub fn init(columns: []const Column) Table {
        assert(columns.len <= constants.MAX_COLUMNS);
        var widths: [constants.MAX_COLUMNS]usize = undefined;
        for (columns, 0..) |col, i| widths[i] = col.header.len;
        return .{
            .columns = columns,
            .widths = widths,
            .cells = undefined,
            .cell_len = undefined,
        };
    }

    /// Append a row; `cells.len` must equal the number of columns.
    pub fn row(self: *Table, cells: []const []const u8) void {
        assert(cells.len == self.columns.len);
        assert(self.row_count < constants.MAX_ROWS);
        for (cells, 0..) |cell, i| {
            assert(cell.len <= constants.MAX_CELL);
            self.cell_len[self.row_count][i] = cell.len;
            @memcpy(self.cells[self.row_count][i][0..cell.len], cell);
            self.widths[i] = @max(self.widths[i], cell.len);
        }
        self.row_count += 1;
    }

    /// Write the table to `w`.
    pub fn render(self: *const Table, w: *std.Io.Writer) !void {
        var headers: [constants.MAX_COLUMNS][]const u8 = undefined;
        for (self.columns, 0..) |col, i| headers[i] = col.header;
        try print_row(w, headers[0..self.columns.len], self.columns, &self.widths);
        try w.writeByte('\n');

        for (self.columns, 0..) |_, i| {
            if (i > 0) try w.writeByte(' ');
            try w.splatByteAll('-', self.widths[i]);
        }
        try w.writeByte('\n');

        for (0..self.row_count) |r| {
            var slices: [constants.MAX_COLUMNS][]const u8 = undefined;
            for (0..self.columns.len) |i| {
                slices[i] = self.cells[r][i][0..self.cell_len[r][i]];
            }
            try print_row(w, slices[0..self.columns.len], self.columns, &self.widths);
            try w.writeByte('\n');
        }
    }
};

fn print_row(w: *std.Io.Writer, cells: []const []const u8, columns: []const Column, widths: []const usize) !void {
    for (cells, 0..) |cell, i| {
        if (i > 0) try w.writeByte(' ');
        const pad = widths[i] - cell.len;
        if (columns[i].right) {
            try w.splatByteAll(' ', pad);
            try w.writeAll(cell);
        } else {
            try w.writeAll(cell);
            try w.splatByteAll(' ', pad);
        }
    }
}

test "render aligns left and right columns" {
    var t = Table.init(&.{
        .{ .header = "Name" },
        .{ .header = "PID", .right = true },
    });
    t.row(&.{ "sensor", "1234" });
    t.row(&.{ "lidar_long", "7" });

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try t.render(&w);

    const out = std.Io.Writer.buffered(&w);
    try std.testing.expectEqualStrings(
        "Name        PID\n" ++
            "---------- ----\n" ++
            "sensor     1234\n" ++
            "lidar_long    7\n",
        out,
    );
}

test "render empty table draws header and separator" {
    var t = Table.init(&.{.{ .header = "A" }});

    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try t.render(&w);

    try std.testing.expectEqualStrings("A\n-\n", std.Io.Writer.buffered(&w));
}
