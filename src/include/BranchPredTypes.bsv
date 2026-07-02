import Types::*;
`include "Autoconf.bsv"

// ============================================================================
// Branch Prediction Unit — Shared Type Definitions
// ============================================================================

// ---- CFI (Control Flow Instruction) Type Enum ----
typedef enum {
    CFI_NONE,    // not a control flow instruction
    CFI_COND,    // conditional branch (BEQ, BNE, BLT, etc.)
    CFI_JAL,     // direct jump (B, BL) — always taken, target from immediate
    CFI_CALL,    // direct call (BL with rd=x1)
    CFI_JALR,    // indirect jump (JIRL rd!=x1/x5, rs1!=x1/x5)
    CFI_ICALL,   // indirect call (JIRL rd=x1/x5)
    CFI_RET      // return (JIRL rs1=x1/x5, rd=x0 or rd=x1)
} CfiType deriving (Bits, Eq, FShow);

// ---- Small BTB Parameters ----
// Configurable via Kconfig: run 'make menuconfig' and set SMALL_BTB_ENTRIES
// (power of 2, e.g. 0x10=16, 0x20=32, 0x40=64, 0x80=128)
`ifndef CONFIG_SMALL_BTB_ENTRIES
`define CONFIG_SMALL_BTB_ENTRIES 32
`endif
typedef `CONFIG_SMALL_BTB_ENTRIES SmallBtbEntries;      // e.g. 32 entries
typedef TLog#(SmallBtbEntries)     LogSmallBtbEntries;   // e.g. TLog#(32) = 5
typedef 16                         SmallBtbTagSz;        // 16-bit partial tag

// ---- Small BTB Entry ----
typedef struct {
    Bool                  valid;
    Bit#(SmallBtbTagSz)   tag;
    Addr                  target;
    CfiType               cfi_type;
    Bit#(2)               ctr;         // 2-bit direction counter
} SmallBtbEntry deriving (Bits, Eq);

// ---- Main BTB Parameters ----
// Configurable via Kconfig: MBTB_ENTRIES (power of 2). Default 0x80=128 to
// match sram_128x64_wrap depth on FPGA. SmallBtb stays flip-flop based.
`ifndef CONFIG_MBTB_ENTRIES
`define CONFIG_MBTB_ENTRIES 128
`endif
typedef `CONFIG_MBTB_ENTRIES MbtbEntries;
typedef TLog#(MbtbEntries)    LogMbtbEntries;   // 7 for 128 entries
typedef 16                    MbtbTagSz;

// ---- Main BTB Entry ----
typedef struct {
    Bool                valid;
    Bit#(MbtbTagSz)     tag;
    CfiType             cfi_type;
    Addr                target;       // direct target or indirect last target
    Bit#(2)             bias_ctr;     // optional: always-taken / strong-bias fallback
    Bit#(2)             conf;         // optional: target confidence
} MBtbEntry deriving (Bits, Eq);

// ---- Fast Prediction Result ----
typedef struct {
    Bool    valid;       // small BTB hit
    Bool    taken;       // predicted direction (for COND)
    Addr    target;      // predicted target (for JAL/CALL/JALR/RET)
    CfiType cfi_type;   // CFI type from small BTB
} FastPredInfo deriving (Bits, Eq);

// ---- TAGE Parameters ----
// Configurable via Kconfig: TAGE_ENTRIES (power of 2). Default 0x40=64.
// On FPGA, sram_128x64_wrap is used (128 deep); the lower 64 entries are used.
`ifndef CONFIG_TAGE_ENTRIES
`define CONFIG_TAGE_ENTRIES 64
`endif
typedef `CONFIG_TAGE_ENTRIES TageEntries;
typedef TLog#(TageEntries)   LogTageEntries;   // 6 for 64 entries
typedef 8   TageTagSz;           // 8-bit partial tag
typedef 256 GhrSz;               // Global History Register width
typedef 3   TageCtrSz;           // 3-bit signed prediction counter
typedef 2   TageUseSz;           // 2-bit usefulness counter
typedef 7   NumTageTables;       // T1 through T7

// TAGE history lengths (geometric progression)
typedef 4   TAGE_HL1;   // T1
typedef 8   TAGE_HL2;   // T2
typedef 16  TAGE_HL3;   // T3
typedef 32  TAGE_HL4;   // T4
typedef 64  TAGE_HL5;   // T5
typedef 128 TAGE_HL6;   // T6
typedef 256 TAGE_HL7;   // T7

// TAGE tagged table entry
typedef struct {
    Bit#(TageTagSz) tag;
    Int#(TageCtrSz) ctr;     // signed prediction counter (-4..+3)
    Bit#(TageUseSz) u;       // usefulness counter (0..3)
} TageEntry deriving (Bits, Eq);

// TAGE prediction metadata (provider table + index + alternate table)
// Repacked for 64-entry tables (6-bit provider index):
//   [15:13] provider_table  (0=bimodal, 1-7=T1-T7)
//   [12:10] alternate_table (0=none/bimodal)
//   [9:4]   provider_index  (6 bits for 64-entry tables)
//   [3:0]   bimodal_index   (4 bits for 16-entry bimodal table)
typedef 16 TageMetaSz;
typedef Bit#(TageMetaSz) TageMeta;

// ---- ITTAGE Parameters ----
// Configurable via Kconfig: ITTAGE_ENTRIES (power of 2). Default 0x40=64.
`ifndef CONFIG_ITTAGE_ENTRIES
`define CONFIG_ITTAGE_ENTRIES 64
`endif
typedef `CONFIG_ITTAGE_ENTRIES IttageEntries;
typedef TLog#(IttageEntries)    IttageLogEntries;   // 6 for 64 entries
typedef 4   IttageNumTables;     // 4 tagged tables
typedef 8   IttageTagSz;         // 8-bit partial tag
typedef 256 IttagePathHistSz;    // Path history register width
typedef 2   IttageConfSz;        // 2-bit confidence counter

// ITTAGE history lengths (geometric progression)
typedef 4   IT_HL1;
typedef 16  IT_HL2;
typedef 64  IT_HL3;
typedef 256 IT_HL4;

// ITTAGE table entry
typedef struct {
    Bit#(IttageTagSz)  tag;
    Addr               target;    // predicted target address
    Bit#(IttageConfSz) conf;      // confidence counter (0..3)
} IttageEntry deriving (Bits, Eq);

// ITTAGE prediction (target + confidence flag)
typedef struct {
    Addr  target;
    Bool  confident;       // conf >= 2
} IttagePrediction deriving (Bits, Eq);

// ITTAGE prediction metadata (provider table + index)
// Repacked for 64-entry tables (6-bit provider index):
//   [8:6] provider_table (0=none, 1-4=T1-T4)
//   [5:0] provider_index (6 bits for 64-entry tables)
typedef 9 IttageMetaSz;
typedef Bit#(IttageMetaSz) IttageMeta;

// ---- Prediction Results from TAGE ----
typedef struct {
    Bool      valid;     // provider found in TAGE tables
    Bool      taken;     // predicted direction
    TageMeta  meta;      // provider/alternate/index for update
} TagePredInfo deriving (Bits, Eq);

// ---- Prediction Results from ITTAGE ----
typedef struct {
    Bool        valid;     // provider found in ITTAGE tables
    Addr        target;    // predicted target
    Bool        confident; // conf >= 2
    IttageMeta  meta;      // provider/index for update
} IttagePredInfo deriving (Bits, Eq);

// ---- History Snapshot (for checkpoint recovery) ----
typedef struct {
    Bit#(GhrSz)            ghist_snapshot;
    Bit#(IttagePathHistSz) phist_snapshot;
} HistSnapshot deriving (Bits, Eq);

// ---- BPU Result (combines fast + accurate path predictions) ----
typedef struct {
    FastPredInfo    fast;         // fast path result
    Bool            mbtb_hit;     // mBTB lookup result
    CfiType         mbtb_cfi;     // CFI type from mBTB
    Addr            mbtb_target;  // target from mBTB
    TagePredInfo    tage;         // TAGE direction result
    IttagePredInfo  ittage;       // ITTAGE target result
} BPUResult deriving (Bits, Eq);

// ---- In-Flight Branch Prediction Meta ----
// Carried through pipeline for execute-stage training and commit recovery
typedef struct {
    Addr            pc;

    // Fast path info
    Bool            fast_valid;
    Bool            fast_taken;
    Addr            fast_target;
    CfiType         cfi_type;

    // mBTB info
    Bool            mbtb_hit;
    Bit#(LogMbtbEntries) mbtb_idx;
    Bit#(MbtbTagSz) mbtb_tag;

    // TAGE info
    Bool            tage_valid;
    Bool            tage_taken;
    TageMeta        tage_meta;

    // ITTAGE info
    Bool            ittage_valid;
    Addr            ittage_target;
    IttageMeta      ittage_meta;

    // History snapshot for recovery
    HistSnapshot    hist_snapshot;
} PredMeta deriving (Bits, Eq);

// ---- Predictor Undo Entry Type ----
typedef enum {
    UPD_SMALL_BTB,
    UPD_MBTB,
    UPD_TAGE_TAGGED,
    UPD_ITTAGE_TAGGED,
    UPD_GHIST,
    UPD_PHIST
} UpdType deriving (Bits, Eq, FShow);

// Width of the old_value field in undo entries
// Needs to hold the largest table entry (SmallBtbEntry ~72 bits)
typedef 80 UndoOldValueSz;

// ---- Predictor Undo Entry ----
// Records old value before speculative write for commit-stage recovery
typedef struct {
    Bool                valid;
    UpdType             upd_type;
    Bit#(3)             table_id;    // which table (0-6 for TAGE, 0-3 for ITTAGE)
    Bit#(7)             index;       // max index width = 7 (for mBTB)
    Bit#(UndoOldValueSz) old_value; // previous value of the modified entry
} PredictorUndoEntry deriving (Bits, Eq);

// ---- Undo Log Pointer ----
typedef 5  UndoLogEntries;   // max 32 in-flight undo entries
typedef TExp#(UndoLogEntries) UndoLogSize;
typedef Bit#(UndoLogEntries) UndoLogPtr;
