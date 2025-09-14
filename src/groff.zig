/// groff out language
pub const Out = enum {
    /// device control command
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
    m,
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

pub const XSubCommand = enum {
    T,
    res,
    init,
    font,
    X,
    trailer,
    stop,
};
