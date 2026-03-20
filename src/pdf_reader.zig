//! Minimal PDF page embedder for gropdf-zig.
//! Reads a single-page PDF (as produced by groff's pdfpic/Ghostscript) and
//! embeds its first page as a Form XObject in the output document.
//! Supports traditional (non-compressed) and cross-reference stream xref tables.
const std = @import("std");
const pdf = @import("pdf.zig");
const log = @import("log.zig");
const zlib = @cImport(@cInclude("zlib.h"));

const Allocator = std.mem.Allocator;

// --- minimal token helpers ---

fn ws(d: []const u8, i: usize) usize {
    var p = i;
    while (p < d.len and (d[p] == ' ' or d[p] == '\t' or d[p] == '\r' or d[p] == '\n')) p += 1;
    return p;
}

fn parseUint(d: []const u8, pos: usize) ?struct { v: usize, end: usize } {
    const i = ws(d, pos);
    if (i >= d.len or d[i] < '0' or d[i] > '9') return null;
    var j = i;
    while (j < d.len and d[j] >= '0' and d[j] <= '9') j += 1;
    const v = std.fmt.parseUnsigned(usize, d[i..j], 10) catch return null;
    return .{ .v = v, .end = j };
}

fn parseSignedFloat(d: []const u8, pos: usize) ?struct { v: f64, end: usize } {
    var i = ws(d, pos);
    if (i >= d.len) return null;
    const start = i;
    if (d[i] == '-') i += 1;
    while (i < d.len and (d[i] >= '0' and d[i] <= '9' or d[i] == '.')) i += 1;
    if (i == start) return null;
    const v = std.fmt.parseFloat(f64, d[start..i]) catch return null;
    return .{ .v = v, .end = i };
}

/// Find first "N G R" indirect reference for /Key in dict bytes, return obj_num N.
fn dictRef(dict: []const u8, key: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, dict, from, key)) |ki| {
        const ak = ki + key.len;
        if (ak >= dict.len) break;
        if (dict[ak] != ' ' and dict[ak] != '\t' and dict[ak] != '\r' and dict[ak] != '\n') {
            from = ki + 1;
            continue;
        }
        const r1 = parseUint(dict, ak) orelse { from = ki + 1; continue; };
        const r2 = parseUint(dict, r1.end) orelse { from = ki + 1; continue; };
        const after = ws(dict, r2.end);
        if (after < dict.len and dict[after] == 'R') return r1.v;
        from = ki + 1;
    }
    return null;
}

/// Get first "N G R" from a /Key [N G R ...] array entry.
fn dictFirstArrayRef(dict: []const u8, key: []const u8) ?usize {
    const ki = std.mem.indexOf(u8, dict, key) orelse return null;
    var i = ws(dict, ki + key.len);
    if (i >= dict.len or dict[i] != '[') return null;
    i += 1;
    const r1 = parseUint(dict, i) orelse return null;
    const r2 = parseUint(dict, r1.end) orelse return null;
    const after = ws(dict, r2.end);
    if (after < dict.len and dict[after] == 'R') return r1.v;
    return null;
}

/// Extract contents of a sub-dict value: /Key << content >> → content.
fn dictSubDict(dict: []const u8, key: []const u8) ?[]const u8 {
    const ki = std.mem.indexOf(u8, dict, key) orelse return null;
    var i = ws(dict, ki + key.len);
    if (i + 1 >= dict.len or dict[i] != '<' or dict[i + 1] != '<') return null;
    i += 2;
    const start = i;
    var depth: usize = 1;
    while (i + 1 < dict.len) {
        if (dict[i] == '<' and dict[i + 1] == '<') { depth += 1; i += 2; }
        else if (dict[i] == '>' and dict[i + 1] == '>') {
            depth -= 1;
            if (depth == 0) return dict[start..i];
            i += 2;
        } else i += 1;
    }
    return null;
}

