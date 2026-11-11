/// Flat bitset plane, owns backing words and active-bit counts.
pub const bitset = @import("bitset.zig");
/// Pyramid summary level with activity and mixed planes.
pub const layer = @import("layer.zig");
/// Compile-time word arithmetic kit for all widths.
pub const bit_word = @import("bit_word").bit_word;
/// Shared aliases, callbacks and small helpers.
pub const utilities = @import("utilities.zig");
/// Hierarchical bit tree with flat/tree iteration choice.
pub const bit_tree = @import("bit_tree.zig");
pub const bit_sliced_array = @import("bit_sliced_array.zig");

/// Flat bitset type factory, backing store for the tree leaves.
pub const Bitset = bitset.Bitset;
/// Pyramid level type factory, aggregates leaf summaries.
pub const Layer = layer.Layer;
/// Backing integer width selector for all containers.
pub const WordType = bit_word.WordType;
/// Word arithmetic kit factory for bit/word conversions.
pub const BitWord = bit_word.BitWord;
/// Logical single-bit value shared across the package.
pub const BitState = bit_word.BitState;
/// Walk order for every iterator in bitset, layer and tree.
pub const Direction = utilities.Direction;
/// Hierarchical tree type factory with adaptive iteration.
pub const BitTree = bit_tree.BitTree;
/// Thresholds that tune the flat versus tree iteration choice.
pub const PredictConfig = bit_tree.PredictConfig;
/// Forced iteration path selector for prediction.
pub const PredictForce = bit_tree.PredictForce;
/// Per-width calibrated prediction rows indexed by word type.
pub const predict_table = &bit_tree.predict_table;
/// Global prediction overrides applied after per-width rows.
pub const predict_config = &bit_tree.predict_config;

test {
    _ = bit_sliced_array;
    _ = bit_tree;
    _ = bitset;
    _ = layer;
}
