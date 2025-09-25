const std = @import("std");

const String = []const u8;
/// groff out language elements - all single characters, some take
pub const Out = enum {
    /// device control command - see XSubCommand
    x,
    /// new page
    p,
    /// select font
    f,
    /// set font size
    s,
    /// set vertical position absolute
    V,
    /// set horizontal position absolute
    H,
    /// set horizontal position relative
    h,
    /// set vertical position relative
    v,
    /// set stroke color
    m,
    /// graphic copmmands
    D,
    /// type-set word
    t,
    /// inter-word whitespace
    w,
    /// type-set glyph/character
    C,
    /// next line
    n,
};

/// sub commands for X command
pub const XSubCommand = enum {
    /// typesetter control command - choses which type of output should be
    /// produced (ps, pdf, or latin1) - we only support `pdf` obviously
    T,
    res,
    init,
    font,
    /// escape control - side channel to us from groff, used to communicate
    /// meta data like papersize
    X,
    trailer,
    stop,
};

/// type for z-position of grout
pub const zPosition = struct {
    v: usize = 0,
    pub fn fromString(input: String) !zPosition {
        var result = zPosition{};
        if (input.len > 3 and input[input.len - 1] == 'z') {
            result.v = try std.fmt.parseUnsigned(usize, input[0 .. input.len - 1], 10);
        } else {
            result.v = try std.fmt.parseUnsigned(usize, input[0..], 10);
        }
        return result;
    }
};