/// Parse MediaBox [llx lly urx ury] from an object's dict bytes.
fn parseMediaBox(dict: []const u8) ?[4]f64 {
    const ki = std.mem.indexOf(u8, dict, "/MediaBox") orelse return null;
    var i = ws(dict, ki + "/MediaBox".len);
    if (i >= dict.len or dict[i] != '[') return null;
    i += 1;
    var vals: [4]f64 = undefined;
    for (&vals) |*v| {
        const r = parseSignedFloat(dict, i) orelse return null;
        v.* = r.v;
        i = r.end;
    }
    return vals;
}

/// Resolve /Length: handles direct integers and "N G R" indirect refs.
fn resolveLength(data: []const u8, dict: []const u8, offsets: *const std.AutoHashMap(usize, usize)) usize {
    const li = std.mem.indexOf(u8, dict, "/Length") orelse return 0;
    const r1 = parseUint(dict, li + "/Length".len) orelse return 0;
    const r2 = parseUint(dict, r1.end) orelse return r1.v;
    const after = ws(dict, r2.end);
    if (after < dict.len and dict[after] == 'R') {
        const len_off = offsets.get(r1.v) orelse return 0;
        const kw = std.mem.indexOfPos(u8, data, len_off, "obj") orelse return 0;
        const lr = parseUint(data, kw + 3) orelse return 0;
        return lr.v;
    }
    return r1.v;
}

/// Replace "/Length N G R" or "/Length N" in a dict with "/Length actual_val".
fn patchLength(allocator: Allocator, dict: []const u8, actual_len: usize) ![]const u8 {
    const li = std.mem.indexOf(u8, dict, "/Length") orelse
        return allocator.dupe(u8, dict);
    const after_key = li + "/Length".len;
    const r1 = parseUint(dict, after_key) orelse return allocator.dupe(u8, dict);
    const r2 = parseUint(dict, r1.end) orelse {
        return std.fmt.allocPrint(allocator, "{s} {d}{s}", .{
            dict[0..after_key], actual_len, dict[r1.end..],
        });
    };
    const after = ws(dict, r2.end);
    if (after < dict.len and dict[after] == 'R') {
        return std.fmt.allocPrint(allocator, "{s} {d}{s}", .{
            dict[0..after_key], actual_len, dict[after + 1 ..],
        });
    }
    return std.fmt.allocPrint(allocator, "{s} {d}{s}", .{
        dict[0..after_key], actual_len, dict[r1.end..],
    });
}

/// Scan text for all "N 0 R" indirect reference object numbers.
fn collectRefs(allocator: Allocator, text: []const u8) ![]usize {
    var result = std.array_list.Managed(usize).init(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] < '0' or text[i] > '9') { i += 1; continue; }
        const saved = i;
        const r1 = parseUint(text, i) orelse { i += 1; continue; };
        const r2 = parseUint(text, r1.end) orelse { i = r1.end; continue; };
        const after = ws(text, r2.end);
        if (after < text.len and text[after] == 'R') {
            const after_R = after + 1;
            const ok = after_R >= text.len or
                (text[after_R] != '_' and
                 (text[after_R] < 'a' or text[after_R] > 'z') and
                 (text[after_R] < 'A' or text[after_R] > 'Z') and
                 (text[after_R] < '0' or text[after_R] > '9'));
            if (ok and r1.v > 0) {
                try result.append(r1.v);
                i = after_R;
                continue;
            }
        }
        i = if (r1.end > saved) r1.end else saved + 1;
    }
    return result.toOwnedSlice();
}

/// Rewrite all "N G R" indirect refs in text using mapping (src → new).
fn remapRefs(allocator: Allocator, text: []const u8, mapping: *const std.AutoHashMap(usize, usize)) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] < '0' or text[i] > '9') { try out.append(text[i]); i += 1; continue; }
        const saved = i;
        const r1 = parseUint(text, i) orelse { try out.append(text[i]); i += 1; continue; };
        const r2 = parseUint(text, r1.end) orelse { try out.appendSlice(text[saved..r1.end]); i = r1.end; continue; };
        const after = ws(text, r2.end);
        if (after < text.len and text[after] == 'R') {
            const after_R = after + 1;
            const ok = after_R >= text.len or
                (text[after_R] != '_' and
                 (text[after_R] < 'a' or text[after_R] > 'z') and
                 (text[after_R] < 'A' or text[after_R] > 'Z') and
                 (text[after_R] < '0' or text[after_R] > '9'));
            if (ok) {
                if (mapping.get(r1.v)) |new_num| {
                    try out.writer().print("{d} 0 R", .{new_num});
                } else {
                    // not in mapping — write original
                    try out.appendSlice(text[saved..after_R]);
                }
                i = after_R;
                continue;
            }
        }
        try out.appendSlice(text[saved..r1.end]);
        i = r1.end;
    }
    return out.toOwnedSlice();
}

