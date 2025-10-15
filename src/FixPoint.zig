const std = @import("std");

const Self = @This();

/// 3 digit exact point decimal - why? because, I think, we do not need
/// floating points precision behavior - we only need three digits and these
/// I want to be exact.
integer: usize = 0,
fraction: usize = 0,
/// custom format function to make this struct easily printable
pub fn format(
    self: @This(),
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writer.print("{d}.{d}", .{ self.integer, self.fraction });
}
pub fn from(n: usize, d: usize) Self {
    var result = Self{};
    result.integer = n / d;
    var rest = n % d;
    for (0..3) |_| {
        // we also scale the prvious rest
        const scaled_rest = 10 * rest;
        // update rest with what remains now
        rest = scaled_rest % d;
        if (scaled_rest == 0 and rest == 0) {
            // we can skip trailing `0`s: 7.5 == 7.50 === 7.500
            break;
        }
        // we `shift` previous result by one digti to the left
        result.fraction *= 10;
        // and add the new digit
        result.fraction += scaled_rest / d;
    }
    return result;
}
pub fn subtractFrom(self: @This(), n: usize) Self {
    var result = Self{};
    result.integer = n - self.integer;
    result.fraction = 0;
    if (self.fraction > 0) {
        result.fraction = 1000 - self.fraction;
        result.integer -= 1;
    }
    return result;
}
const expect = std.testing.expect;
test "FixPoint" {
    const fp = Self.from(15, 2);
    std.debug.print("fp {d}.{d}\n", .{ fp.integer, fp.fraction });
    try expect(fp.integer == 7);
    try expect(fp.fraction == 5);
    const fp1 = Self.from(10, 3);
    std.debug.print("fp {d}.{d}\n", .{ fp1.integer, fp1.fraction });
    try expect(fp1.integer == 3);
    try expect(fp1.fraction == 333);
}
