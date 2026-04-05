`define CSR_CRMD        14'h0 // CsrCrmd
`define CSR_PRMD        14'h1 // CsrPrmd
`define CSR_EUEN        14'h2 // EUEN extension enable
`define CSR_ECFG        14'h4 // ECFG exception config
`define CSR_ESTAT       14'h5 // CsrEstat
`define CSR_ERA         14'h6 // CsrEra
`define CSR_BADV        14'h7 // BADV bad address virtual
`define CSR_EENTRY      14'hc // CsrEentry
`define CSR_TLBIDX      14'h10 // TLBIDX TLB index
`define CSR_TLBEHI      14'h11 // TLBEHI TLB entry high
`define CSR_TLBEL0      14'h12 // TLBEL0 TLB entry low 0
`define CSR_TLBEL1      14'h13 // TLBEL1 TLB entry low 1
`define CSR_ASID        14'h18 // ASID address space identifier
`define CSR_PGDL        14'h19 // PGDL page global directory low
`define CSR_PGDH        14'h1a // PGDH page global directory high
`define CSR_PGD         14'h1b // PGD page global directory
`define CSR_CPUID       14'h20 // CPUID CPU identifier
`define CSR_SAVE0       14'h30 // CsrSave0
`define CSR_SAVE1       14'h31 // CsrSave1
`define CSR_SAVE2       14'h32 // CsrSave2
`define CSR_SAVE3       14'h33 // CsrSave3
`define CSR_TID         14'h40 // TID timer ID
`define CSR_TCFG        14'h41 // TCFG timer configuration
`define CSR_TVAL        14'h42 // TVAL timer value
`define CSR_TICLR       14'h44 // TICLR timer interrupt clear
`define CSR_LLBCTL      14'h60 // LLBCTL LLBit control
`define CSR_TLBRENTRY   14'h88 // TLBRENTRY TLB refill entry
`define CSR_CTAG        14'h98 // CTAG cache tag
`define CSR_DMW0        14'h180 // DMW0 direct map window 0
`define CSR_DMW1        14'h181 // DMW1 direct map window 1

`define CSR_CRMD_PLV    1: 0
`define CSR_CRMD_IE     2
`define CSR_CRMD_DA     3 // Direct address translation enable
`define CSR_CRMD_PG     4 // Mapped address translation enable
`define CSR_CRMD_DATF   6: 5 // Direct mode: fetch access type
`define CSR_CRMD_DATM   8: 7 // Direct mode: load/store access type

`define CSR_PRMD_PPLV   1: 0
`define CSR_PRMD_PIE    2

`define CSR_ECFG_LIE    12: 0 // csr_ecfg_lie[10] reserved bit 0

`define CSR_ESTAT_IS10  1: 0 // Software interrupt
`define CSR_ESTAT_ECODE 21: 16 // Exception code
`define CSR_ESTAT_ESUBCODE 30: 22 // Exception subcode

`define ECODE_INT       6'h0
`define ECODE_PIL       6'h1 // Load page invalid
`define ECODE_PIS       6'h2 // Store page invalid
`define ECODE_PIF       6'h3 // Fetch page invalid
`define ECODE_PME       6'h4 // Page modify
`define ECODE_PPI       6'h7 // Page privilege illegal
`define ECODE_ADE       6'h8 // Address error
`define ESUBCODE_ADEF   9'h0 // Fetch address error
`define ESUBCODE_ADEM   9'h1 // Load/store address error
`define ESUBCODE_NONE   9'b0 // No subcode
`define ECODE_ALE       6'h9 // Address unaligned
`define ECODE_SYS       6'hB // Syscall
`define ECODE_BRK       6'hC // Breakpoint
`define ECODE_INE       6'hD // Instruction not exist
`define ECODE_IPE       6'hE // Instruction privilege error
`define ECODE_FPD       6'hF // Floating-point disabled
`define ECODE_FPE       6'h12 // Floating-point exception

`define ECODE_TLBR      6'h3F // TLB refill

`define CSR_ERA_PC      31: 0

`define CSR_EENTRY_VA   31: 6 // RW exception/interrupt entry [31:6]

`define CSR_SAVE_DATA   31: 0

`define CSR_TID_TID     31: 0 // RW timer ID

`define CSR_TCFG_EN     0
`define CSR_TCFG_PERIOD 1
`define CSR_TCFG_INITV  31: 2 // RW timer initial value

`define CSR_TICLR_CLR   0 // W1 clear timer interrupt

`define CSR_TLBIDX_INDEX 3: 0 // TLB index
`define CSR_TLBIDX_NE    31 // Not-exist flag (RO)
`define CSR_TLBIDX_PS    29: 24 // Page size

`define CSR_TLBEHI_VPPN  31: 13 // Virtual page number

`define CSR_TLBELO_V     0 // Valid
`define CSR_TLBELO_D     1 // Dirty
`define CSR_TLBELO_PLV   3: 2 // Privilege level
`define CSR_TLBELO_MAT   5: 4 // Memory access type
`define CSR_TLBELO_G     6 // Global
`define CSR_TLBELO_PPN   27: 8 // Physical page number

`define CSR_ASID_ASIDBITS 23: 16 // ASID width (RO)
`define CSR_ASID_ASID     9: 0 // ASID value

`define CSR_PGD_BASE    31: 12 // Page global directory base

`define CSR_TLBRENTRY_PA 31: 6 // TLB refill entry

`define CSR_DMW_PLV0    0 // Enable at PLV0
`define CSR_DMW_PLV3    3 // Enable at PLV3
`define CSR_DMW_MAT     5: 4 // Memory access type
`define CSR_DMW_PSEG    27: 25 // Physical segment
`define CSR_DMW_VSEG    31: 29 // Virtual segment base