/// Data extracted from one PDF indirect object.
const ObjData = struct {
    dict: []const u8,
    stream: ?[]const u8,
    filter: ?[]const u8,
    actual_len: usize,
};

/// Extract a dict+stream object.  Returns null for non-dict objects (arrays, integers).
fn readDictObj(data: []const u8, offset: usize, offsets: *const std.AutoHashMap(usize, usize)) ?ObjData {
    const obj_kw = std.mem.indexOfPos(u8, data, offset, "obj") orelse return null;
    var i = ws(data, obj_kw + 3);
    if (i + 1 >= data.len or data[i] != '<' or data[i + 1] != '<') return null;
    i += 2;
    const dict_start = i;
    var depth: usize = 1;
    while (i + 1 < data.len) {
        if (data[i] == '<' and data[i + 1] == '<') { depth += 1; i += 2; }
        else if (data[i] == '>' and data[i + 1] == '>') {
            depth -= 1;
            if (depth == 0) break;
            i += 2;
        } else i += 1;
    }
    const dict = data[dict_start..i];
    i += 2;
    i = ws(data, i);
    if (i + 6 <= data.len and std.mem.eql(u8, data[i .. i + 6], "stream")) {
        i += 6;
        if (i < data.len and data[i] == '\r') i += 1;
        if (i < data.len and data[i] == '\n') i += 1;
        const stream_start = i;
        const len = resolveLength(data, dict, offsets);
        const stream_end = if (len > 0)
            stream_start + len
        else
            std.mem.indexOfPos(u8, data, stream_start, "endstream") orelse data.len;
        const filter: ?[]const u8 = if (std.mem.indexOf(u8, dict, "FlateDecode") != null) "FlateDecode" else null;
        return ObjData{
            .dict = dict,
            .stream = data[stream_start..@min(stream_end, data.len)],
            .filter = filter,
            .actual_len = len,
        };
    }
    return ObjData{ .dict = dict, .stream = null, .filter = null, .actual_len = 0 };
}

/// Extract the literal content of a non-dict object (array, integer, name).
/// Returns null if the object is a dict.
fn readLiteralObj(data: []const u8, offset: usize) ?[]const u8 {
    const obj_kw = std.mem.indexOfPos(u8, data, offset, "obj") orelse return null;
    const i = ws(data, obj_kw + 3);
    if (i + 1 < data.len and data[i] == '<' and data[i + 1] == '<') return null; // it's a dict
    const start = i;
    const end = std.mem.indexOfPos(u8, data, start, "endobj") orelse return null;
    var e = end;
    while (e > start and (data[e - 1] == ' ' or data[e - 1] == '\t' or data[e - 1] == '\r' or data[e - 1] == '\n')) e -= 1;
    return data[start..e];
}

/// Parse the traditional (non-compressed) xref table.
fn parseXref(data: []const u8, xref_offset: usize, offsets: *std.AutoHashMap(usize, usize)) !usize {
    var i = xref_offset;
    if (std.mem.indexOfPos(u8, data, i, "xref")) |xi| i = ws(data, xi + 4);
    while (i < data.len) {
        const first_r = parseUint(data, i) orelse break;
        const count_r = parseUint(data, first_r.end) orelse break;
        i = ws(data, count_r.end);
        const first = first_r.v;
        const count = count_r.v;
        for (0..count) |k| {
            if (i + 20 > data.len) break;
            const entry = data[i .. i + 20];
            const off = std.fmt.parseUnsigned(usize, entry[0..10], 10) catch 0;
            if (entry[17] == 'n') try offsets.put(first + k, off);
            i += 20;
        }
        i = ws(data, i);
        if (i + 7 <= data.len and std.mem.eql(u8, data[i .. i + 7], "trailer")) break;
    }
    const tpos = std.mem.indexOfPos(u8, data, xref_offset, "trailer") orelse return error.NoTrailer;
    const tdstart = std.mem.indexOfPos(u8, data, tpos, "<<") orelse return error.NoTrailer;
    return dictRef(data[tdstart..], "/Root") orelse error.NoRoot;
}

