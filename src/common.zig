const std = @import("std");
pub const String = []const u8;
pub const U8SplitIterator = std.mem.SplitIterator(u8, .scalar);

/// Parsed data from a Type1 PFA font file, ready to embed in a PDF.
pub const Type1FontData = struct {
    /// Raw bytes of the complete font file
    data: []const u8,
    /// Byte count of the clear-text portion (up to and including the newline after "currentfile eexec")
    length1: usize,
    /// Byte count of the encrypted portion
    length2: usize,
    /// Byte count of the fixed-content trailer (zeros + cleartomark); 0 if absent
    length3: usize,
    /// PostScript internal font name, e.g. "NimbusRoman-Regular"
    font_name: []const u8,
    /// Font bounding box [llx lly urx ury] in 1/1000-unit coordinates
    font_bbox: [4]i64,
    /// Italic angle in degrees (0 for upright)
    italic_angle: i64,
    /// PDF font flags (bit 1=FixedPitch, bit 2=Serif, bit 6=NonSymbolic, bit 7=Italic)
    flags: u32,
};
