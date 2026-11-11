const std = @import("std");

// Point this at the file that holds your BitState / WordType / BitWord definitions.
const bit_word = @import("bit_word").bit_word;
const WordType = bit_word.WordType;
const BitWord = bit_word.BitWord;
const Bitset = bit_word.Bitset;

pub const Comparison = enum {
    equal,
    not_equal,
    less_than,
    less_than_or_equal,
    greater_than,
    greater_than_or_equal,
};

/// Array of `bits_count` values of type `Column_` (any unsigned integer from u1 to u64),
/// stored bit-sliced and slice-major: slice `s` (bit `s` of every value, slice 0 = LSB)
/// is one contiguous run of `words_count` words,
///
///     data[slice * words_count + word_id]
///
/// Bit `i` of word `w` in slice `s` is bit `s` of value `w * word_type_bits + i`.
/// The number of slices is `@bitSizeOf(Column)` and known at compile time, so every
/// loop over the slices is fully unrolled. Every slice is a plain bitset slice
/// (see `getSlice`) and a bulk scan can load several consecutive words of one slice
/// with a single vector load.
pub fn BitSlicedArray(comptime word_type: WordType, comptime Column_: type) type {
    comptime {
        const valid = switch (@typeInfo(Column_)) {
            .int => |info| info.signedness == .unsigned and info.bits >= 1 and info.bits <= 64,
            else => false,
        };
        if (!valid) {
            @compileError(std.fmt.comptimePrint(
                \\BitSlicedArray: invalid Column type '{s}'.
                \\Column must be an unsigned integer type from u1 to u64 (for example u3, u5 or u13).
                \\Its bit size is the number of bit slices, i.e. how many bits every stored value has,
                \\and it must be known at compile time because all slice loops are fully unrolled.
                \\Correct usage: BitSlicedArray(.u64, u5) stores 5-bit values (0..31).
            , .{@typeName(Column_)}));
        }
    }

    return struct {
        const Self = @This();

        pub const bw = BitWord(word_type);
        pub const Word = bw.Word;
        pub const Set = Bitset(word_type);

        /// Type of one stored value, unsigned integer from u1 to u64.
        pub const Column = Column_;
        /// Number of bit slices == bits per value.
        pub const slices_count: usize = @bitSizeOf(Column);

        /// Vector length (in words) suggested for this target, 1 when unknown.
        pub const default_vec_len: usize = std.simd.suggestVectorLength(Word) orelse 1;

        /// Lookup table indexed by a bit: 0 -> empty word, 1 -> word filled with ones.
        const bit_words = [2]Word{ 0, bw.max_value };

        /// Right-hand side made by `prepareRhs` and passed explicitly to every comparison:
        /// `kb[s]` is all-ones when bit `s` of the value is 1, otherwise 0.
        pub const Rhs = struct {
            kb: [slices_count]Word,
        };

        /// `slices_count * words_count` words, slice-major.
        data: []Word,
        /// Number of actual values stored.
        bits_count: usize,
        /// Number of lane words per slice (each covers `bw.word_type_bits` values).
        words_count: u32,
        /// Valid-lane mask of the last word, unused lanes are 0.
        last_word_mask: Word,

        /// - `bits_count` - number of actual values, the last word may be partially used.
        pub fn init(allocator: std.mem.Allocator, bits_count: usize) !Self {
            const count32: u32 = @intCast(bits_count);
            const words_count = bw.bitsToWordsCount(count32);

            const data = try allocator.alloc(Word, @as(usize, words_count) * slices_count);
            // Required: every value starts as 0, unused lanes stay 0.
            @memset(data, 0);

            const tail = bw.bitIdInWord(count32);

            return .{
                .data = data,
                .bits_count = bits_count,
                .words_count = words_count,
                .last_word_mask = if (tail == 0) bw.max_value else bw.maskStart(tail),
            };
        }

        /// Frees the storage and resets every field to zero / empty.
        /// `allocator` must be the same one that was passed to `init`.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.data);
            self.* = .{
                .data = &.{},
                .bits_count = 0,
                .words_count = 0,
                .last_word_mask = 0,
            };
        }

        /// Slice `slice_id` (bit `slice_id` of every value) as a plain bitset slice,
        /// `words_count` words.
        pub inline fn getSlice(self: *const Self, slice_id: usize) []const Word {
            if (std.debug.runtime_safety) {
                std.debug.assert(slice_id < slices_count);
            }
            const wc: usize = self.words_count;
            return self.data[slice_id * wc ..][0..wc];
        }

        /// Writes the value at `index`.
        pub fn set(self: *Self, index: usize, value: Column) void {
            if (std.debug.runtime_safety) {
                std.debug.assert(index < self.bits_count);
            }

            const v: u64 = value;
            const bit_id: u32 = @intCast(index);
            const word_id: usize = bw.bitToWordId(bit_id);
            const lane_mask: Word = @as(Word, 1) << bw.bitIdInWord(bit_id);
            const wc: usize = self.words_count;

            inline for (0..slices_count) |s| {
                const bit: u1 = @truncate(v >> @truncate(s));
                const word = &self.data[s * wc + word_id];
                word.* = bw.merge(word.*, bit_words[bit], lane_mask);
            }
        }

        /// Reads the value at `index`.
        pub fn get(self: *const Self, index: usize) Column {
            if (std.debug.runtime_safety) {
                std.debug.assert(index < self.bits_count);
            }

            const bit_id: u32 = @intCast(index);
            const word_id: usize = bw.bitToWordId(bit_id);
            const lane = bw.bitIdInWord(bit_id);
            const wc: usize = self.words_count;

            var result: u64 = 0;
            inline for (0..slices_count) |s| {
                result |= @as(u64, bw.readBit(self.data[s * wc + word_id], lane)) << @truncate(s);
            }
            return @intCast(result);
        }

        /// Builds the right-hand side for the comparison functions. It is a pure function
        /// of the value, so with a comptime-known value (`comptime Self.prepareRhs(6)`)
        /// the compiler folds the whole comparison down to constants per slice.
        pub fn prepareRhs(right_hand_side: Column) Rhs {
            const rhs: u64 = right_hand_side;
            var result: Rhs = .{ .kb = undefined };
            inline for (0..slices_count) |s| {
                const bit: u1 = @truncate(rhs >> @truncate(s));
                result.kb[s] = bit_words[bit];
            }
            return result;
        }

        /// Lookup table indexed by a bit: 0 -> empty vector, 1 -> vector filled with ones.
        fn bitVectors(comptime vec_len: usize) [2]@Vector(vec_len, Word) {
            return .{ @splat(0), @splat(bw.max_value) };
        }

        /// Right-hand side prepared as whole vectors: `kb[s]` is a vector of `vec_len` words,
        /// all-ones when bit `s` of the value is 1, otherwise all zeros.
        pub fn RhsVector(comptime vec_len: usize) type {
            return struct {
                kb: [slices_count]@Vector(vec_len, Word),
            };
        }

        /// Vector version of `prepareRhs`: the splats are done once here, so loops over
        /// `getMaskVector` don't have to repeat them. Pure function of the value, so a
        /// comptime-known value is folded by the compiler as well.
        pub fn prepareRhsVector(comptime vec_len: usize, right_hand_side: Column) RhsVector(vec_len) {
            const bit_vectors = comptime bitVectors(vec_len);
            const rhs: u64 = right_hand_side;
            var result: RhsVector(vec_len) = .{ .kb = undefined };
            inline for (0..slices_count) |s| {
                const bit: u1 = @truncate(rhs >> @truncate(s));
                result.kb[s] = bit_vectors[bit];
            }
            return result;
        }

        // ---- shared comparison core, works on a Word or a @Vector(n, Word) -------------

        inline fn splatAs(comptime T: type, x: Word) T {
            return if (T == Word) x else @splat(x);
        }

        /// Takes `kb[s]` as is when it already has type `T` (prepared vector rhs),
        /// otherwise splats the scalar word.
        inline fn kbAt(comptime T: type, rhs: anytype, comptime slice_id: usize) T {
            const item = rhs.kb[slice_id];
            return if (@TypeOf(item) == T) item else splatAs(T, item);
        }

        inline fn loadSlice(self: *const Self, comptime T: type, comptime slice_id: usize, index: usize) T {
            const at = slice_id * @as(usize, self.words_count) + index;
            if (T == Word) return self.data[at];
            const n = @typeInfo(T).vector.len;
            return self.data[at..][0..n].*;
        }

        /// Compares the words `index ..< index + lanes of T` against the rhs.
        /// Does NOT apply the last-word mask.
        inline fn compare(
            self: *const Self,
            comptime comparison: Comparison,
            comptime T: type,
            index: usize,
            rhs: anytype, // *const Rhs, or *const RhsVector(n) when T is a @Vector(n, Word)
        ) T {
            const need_gt = comptime switch (comparison) {
                .greater_than, .greater_than_or_equal => true,
                else => false,
            };
            const need_lt = comptime switch (comparison) {
                .less_than, .less_than_or_equal => true,
                else => false,
            };

            var gt: T = splatAs(T, 0);
            var lt: T = splatAs(T, 0);
            var eq: T = splatAs(T, bw.max_value);

            // MSB -> LSB, fully unrolled; `eq` = lanes equal to rhs on all bits seen so far.
            inline for (0..slices_count) |i| {
                const s = slices_count - 1 - i;
                const slice = self.loadSlice(T, s, index);
                const kb = kbAt(T, rhs, s);

                if (need_gt) gt |= eq & slice & ~kb;
                if (need_lt) lt |= eq & ~slice & kb;
                eq &= ~(slice ^ kb);
            }

            return switch (comparison) {
                .equal => eq,
                .not_equal => ~eq,
                .greater_than => gt,
                .greater_than_or_equal => gt | eq,
                .less_than => lt,
                .less_than_or_equal => lt | eq,
            };
        }

        // ---- single word ----------------------------------------------------------------

        /// Mask of lane word `word_id` where bit `i` is active when
        /// `value[word_id * word_type_bits + i] <comparison> rhs`.
        /// Unused lanes of the last word are always 0.
        pub fn getMask(
            self: *const Self,
            comptime comparison: Comparison,
            word_id: u32,
            rhs: *const Rhs,
        ) Word {
            if (std.debug.runtime_safety) {
                std.debug.assert(word_id < self.words_count);
            }

            const result = self.compare(comparison, Word, word_id, rhs);

            // Only depends on word_id, never on stored data.
            return if (word_id == self.words_count - 1) result & self.last_word_mask else result;
        }

        // ---- bulk -----------------------------------------------------------------------

        /// One vector step: the masks of the `vec_len` consecutive words
        /// `word_id ..< word_id + vec_len`, one mask per vector element.
        /// Requires `word_id + vec_len <= words_count`. Unused lanes of the last word are 0.
        ///
        /// Meant to be called in a loop, the tail (fewer than `vec_len` words left) is
        /// done with `getMask`:
        ///
        ///     const rhs_vec = Arr.prepareRhsVector(n, value);
        ///     const rhs = Arr.prepareRhs(value);
        ///     var i: u32 = 0;
        ///     while (i + n <= arr.words_count) : (i += n) {
        ///         out[i..][0..n].* = arr.getMaskVector(.greater_than, n, i, &rhs_vec);
        ///     }
        ///     while (i < arr.words_count) : (i += 1) out[i] = arr.getMask(.greater_than, i, &rhs);
        pub fn getMaskVector(
            self: *const Self,
            comptime comparison: Comparison,
            comptime vec_len: usize,
            word_id: u32,
            rhs: *const RhsVector(vec_len),
        ) @Vector(vec_len, Word) {
            if (std.debug.runtime_safety) {
                std.debug.assert(@as(usize, word_id) + vec_len <= self.words_count);
            }

            var result = self.compare(comparison, @Vector(vec_len, Word), word_id, rhs);

            // Only depends on word_id, never on stored data.
            if (@as(usize, word_id) + vec_len == self.words_count) {
                result[vec_len - 1] &= self.last_word_mask;
            }
            return result;
        }

        /// Scalar bulk: writes the mask of every word into `out` (`out.len == words_count`).
        pub fn getMasks(
            self: *const Self,
            comptime comparison: Comparison,
            rhs: *const Rhs,
            out: []Word,
        ) void {
            if (std.debug.runtime_safety) {
                std.debug.assert(out.len == self.words_count);
            }
            if (self.words_count == 0) return;

            for (0..self.words_count) |i| {
                out[i] = self.compare(comparison, Word, i, rhs);
            }
            out[self.words_count - 1] &= self.last_word_mask;
        }

        /// Vectorized bulk: processes `vec_len` consecutive words per step, the remaining
        /// tail words use the scalar path. Result is identical to `getMasks`.
        pub fn getMasksVector(
            self: *const Self,
            comptime comparison: Comparison,
            comptime vec_len: usize,
            rhs: *const Rhs,
            out: []Word,
        ) void {
            if (std.debug.runtime_safety) {
                std.debug.assert(out.len == self.words_count);
            }
            if (self.words_count == 0) return;

            const V = @Vector(vec_len, Word);
            const count: usize = self.words_count;

            var i: usize = 0;
            while (i + vec_len <= count) : (i += vec_len) {
                out[i..][0..vec_len].* = self.compare(comparison, V, i, rhs);
            }
            while (i < count) : (i += 1) {
                out[i] = self.compare(comparison, Word, i, rhs);
            }

            out[count - 1] &= self.last_word_mask;
        }

        /// `getMasksVector` with the vector length suggested for the target.
        pub fn getMasksSimd(
            self: *const Self,
            comptime comparison: Comparison,
            rhs: *const Rhs,
            out: []Word,
        ) void {
            self.getMasksVector(comparison, default_vec_len, rhs, out);
        }
    };
}