/// Decompress zlib/FlateDecode data using system libz.
fn zlibDecompress(allocator: Allocator, compressed: []const u8) ![]u8 {
    // Estimate output size; grow if needed.
    var out_len: usize = compressed.len * 4 + 256;
    while (true) {
        const buf = try allocator.alloc(u8, out_len);
        var dest_len: zlib.uLongf = @intCast(buf.len);
        const ret = zlib.uncompress(buf.ptr, &dest_len, compressed.ptr, @intCast(compressed.len));
        if (ret == zlib.Z_OK) return allocator.realloc(buf, @intCast(dest_len));
        allocator.free(buf);
        if (ret == zlib.Z_BUF_ERROR) {
            out_len *= 4;
            continue;
        }
        return error.DecompressFailed;
    }
}

/// Parse /W [w1 w2 w3] from a dict string. Returns null if not found.
fn parseWArray(dict: []const u8) ?[3]usize {
    const ki = std.mem.indexOf(u8, dict, "/W") orelse return null;
    var i = ws(dict, ki + 2);
    if (i >= dict.len or dict[i] != '[') return null;
    i += 1;
    var w: [3]usize = undefined;
    for (&w) |*wv| {
        const r = parseUint(dict, i) orelse return null;
        wv.* = r.v;
        i = r.end;
    }
    return w;
}

const Type2Entry = struct { stream_num: usize, idx: usize };

/// Parse a cross-reference stream object at `xref_offset`.
/// Populates `offsets` (type-1 entries) and `type2_entries` (type-2 entries).
/// Returns the root catalog object number.
fn parseXrefStream(allocator: Allocator, data: []const u8, xref_offset: usize, offsets: *std.AutoHashMap(usize, usize), type2_entries: *std.AutoHashMap(usize, Type2Entry)) !usize {
    // readDictObj needs an offsets map; /Length in xref streams is typically direct
    var dummy = std.AutoHashMap(usize, usize).init(allocator);
    defer dummy.deinit();

    const obj = readDictObj(data, xref_offset, &dummy) orelse return error.NoTrailer;
    const stream = obj.stream orelse return error.NoTrailer;

    const root_num = dictRef(obj.dict, "/Root") orelse return error.NoRoot;

    const w = parseWArray(obj.dict) orelse return error.NoTrailer;
    const entry_size = w[0] + w[1] + w[2];
    if (entry_size == 0) return error.NoTrailer;

    // Parse /Size (total number of entries if no /Index)
    const size: usize = if (std.mem.indexOf(u8, obj.dict, "/Size")) |ki| blk: {
        break :blk (parseUint(obj.dict, ki + "/Size".len) orelse break :blk 0).v;
    } else 0;

    // Decompress if FlateDecode
    const raw: []const u8 = if (obj.filter != null) blk: {
        break :blk try zlibDecompress(allocator, stream);
    } else try allocator.dupe(u8, stream);
    defer allocator.free(raw);

    // Parse /Index [first count first count ...] — default [0 size]
    const num_entries = raw.len / entry_size;
    var obj_numbers = try allocator.alloc(usize, num_entries);
    defer allocator.free(obj_numbers);

    var total_mapped: usize = 0;
    if (std.mem.indexOf(u8, obj.dict, "/Index")) |ki| {
        var i = ws(obj.dict, ki + "/Index".len);
        if (i < obj.dict.len and obj.dict[i] == '[') {
            i += 1;
            while (total_mapped < num_entries) {
                const r1 = parseUint(obj.dict, i) orelse break;
                const r2 = parseUint(obj.dict, r1.end) orelse break;
                const first = r1.v;
                const count = r2.v;
                i = r2.end;
                for (0..count) |k| {
                    if (total_mapped >= num_entries) break;
                    obj_numbers[total_mapped] = first + k;
                    total_mapped += 1;
                }
            }
        }
    }
    if (total_mapped == 0) {
        // default: [0 size]
        const n = @min(num_entries, size);
        for (0..n) |k| obj_numbers[k] = k;
        total_mapped = n;
    }

    // Parse binary entries
    var pos: usize = 0;
    for (0..total_mapped) |ei| {
        if (pos + entry_size > raw.len) break;
        // field 1: type (default 1 if w[0]==0)
        var entry_type: usize = if (w[0] == 0) 1 else 0;
        for (0..w[0]) |_| { entry_type = (entry_type << 8) | raw[pos]; pos += 1; }
        // field 2: offset (type 1) or obj stream num (type 2)
        var field2: usize = 0;
        for (0..w[1]) |_| { field2 = (field2 << 8) | raw[pos]; pos += 1; }
        // field 3: gen (type 1) or idx in stream (type 2)
        var field3: usize = 0;
        for (0..w[2]) |_| { field3 = (field3 << 8) | raw[pos]; pos += 1; }

        switch (entry_type) {
            1 => try offsets.put(obj_numbers[ei], field2),
            2 => try type2_entries.put(obj_numbers[ei], .{ .stream_num = field2, .idx = field3 }),
            else => {},
        }
    }

    return root_num;
}

