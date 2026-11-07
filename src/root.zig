/// Flat bitset plane, owns backing words and active-bit counts.
pub const bitset = @import("bitset.zig");
/// Pyramid summary level with activity and mixed planes.
pub const layer = @import("layer.zig");
/// Compile-time word arithmetic kit for all widths.
pub const bit_word = @import("bit_word").bit_word;
/// Shared aliases, callbacks and small helpers.
pub const utilities = @import("utilities.zig");
/// Hierarchical bit tree with flat/tree iteration choice.
pub const bit_structs = @import("bit_tree.zig");

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
pub const BitTree = bit_structs.BitTree;
/// Thresholds that tune the flat versus tree iteration choice.
pub const PredictConfig = bit_structs.PredictConfig;
/// Forced iteration path selector for prediction.
pub const PredictForce = bit_structs.PredictForce;
/// Per-width calibrated prediction rows indexed by word type.
pub const predict_table = &bit_structs.predict_table;
/// Global prediction overrides applied after per-width rows.
pub const predict_config = &bit_structs.predict_config;