fn scalarCompare(comptime comparison: Comparison, v: u64, rhs: u64) bool {
    return switch (comparison) {
        .equal => v == rhs,
        .not_equal => v != rhs,
        .less_than => v < rhs,
        .less_than_or_equal => v <= rhs,
        .greater_than => v > rhs,
        .greater_than_or_equal => v >= rhs,
    };
}

fn testAgainstReference(comptime wt: WordType, comptime Col: type, count: usize) !void {
    const Arr = BitSlicedArray(wt, Col);
    const allocator = std.testing.allocator;

    var arr = try Arr.init(allocator, count);
    defer arr.deinit(allocator);

    const values = try allocator.alloc(Col, count);
    defer allocator.free(values);
    const out_scalar = try allocator.alloc(Arr.Word, arr.words_count);
    defer allocator.free(out_scalar);
    const out_vec = try allocator.alloc(Arr.Word, arr.words_count);
    defer allocator.free(out_vec);
    const out_simd = try allocator.alloc(Arr.Word, arr.words_count);
    defer allocator.free(out_simd);

    var prng = std.Random.DefaultPrng.init(42);
    for (values, 0..) |*v, i| {
        v.* = prng.random().int(Col);
        arr.set(i, v.*);
    }
    for (values, 0..) |v, i| try std.testing.expectEqual(v, arr.get(i));

    const max: Col = std.math.maxInt(Col);
    // u1 has a u0 shift amount, so `max >> 1` does not compile there.
    const half: Col = comptime if (@bitSizeOf(Col) == 1) 0 else max >> 1;
    const rhs_values = [_]Col{ 0, 1, max, half, values[0] };

    inline for (comptime std.enums.values(Comparison)) |cmp| {
        for (rhs_values) |rhs_value| {
            const rhs = Arr.prepareRhs(rhs_value);

            arr.getMasks(cmp, &rhs, out_scalar);
            arr.getMasksVector(cmp, 4, &rhs, out_vec);
            arr.getMasksSimd(cmp, &rhs, out_simd);

            const rhs_vec = Arr.prepareRhsVector(4, rhs_value);
            var w_vec: usize = 0;
            while (w_vec + 4 <= arr.words_count) : (w_vec += 4) {
                const vec = arr.getMaskVector(cmp, 4, @intCast(w_vec), &rhs_vec);
                for (0..4) |k| try std.testing.expectEqual(out_scalar[w_vec + k], vec[k]);
            }

            for (0..arr.words_count) |w| {
                const single = arr.getMask(cmp, @intCast(w), &rhs);
                try std.testing.expectEqual(single, out_scalar[w]);
                try std.testing.expectEqual(single, out_vec[w]);
                try std.testing.expectEqual(single, out_simd[w]);

                for (0..Arr.bw.word_type_bits) |lane| {
                    const i = w * Arr.bw.word_type_bits + lane;
                    const got = Arr.bw.readBit(single, @intCast(lane));
                    // Unused lanes of the last word must be 0.
                    const expected = i < count and scalarCompare(cmp, values[i], rhs_value);
                    try std.testing.expectEqual(@intFromBool(expected), got);
                }
            }
        }
    }
}

test "BitSlicedArray matches scalar reference" {
    inline for (.{ WordType.u8, WordType.u64 }) |wt| {
        inline for (.{ u1, u3, u5, u8, u13, u64 }) |Col| {
            try testAgainstReference(wt, Col, 1);
            try testAgainstReference(wt, Col, 70);
            try testAgainstReference(wt, Col, 1003);
        }
    }
}

test "deinit resets the struct" {
    const Arr = BitSlicedArray(.u64, u3);
    var arr = try Arr.init(std.testing.allocator, 10);
    arr.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), arr.data.len);
    try std.testing.expectEqual(@as(usize, 0), arr.bits_count);
    try std.testing.expectEqual(@as(u32, 0), arr.words_count);
    try std.testing.expectEqual(@as(u64, 0), arr.last_word_mask);
}