/// Extract objects stored in object streams (type-2 xref entries).
/// Appends synthetic `N 0 obj ... endobj` blocks to a buffer and records
/// their offsets at `data_base + position_in_extra`.  Caller must free the
/// returned slice.
fn extractObjectStreams(allocator: Allocator, data: []const u8, data_base: usize, offsets: *std.AutoHashMap(usize, usize), type2_entries: *const std.AutoHashMap(usize, Type2Entry)) ![]const u8 {
    if (type2_entries.count() == 0) return allocator.dupe(u8, "");

    var extra = std.array_list.Managed(u8).init(allocator);
    errdefer extra.deinit();

    // Collect unique stream object numbers
    var stream_nums = std.AutoHashMap(usize, void).init(allocator);
    defer stream_nums.deinit();
    var it = type2_entries.valueIterator();
    while (it.next()) |e| try stream_nums.put(e.stream_num, {});

    var sit = stream_nums.keyIterator();
    while (sit.next()) |snp| {
        const stream_num = snp.*;
        const stream_off = offsets.get(stream_num) orelse continue;

        // /Length may be an indirect ref — use the real offsets map
        const obj = readDictObj(data, stream_off, offsets) orelse continue;
        const stream_bytes = obj.stream orelse continue;

        // /N = number of objects, /First = byte offset of first object in decompressed body
        const n: usize = if (std.mem.indexOf(u8, obj.dict, "/N")) |ki| blk: {
            break :blk (parseUint(obj.dict, ki + 2) orelse break :blk 0).v;
        } else continue;
        const first: usize = if (std.mem.indexOf(u8, obj.dict, "/First")) |ki| blk: {
            break :blk (parseUint(obj.dict, ki + "/First".len) orelse break :blk 0).v;
        } else continue;

        const raw: []const u8 = if (obj.filter != null)
            try zlibDecompress(allocator, stream_bytes)
        else
            try allocator.dupe(u8, stream_bytes);
        defer allocator.free(raw);

        // Parse header: N pairs of (obj_num  offset_from_first)
        var header_pos: usize = 0;
        var hdr_obj_nums = try allocator.alloc(usize, n);
        defer allocator.free(hdr_obj_nums);
        var hdr_offsets = try allocator.alloc(usize, n);
        defer allocator.free(hdr_offsets);

        for (0..n) |k| {
            const r1 = parseUint(raw, header_pos) orelse break;
            const r2 = parseUint(raw, r1.end) orelse break;
            hdr_obj_nums[k] = r1.v;
            hdr_offsets[k] = first + r2.v;
            header_pos = r2.end;
        }

        // Emit synthetic objects for all type-2 entries in this stream
        var t2it = type2_entries.iterator();
        while (t2it.next()) |t2e| {
            if (t2e.value_ptr.stream_num != stream_num) continue;
            const idx = t2e.value_ptr.idx;
            if (idx >= n) continue;
            const obj_num = t2e.key_ptr.*;
            const obj_start = hdr_offsets[idx];
            const obj_end = if (idx + 1 < n) hdr_offsets[idx + 1] else raw.len;
            if (obj_start > obj_end or obj_end > raw.len) continue;

            const synthetic_off = data_base + extra.items.len;
            try offsets.put(obj_num, synthetic_off);
            try extra.writer().print("{d} 0 obj\n", .{obj_num});
            try extra.appendSlice(raw[obj_start..obj_end]);
            try extra.appendSlice("\nendobj\n");
        }
    }

    return extra.toOwnedSlice();
}

