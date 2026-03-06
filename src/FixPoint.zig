const std = @import("std");

const String = []const u8;
const Self = @This();

/// 3 digit exact point decimal - why? because, I think, we do not need
/// floating points precision behavior - we only need three digits and these
/// I want to be exact.
integer: usize = 0,
fraction: usize = 0,
/// custom format function to make this struct easily printable
pub fn format(
    self: Self,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writer.print("{d}.{d:03}", .{ self.integer, self.fraction });
}
/// convenience constructor the tries to parse args as usizes
pub fn from_strings(n_str: String, d_str: String) !Self {
    const n = try std.fmt.parseUnsigned(usize, n_str, 10);
    const d = try std.fmt.parseUnsigned(usize, d_str, 10);
    return Self.from(n, d);
}
pub fn from_n_string(n_str: String, d: usize) !Self {
    const n = try std.fmt.parseUnsigned(usize, n_str, 10);
    return Self.from(n, d);
}
/// create a new fix point fraction from the given nominator and denominator
pub fn from(n: usize, d: usize) Self {
    var result = Self{};
    result.integer = n / d;
    var rest = n % d;
    for (0..3) |_| {
        // we also scale the prvious rest
        const scaled_rest = 10 * rest;
        // update rest with what remains now
        rest = scaled_rest % d;
        // we `shift` previous result by one digti to the left
        result.fraction *= 10;
        // and add the new digit
        result.fraction += scaled_rest / d;
    }
    return result;
}

/// subtract self from the given FixPoint parameter and return a new object.
/// returns zero if self > n (underflow guard).
pub fn subtractFrom(self: Self, n: usize) Self {
    // Guard against underflow: if self > n, clamp to zero
    if (self.integer > n) return Self{};
    if (self.integer == n and self.fraction > 0) return Self{};
    var result = Self{};
    result.integer = n - self.integer;
    result.fraction = 0;
    if (self.fraction > 0) {
        result.fraction = 1000 - self.fraction;
        result.integer -= 1;
    }
    return result;
}

/// subtract o from self, returning a new object.
/// returns zero if o > self (underflow guard).
pub fn sub(self: Self, o: Self) Self {
    // Guard against underflow: if o > self, clamp to zero
    if (o.integer > self.integer) return Self{};
    var result = Self{};
    result.integer = self.integer - o.integer;
    if (o.fraction > self.fraction) {
        if (result.integer == 0) return Self{};
        result.fraction = 1000 + self.fraction - o.fraction;
        result.integer -= 1;
    } else {
        result.fraction = self.fraction - o.fraction;
    }
    return result;
}

/// add self to the given FixPoint parameter and return a new object
pub fn addTo(self: Self, o: Self) Self {
    var result = self;
    result.integer += o.integer;
    result.fraction += o.fraction;
    if (result.fraction >= 1000) {
        result.integer += 1;
        result.fraction -= 1000;
    }
    return result;
}

/// multiply self with the other operand and return a new object
pub fn mult(self: Self, o: Self) Self {
    var result = Self{};
    result.integer = self.integer * o.integer;
    result.fraction = self.integer * o.fraction;
    result.fraction += o.integer * self.fraction;
    result.fraction += (self.fraction * o.fraction) / 1000;
    if (result.fraction >= 1000) {
        result.integer += result.fraction / 1000;
        result.fraction = result.fraction % 1000;
    }
    return result;
}

const expect = std.testing.expect;

test "Construction" {
    var fp = Self.from(15, 2);
    std.debug.print("15/2 = {f}\n", .{fp});
    try expect(fp.integer == 7 and fp.fraction == 500);

    fp = Self.from(10, 3);
    std.debug.print("10/3 = {f}\n", .{fp});
    try expect(fp.integer == 3 and fp.fraction == 333);

    fp = Self.from(1, 10);
    std.debug.print("1/10 = {f}\n", .{fp});
    try expect(fp.integer == 0 and fp.fraction == 100);

    fp = Self.from(1, 100);
    std.debug.print("1/100 = {f}\n", .{fp});
    try expect(fp.integer == 0 and fp.fraction == 10);

    fp = Self.from(1, 1000);
    std.debug.print("1/1000 = {f}\n", .{fp});
    try expect(fp.integer == 0 and fp.fraction == 1);
}

test "Addition" {
    var res = Self.from(1, 1).addTo(Self.from(1, 1));
    std.debug.print("1.0 + 1.0 = {f}\n", .{res});
    try expect(res.integer == 2 and res.fraction == 0);

    res = res.addTo(Self.from(1, 2));
    std.debug.print("2.0 + 0.500 = {f}\n", .{res});
    try expect(res.integer == 2 and res.fraction == 500);

    res = res.addTo(Self.from(1, 2));
    std.debug.print("2.500 + 0.500 = {f}\n", .{res});
    try expect(res.integer == 3 and res.fraction == 0);
}

test "Multiplication" {
    var res = Self.from(1, 1).mult(Self.from(1, 2));
    std.debug.print("1.0 * 0.5 = {f}\n", .{res});
    try expect(res.integer == 0 and res.fraction == 500);

    res = Self.from(3, 2).mult(Self.from(1, 2));
    std.debug.print("1.5 * 0.5 = {f}\n", .{res});
    try expect(res.integer == 0 and res.fraction == 750);

    res = Self.from(1, 10).mult(Self.from(1, 10));
    std.debug.print("0.1 * 0.1 = {f}\n", .{res});
    try expect(res.integer == 0 and res.fraction == 10);

    const zero_dot_nineninenine = Self{ .integer = 0, .fraction = 999 };
    res = zero_dot_nineninenine.mult(zero_dot_nineninenine);
    std.debug.print("0.999 * 0.999 = {f}\n", .{res});

    // cross-term: 1.5 * 2.0 = 3.0  (requires o.integer * self.fraction)
    res = Self.from(3, 2).mult(Self.from(2, 1));
    std.debug.print("1.5 * 2.0 = {f}\n", .{res});
    try expect(res.integer == 3 and res.fraction == 0);
}

test "Substraction" {
    const a = Self.from(1, 1);
    const b = Self.from(1, 10);
    std.debug.print("{f} - {f} = ", .{ a, b });
    const res = a.sub(b);
    std.debug.print("{f}\n", .{res});
    try expect(res.integer == 0 and res.fraction == 900);

    // borrow with non-zero self.fraction: 1.500 - 0.700 = 0.800
    const c = Self.from(3, 2);
    const d = Self.from(7, 10);
    std.debug.print("{f} - {f} = ", .{ c, d });
    const res2 = c.sub(d);
    std.debug.print("{f}\n", .{res2});
    try expect(res2.integer == 0 and res2.fraction == 800);
}
