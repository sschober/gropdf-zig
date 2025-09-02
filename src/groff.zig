/// groff out language
pub const Out = enum {
    /// device control command
    x,
    /// new page
    p,
    /// select font
    f,
    s,
    /// TODO set vertical position absolute
    V,
    /// TODO set horizontal position absolute
    H,
    /// TODO set horizontal position relative
    h,
    m,
    D,
    /// type-set word
    t,
    /// inter-word whitespace
    w,
    /// type-set glyph/character
    C,
    /// TODO next line
    n,
};