fn findStartxref(data: []const u8) !usize {
    const needle = "startxref";
    const search_from: usize = if (data.len > 1024) data.len - 1024 else 0;
    var i = search_from;
    while (std.mem.indexOfPos(u8, data, i, needle)) |found| {
        if (parseUint(data, found + needle.len)) |r| return r.v;
        i = found + 1;
    }
    return error.NoStartxref;
}

pub const EmbedResult = struct { obj_num: usize, bbox: [4]f64 };

pub fn embedFirstPage(allocator: Allocator, doc: *pdf.Document, path: []const u8) !EmbedResult {
    const file_data = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(file_data);

    var offsets = std.AutoHashMap(usize, usize).init(allocator);
    defer offsets.deinit();
    var type2_entries = std.AutoHashMap(usize, Type2Entry).init(allocator);
    defer type2_entries.deinit();

    const xref_offset = try findStartxref(file_data);
    // Try traditional xref table first; fall back to cross-reference stream (PDF 1.5+)
    const root_num = parseXref(file_data, xref_offset, &offsets) catch |e| switch (e) {
        error.NoTrailer, error.NoRoot => blk: {
            offsets.clearRetainingCapacity();
            break :blk try parseXrefStream(allocator, file_data, xref_offset, &offsets, &type2_entries);
        },
        else => return e,
    };

    // For PDF 1.5+ object streams: extract embedded objects into a synthetic buffer
    // and record their synthetic offsets (data.len + position_in_extra) in `offsets`.
    const extra = try extractObjectStreams(allocator, file_data, file_data.len, &offsets, &type2_entries);
    defer allocator.free(extra);

    // Build unified data view: original file + synthetic objects appended
    const data: []const u8 = if (extra.len > 0) blk: {
        const combined = try allocator.alloc(u8, file_data.len + extra.len);
        @memcpy(combined[0..file_data.len], file_data);
        @memcpy(combined[file_data.len..], extra);
        break :blk combined;
    } else file_data;
    defer if (extra.len > 0) allocator.free(data);

    const cat_off = offsets.get(root_num) orelse return error.BadPdf;
    const cat = readDictObj(data, cat_off, &offsets) orelse return error.BadPdf;
    const pages_num = dictRef(cat.dict, "/Pages") orelse return error.BadPdf;

    const pages_off = offsets.get(pages_num) orelse return error.BadPdf;
    const pages_obj = readDictObj(data, pages_off, &offsets) orelse return error.BadPdf;
    const page_num = dictFirstArrayRef(pages_obj.dict, "/Kids") orelse
        dictRef(pages_obj.dict, "/Kids") orelse return error.BadPdf;

    const page_off = offsets.get(page_num) orelse return error.BadPdf;
    const page_obj = readDictObj(data, page_off, &offsets) orelse return error.BadPdf;
    const bbox = parseMediaBox(page_obj.dict) orelse return error.BadPdf;

    const cont_num = dictRef(page_obj.dict, "/Contents") orelse
        dictFirstArrayRef(page_obj.dict, "/Contents") orelse return error.BadPdf;
    const cont_off = offsets.get(cont_num) orelse return error.BadPdf;
    const cont_obj = readDictObj(data, cont_off, &offsets) orelse return error.BadPdf;
    const cont_bytes = cont_obj.stream orelse return error.BadPdf;

    const res_dict: []const u8 = blk: {
        if (dictSubDict(page_obj.dict, "/Resources")) |r| break :blk r;
        if (dictRef(page_obj.dict, "/Resources")) |rn| {
            if (offsets.get(rn)) |ro| {
                if (readDictObj(data, ro, &offsets)) |robj| break :blk robj.dict;
            }
        }
        break :blk "";
    };

    // --- Phase 1: BFS to collect all referenced objects in order ---
    var needed = std.array_list.Managed(usize).init(allocator);
    defer needed.deinit();
    var seen = std.AutoHashMap(usize, void).init(allocator);
    defer seen.deinit();

    {
        const refs = try collectRefs(allocator, res_dict);
        defer allocator.free(refs);
        for (refs) |n| {
            if (!seen.contains(n)) { try seen.put(n, {}); try needed.append(n); }
        }
    }
    var qi: usize = 0;
    while (qi < needed.items.len) : (qi += 1) {
        const src_num = needed.items[qi];
        const src_off = offsets.get(src_num) orelse continue;
        // scan both dict objects and literal objects for more refs
        const text: []const u8 = if (readDictObj(data, src_off, &offsets)) |o|
            o.dict
        else
            readLiteralObj(data, src_off) orelse continue;
        const refs = try collectRefs(allocator, text);
        defer allocator.free(refs);
        for (refs) |n| {
            if (!seen.contains(n)) { try seen.put(n, {}); try needed.append(n); }
        }
    }

    // --- Phase 2: pre-assign new object numbers ---
    // We need to know which objects will actually be added (both dict and literal)
    // before we can remap references in their dicts.
    var src_to_new = std.AutoHashMap(usize, usize).init(allocator);
    defer src_to_new.deinit();

    var next_num: usize = doc.objs.items.len + 1;
    for (needed.items) |src_num| {
        const src_off = offsets.get(src_num) orelse continue;
        // check it's a copyable object (dict or literal, not a bare integer like a length)
        const is_dict = readDictObj(data, src_off, &offsets) != null;
        const is_lit = !is_dict and readLiteralObj(data, src_off) != null;
        if (is_dict or is_lit) {
            try src_to_new.put(src_num, next_num);
            next_num += 1;
        }
    }

    // --- Phase 3: copy objects in order with remapped refs ---
    for (needed.items) |src_num| {
        const src_off = offsets.get(src_num) orelse continue;
        if (readDictObj(data, src_off, &offsets)) |obj| {
            const actual_len = obj.actual_len;
            const patched = if (obj.stream != null)
                try patchLength(allocator, obj.dict, actual_len)
            else
                try allocator.dupe(u8, obj.dict);
            const remapped = try remapRefs(allocator, patched, &src_to_new);
            const stream_copy: ?[]const u8 = if (obj.stream) |s| try allocator.dupe(u8, s) else null;
            _ = try doc.addRawObject(remapped, stream_copy);
        } else if (readLiteralObj(data, src_off)) |lit| {
            const remapped = try remapRefs(allocator, lit, &src_to_new);
            _ = try doc.addLiteralObject(remapped);
        }
    }

    // --- Build Form XObject ---
    const new_res_dict = try remapRefs(allocator, res_dict, &src_to_new);
    const filter_str: []const u8 = if (cont_obj.filter != null)
        try std.fmt.allocPrint(allocator, "\n/Filter /{s}", .{cont_obj.filter.?})
    else
        "";
    const cont_len = if (cont_obj.actual_len > 0) cont_obj.actual_len else cont_bytes.len;
    const form_dict = try std.fmt.allocPrint(allocator,
        "/Type /XObject\n/Subtype /Form\n/BBox [{d:.3} {d:.3} {d:.3} {d:.3}]\n/Resources <<\n{s}\n>>{s}\n/Length {d}",
        .{ bbox[0], bbox[1], bbox[2], bbox[3], new_res_dict, filter_str, cont_len },
    );
    const cont_copy = try allocator.dupe(u8, cont_bytes);
    const form_num = try doc.addRawObject(form_dict, cont_copy);

    log.dbg("pdf_reader: embedded {s} as Form XObject {d}, bbox=[{d:.1} {d:.1} {d:.1} {d:.1}]\n", .{
        path, form_num, bbox[0], bbox[1], bbox[2], bbox[3],
    });
    return EmbedResult{ .obj_num = form_num, .bbox = bbox };
}
