#!/usr/bin/env python3
"""
Generate a fixed chiplab adapter for mkCoreAxiTop.

Input:
  src/build/verilog/mkCoreAxiTop.v

Output:
  chiplab/IP/myCPU/mycpu_top.v   (module name fixed: core_top)
"""

from pathlib import Path


DIFF_PORTS = [
    "EN_diffTrace",
    "diffTrace",
    "diffTraceValid",
    "diffCommitBundle",
    "diffRegsBundle",
    "diffCsrBundle",
    "diffExcpBundle",
    "diffStoreBundle",
    "diffLoadBundle",
    "EN_diffTraceDeq",
]


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def require_ports(text: str, ports: list[str]) -> None:
    missing = [p for p in ports if p not in text]
    if missing:
        raise RuntimeError(f"mkCoreAxiTop.v missing required ports: {', '.join(missing)}")


def has_all_ports(text: str, ports: list[str]) -> bool:
    return all(port in text for port in ports)

def render_wrapper(enable_difftest: bool) -> str:
    diff_decl = ""
    diff_conn_ports: list[str] = []
    diff_logic = ""

    if enable_difftest:
        diff_decl = """
  wire [2463:0] diffTraceUnused;
  wire          diffTraceReadyUnused;
  wire          diffTraceValid;
  wire          diffTraceValidReadyUnused;
  wire [141:0]  diffCommitBundle;
  wire          diffCommitBundleReadyUnused;
  wire [1023:0] diffRegsBundle;
  wire          diffRegsBundleReadyUnused;
  wire [831:0]  diffCsrBundle;
  wire          diffCsrBundleReadyUnused;
  wire [129:0]  diffExcpBundle;
  wire          diffExcpBundleReadyUnused;
  wire [199:0]  diffStoreBundle;
  wire          diffStoreBundleReadyUnused;
  wire [135:0]  diffLoadBundle;
  wire          diffLoadBundleReadyUnused;
  wire          diffTraceDeq;
  wire          diffTraceDeqReadyUnused;
"""
        diff_conn_ports = [
            ".EN_diffTrace        (1'b0)",
            ".diffTrace           (diffTraceUnused)",
            ".RDY_diffTrace       (diffTraceReadyUnused)",
            ".diffTraceValid      (diffTraceValid)",
            ".RDY_diffTraceValid  (diffTraceValidReadyUnused)",
            ".diffCommitBundle    (diffCommitBundle)",
            ".RDY_diffCommitBundle(diffCommitBundleReadyUnused)",
            ".diffRegsBundle      (diffRegsBundle)",
            ".RDY_diffRegsBundle  (diffRegsBundleReadyUnused)",
            ".diffCsrBundle       (diffCsrBundle)",
            ".RDY_diffCsrBundle   (diffCsrBundleReadyUnused)",
            ".diffExcpBundle      (diffExcpBundle)",
            ".RDY_diffExcpBundle  (diffExcpBundleReadyUnused)",
            ".diffStoreBundle     (diffStoreBundle)",
            ".RDY_diffStoreBundle (diffStoreBundleReadyUnused)",
            ".diffLoadBundle      (diffLoadBundle)",
            ".RDY_diffLoadBundle  (diffLoadBundleReadyUnused)",
            ".EN_diffTraceDeq     (diffTraceDeq)",
            ".RDY_diffTraceDeq    (diffTraceDeqReadyUnused)",
        ]
        diff_logic = """
`ifdef DIFFTEST_EN
  reg  [63:0] cycleCnt;
  reg  [63:0] instrCnt;
  reg         diffStepValid_r;
  reg  [141:0]  diffCommitBundle_r;
  reg  [1023:0] diffRegsBundle_r;
  reg  [831:0]  diffCsrBundle_r;
  reg  [129:0]  diffExcpBundle_r;
  reg  [199:0]  diffStoreBundle_r;
  reg  [135:0]  diffLoadBundle_r;

  wire         cmt_valid       = diffStepValid_r && diffCommitBundle_r[141];
  wire [31:0]  cmt_pc          = diffCommitBundle_r[140:109];
  wire [31:0]  cmt_next_pc     = diffCommitBundle_r[108:77];
  wire [31:0]  cmt_inst        = diffCommitBundle_r[76:45];
  wire         cmt_wen         = diffCommitBundle_r[44];
  wire [4:0]   cmt_wdest_raw   = diffCommitBundle_r[43:39];
  wire [31:0]  cmt_wdata       = diffCommitBundle_r[38:7];
  wire         cmt_skip        = diffCommitBundle_r[6];
  wire         cmt_tlbfill_en  = diffCommitBundle_r[5];
  wire [4:0]   cmt_rand_index  = diffCommitBundle_r[4:0];
  wire [7:0]   cmt_wdest       = {3'b0, cmt_wdest_raw};

  wire         excp_valid      = diffStepValid_r && diffExcpBundle_r[129];
  wire         excp_eret       = diffExcpBundle_r[128];
  wire [31:0]  excp_intr       = diffExcpBundle_r[127:96];
  wire [31:0]  excp_cause      = diffExcpBundle_r[95:64];
  wire [31:0]  excp_pc         = diffExcpBundle_r[63:32];
  wire [31:0]  excp_inst       = diffExcpBundle_r[31:0];

  wire [7:0]   store_valid     = diffStepValid_r ? diffStoreBundle_r[199:192] : 8'b0;
  wire [63:0]  store_paddr     = diffStoreBundle_r[191:128];
  wire [63:0]  store_vaddr     = diffStoreBundle_r[127:64];
  wire [63:0]  store_data      = diffStoreBundle_r[63:0];

  wire [7:0]   load_valid      = diffStepValid_r ? diffLoadBundle_r[135:128] : 8'b0;
  wire [63:0]  load_paddr      = diffLoadBundle_r[127:64];
  wire [63:0]  load_vaddr      = diffLoadBundle_r[63:0];

  wire [31:0] csr_crmd         = diffCsrBundle_r[831:800];
  wire [31:0] csr_prmd         = diffCsrBundle_r[799:768];
  wire [31:0] csr_euen         = diffCsrBundle_r[767:736];
  wire [31:0] csr_ecfg         = diffCsrBundle_r[735:704];
  wire [31:0] csr_era          = diffCsrBundle_r[703:672];
  wire [31:0] csr_badv         = diffCsrBundle_r[671:640];
  wire [31:0] csr_eentry       = diffCsrBundle_r[639:608];
  wire [31:0] csr_tlbidx       = diffCsrBundle_r[607:576];
  wire [31:0] csr_tlbehi       = diffCsrBundle_r[575:544];
  wire [31:0] csr_tlbelo0      = diffCsrBundle_r[543:512];
  wire [31:0] csr_tlbelo1      = diffCsrBundle_r[511:480];
  wire [31:0] csr_asid         = diffCsrBundle_r[479:448];
  wire [31:0] csr_pgdl         = diffCsrBundle_r[447:416];
  wire [31:0] csr_pgdh         = diffCsrBundle_r[415:384];
  wire [31:0] csr_save0        = diffCsrBundle_r[383:352];
  wire [31:0] csr_save1        = diffCsrBundle_r[351:320];
  wire [31:0] csr_save2        = diffCsrBundle_r[319:288];
  wire [31:0] csr_save3        = diffCsrBundle_r[287:256];
  wire [31:0] csr_tid          = diffCsrBundle_r[255:224];
  wire [31:0] csr_tcfg         = diffCsrBundle_r[223:192];
  wire [31:0] csr_tval         = diffCsrBundle_r[191:160];
  wire [31:0] csr_llbctl       = diffCsrBundle_r[159:128];
  wire [31:0] csr_tlbrentry    = diffCsrBundle_r[127:96];
  wire [31:0] csr_dmw0         = diffCsrBundle_r[95:64];
  wire [31:0] csr_dmw1         = diffCsrBundle_r[63:32];
  wire [31:0] csr_estat        = diffCsrBundle_r[31:0];

  wire [31:0] gpr [0:31];
  assign gpr[0]  = diffRegsBundle_r[1023:992];
  assign gpr[1]  = diffRegsBundle_r[991:960];
  assign gpr[2]  = diffRegsBundle_r[959:928];
  assign gpr[3]  = diffRegsBundle_r[927:896];
  assign gpr[4]  = diffRegsBundle_r[895:864];
  assign gpr[5]  = diffRegsBundle_r[863:832];
  assign gpr[6]  = diffRegsBundle_r[831:800];
  assign gpr[7]  = diffRegsBundle_r[799:768];
  assign gpr[8]  = diffRegsBundle_r[767:736];
  assign gpr[9]  = diffRegsBundle_r[735:704];
  assign gpr[10] = diffRegsBundle_r[703:672];
  assign gpr[11] = diffRegsBundle_r[671:640];
  assign gpr[12] = diffRegsBundle_r[639:608];
  assign gpr[13] = diffRegsBundle_r[607:576];
  assign gpr[14] = diffRegsBundle_r[575:544];
  assign gpr[15] = diffRegsBundle_r[543:512];
  assign gpr[16] = diffRegsBundle_r[511:480];
  assign gpr[17] = diffRegsBundle_r[479:448];
  assign gpr[18] = diffRegsBundle_r[447:416];
  assign gpr[19] = diffRegsBundle_r[415:384];
  assign gpr[20] = diffRegsBundle_r[383:352];
  assign gpr[21] = diffRegsBundle_r[351:320];
  assign gpr[22] = diffRegsBundle_r[319:288];
  assign gpr[23] = diffRegsBundle_r[287:256];
  assign gpr[24] = diffRegsBundle_r[255:224];
  assign gpr[25] = diffRegsBundle_r[223:192];
  assign gpr[26] = diffRegsBundle_r[191:160];
  assign gpr[27] = diffRegsBundle_r[159:128];
  assign gpr[28] = diffRegsBundle_r[127:96];
  assign gpr[29] = diffRegsBundle_r[95:64];
  assign gpr[30] = diffRegsBundle_r[63:32];
  assign gpr[31] = diffRegsBundle_r[31:0];
  assign diffTraceDeq = diffTraceValid;

  always @(posedge aclk) begin
    if (reset) begin
      cycleCnt <= 64'b0;
      instrCnt <= 64'b0;
      diffStepValid_r <= 1'b0;
      diffCommitBundle_r <= 142'b0;
      diffRegsBundle_r <= 1024'b0;
      diffCsrBundle_r <= 832'b0;
      diffExcpBundle_r <= 130'b0;
      diffStoreBundle_r <= 200'b0;
      diffLoadBundle_r <= 136'b0;
    end else begin
      cycleCnt <= cycleCnt + 64'b1;
      diffStepValid_r <= diffTraceValid;
      if (diffTraceValid) begin
        diffCommitBundle_r <= diffCommitBundle;
        diffRegsBundle_r <= diffRegsBundle;
        diffCsrBundle_r <= diffCsrBundle;
        diffExcpBundle_r <= diffExcpBundle;
        diffStoreBundle_r <= diffStoreBundle;
        diffLoadBundle_r <= diffLoadBundle;
      end
      if (cmt_valid) begin
        instrCnt <= instrCnt + 64'b1;
      end
    end
  end

  DifftestInstrCommit DifftestInstrCommit(
    .clock              (aclk),
    .coreid             (0),
    .index              (0),
    .valid              (cmt_valid),
    .pc                 ({32'b0, cmt_pc}),
    .instr              (cmt_inst),
    .skip               (cmt_skip),
    .is_TLBFILL         (cmt_tlbfill_en),
    .TLBFILL_index      (cmt_rand_index),
    .is_CNTinst         (1'b0),
    .timer_64_value     (64'b0),
    .wen                (cmt_wen),
    .wdest              (cmt_wdest),
    .wdata              ({32'b0, cmt_wdata}),
    .csr_rstat          (1'b0),
    .csr_data           (32'b0)
  );

  DifftestExcpEvent DifftestExcpEvent(
    .clock              (aclk),
    .coreid             (0),
    .excp_valid         (excp_valid),
    .eret               (excp_eret),
    .intrNo             (excp_intr),
    .cause              (excp_cause),
    .exceptionPC        ({32'b0, excp_pc}),
    .exceptionInst      (excp_inst)
  );

  DifftestTrapEvent DifftestTrapEvent(
    .clock              (aclk),
    .coreid             (0),
    .valid              (1'b0),
    .code               (3'b0),
    .pc                 ({32'b0, cmt_pc}),
    .cycleCnt           (cycleCnt),
    .instrCnt           (instrCnt)
  );

  DifftestStoreEvent DifftestStoreEvent(
    .clock              (aclk),
    .coreid             (0),
    .index              (0),
    .valid              (store_valid),
    .storePAddr         (store_paddr),
    .storeVAddr         (store_vaddr),
    .storeData          (store_data)
  );

  DifftestLoadEvent DifftestLoadEvent(
    .clock              (aclk),
    .coreid             (0),
    .index              (0),
    .valid              (load_valid),
    .paddr              (load_paddr),
    .vaddr              (load_vaddr)
  );

  DifftestCSRRegState DifftestCSRRegState(
    .clock              (aclk),
    .coreid             (0),
    .crmd               ({32'b0, csr_crmd}),
    .prmd               ({32'b0, csr_prmd}),
    .euen               ({32'b0, csr_euen}),
    .ecfg               ({32'b0, csr_ecfg}),
    .estat              ({32'b0, csr_estat}),
    .era                ({32'b0, csr_era}),
    .badv               ({32'b0, csr_badv}),
    .eentry             ({32'b0, csr_eentry}),
    .tlbidx             ({32'b0, csr_tlbidx}),
    .tlbehi             ({32'b0, csr_tlbehi}),
    .tlbelo0            ({32'b0, csr_tlbelo0}),
    .tlbelo1            ({32'b0, csr_tlbelo1}),
    .asid               ({32'b0, csr_asid}),
    .pgdl               ({32'b0, csr_pgdl}),
    .pgdh               ({32'b0, csr_pgdh}),
    .save0              ({32'b0, csr_save0}),
    .save1              ({32'b0, csr_save1}),
    .save2              ({32'b0, csr_save2}),
    .save3              ({32'b0, csr_save3}),
    .tid                ({32'b0, csr_tid}),
    .tcfg               ({32'b0, csr_tcfg}),
    .tval               ({32'b0, csr_tval}),
    .ticlr              (64'b0),
    .llbctl             ({32'b0, csr_llbctl}),
    .tlbrentry          ({32'b0, csr_tlbrentry}),
    .dmw0               ({32'b0, csr_dmw0}),
    .dmw1               ({32'b0, csr_dmw1})
  );

  DifftestGRegState DifftestGRegState(
    .clock              (aclk),
    .coreid             (0),
    .gpr_0              ({32'b0, gpr[0]}),
    .gpr_1              ({32'b0, gpr[1]}),
    .gpr_2              ({32'b0, gpr[2]}),
    .gpr_3              ({32'b0, gpr[3]}),
    .gpr_4              ({32'b0, gpr[4]}),
    .gpr_5              ({32'b0, gpr[5]}),
    .gpr_6              ({32'b0, gpr[6]}),
    .gpr_7              ({32'b0, gpr[7]}),
    .gpr_8              ({32'b0, gpr[8]}),
    .gpr_9              ({32'b0, gpr[9]}),
    .gpr_10             ({32'b0, gpr[10]}),
    .gpr_11             ({32'b0, gpr[11]}),
    .gpr_12             ({32'b0, gpr[12]}),
    .gpr_13             ({32'b0, gpr[13]}),
    .gpr_14             ({32'b0, gpr[14]}),
    .gpr_15             ({32'b0, gpr[15]}),
    .gpr_16             ({32'b0, gpr[16]}),
    .gpr_17             ({32'b0, gpr[17]}),
    .gpr_18             ({32'b0, gpr[18]}),
    .gpr_19             ({32'b0, gpr[19]}),
    .gpr_20             ({32'b0, gpr[20]}),
    .gpr_21             ({32'b0, gpr[21]}),
    .gpr_22             ({32'b0, gpr[22]}),
    .gpr_23             ({32'b0, gpr[23]}),
    .gpr_24             ({32'b0, gpr[24]}),
    .gpr_25             ({32'b0, gpr[25]}),
    .gpr_26             ({32'b0, gpr[26]}),
    .gpr_27             ({32'b0, gpr[27]}),
    .gpr_28             ({32'b0, gpr[28]}),
    .gpr_29             ({32'b0, gpr[29]}),
    .gpr_30             ({32'b0, gpr[30]}),
    .gpr_31             ({32'b0, gpr[31]})
  );
`endif
"""
    extra_conn_ports = diff_conn_ports
    extra_conn = ""
    if extra_conn_ports:
        extra_conn = ",\n" + ",\n".join(f"    {port}" for port in extra_conn_ports)

    return f"""// Auto-generated by src/scripts/gen_axi_wrapper.py
// Do not edit this file manually.

module core_top
#(
  parameter TLBNUM   = 32,
  parameter START_PC = 32'h1c000000
)
(
    input           aclk,
    input           aresetn,
    input    [ 7:0] intrpt,
    output   [ 3:0] arid,
    output   [31:0] araddr,
    output   [ 7:0] arlen,
    output   [ 2:0] arsize,
    output   [ 1:0] arburst,
    output   [ 1:0] arlock,
    output   [ 3:0] arcache,
    output   [ 2:0] arprot,
    output          arvalid,
    input           arready,
    input    [ 3:0] rid,
    input    [31:0] rdata,
    input    [ 1:0] rresp,
    input           rlast,
    input           rvalid,
    output          rready,
    output   [ 3:0] awid,
    output   [31:0] awaddr,
    output   [ 7:0] awlen,
    output   [ 2:0] awsize,
    output   [ 1:0] awburst,
    output   [ 1:0] awlock,
    output   [ 3:0] awcache,
    output   [ 2:0] awprot,
    output          awvalid,
    input           awready,
    output   [ 3:0] wid,
    output   [31:0] wdata,
    output   [ 3:0] wstrb,
    output          wlast,
    output          wvalid,
    input           wready,
    input    [ 3:0] bid,
    input    [ 1:0] bresp,
    input           bvalid,
    output          bready,
    input           break_point,
    input           infor_flag,
    input  [ 4:0]   reg_num,
    output          ws_valid,
    output [31:0]   rf_rdata,
    output [31:0] debug0_wb_pc,
    output [ 3:0] debug0_wb_rf_wen,
    output [ 4:0] debug0_wb_rf_wnum,
    output [31:0] debug0_wb_rf_wdata,
    output [31:0] debug0_wb_inst
);

  wire        core_rdAddrValid;
  wire [44:0] core_rdAddr;
  wire        core_rdAddrRdy;
  wire        core_rdDataRdy;
  wire        core_wrAddrValid;
  wire [44:0] core_wrAddr;
  wire        core_wrAddrRdy;
  wire        core_wrDataValid;
  wire [36:0] core_wrData;
  wire        core_wrDataRdy;
  wire        core_wrRespRdy;
  wire        rdAddrValidRdy;
  wire        wrAddrValidRdy;
  wire        wrDataValidRdy;

  reg reset;

  always @(posedge aclk) begin
    reset <= ~aresetn;
  end
  wire [34:0] core_rdData = {{rdata, rresp, rlast}};
{diff_decl}
  mkCoreAxiTop u_core (
    .CLK                (aclk),
    .RST_N              (reset),
    .axiMem_rdAddrValid (core_rdAddrValid),
    .RDY_axiMem_rdAddrValid (rdAddrValidRdy),
    .axiMem_rdAddr      (core_rdAddr),
    .EN_axiMem_rdAddr   (core_rdAddrValid && arready),
    .RDY_axiMem_rdAddr  (core_rdAddrRdy),
    .axiMem_rdData_d    (core_rdData),
    .EN_axiMem_rdData   (rvalid && core_rdDataRdy),
    .RDY_axiMem_rdData  (core_rdDataRdy),
    .axiMem_wrAddrValid (core_wrAddrValid),
    .RDY_axiMem_wrAddrValid (wrAddrValidRdy),
    .axiMem_wrAddr      (core_wrAddr),
    .EN_axiMem_wrAddr   (core_wrAddrValid && awready),
    .RDY_axiMem_wrAddr  (core_wrAddrRdy),
    .axiMem_wrDataValid (core_wrDataValid),
    .RDY_axiMem_wrDataValid (wrDataValidRdy),
    .axiMem_wrData      (core_wrData),
    .EN_axiMem_wrData   (core_wrDataValid && wready),
    .RDY_axiMem_wrData  (core_wrDataRdy),
    .axiMem_wrResp_r    (bresp),
    .EN_axiMem_wrResp   (bvalid && core_wrRespRdy),
    .RDY_axiMem_wrResp  (core_wrRespRdy),
    .break_point        (break_point),
    .infor_flag         (infor_flag),
    .reg_num            (reg_num),
    .ws_valid           (ws_valid),
    .rf_rdata           (rf_rdata),
    .debug0_wb_pc       (debug0_wb_pc),
    .debug0_wb_rf_wen   (debug0_wb_rf_wen),
    .debug0_wb_rf_wnum  (debug0_wb_rf_wnum),
    .debug0_wb_rf_wdata (debug0_wb_rf_wdata),
    .debug0_wb_inst     (debug0_wb_inst){extra_conn}
  );

  assign arid    = 4'b0;
  assign araddr  = core_rdAddr[44:13];
  assign arlen   = core_rdAddr[12:5];
  assign arsize  = core_rdAddr[4:2];
  assign arburst = core_rdAddr[1:0];
  assign arlock  = 2'b0;
  assign arcache = 4'b0;
  assign arprot  = 3'b0;
  assign arvalid = core_rdAddrValid;
  assign rready  = core_rdDataRdy;

  assign awid    = 4'b0;
  assign awaddr  = core_wrAddr[44:13];
  assign awlen   = core_wrAddr[12:5];
  assign awsize  = core_wrAddr[4:2];
  assign awburst = core_wrAddr[1:0];
  assign awlock  = 2'b0;
  assign awcache = 4'b0;
  assign awprot  = 3'b0;
  assign awvalid = core_wrAddrValid;

  assign wid     = 4'b0;
  assign wdata   = core_wrData[36:5];
  assign wstrb   = core_wrData[4:1];
  assign wlast   = core_wrData[0];
  assign wvalid  = core_wrDataValid;
  assign bready  = core_wrRespRdy;

{diff_logic}
  wire _unused_ok = &{{1'b0, intrpt, rid, bid,
                       core_rdAddrRdy, core_wrAddrRdy, core_wrDataRdy,
                       rdAddrValidRdy, wrAddrValidRdy, wrDataValidRdy}};

endmodule
"""


def main() -> None:
    root = repo_root()
    mk_core_axi_top_v = root / "src" / "build" / "verilog" / "mkCoreAxiTop.v"
    output_v = root / "chiplab" / "IP" / "myCPU" / "mycpu_top.v"

    if not mk_core_axi_top_v.exists():
        raise FileNotFoundError(f"Input not found: {mk_core_axi_top_v}")

    text = mk_core_axi_top_v.read_text(encoding="utf-8", errors="ignore")
    require_ports(
        text,
        [
            "module mkCoreAxiTop(",
            "axiMem_rdAddr",
            "axiMem_wrAddr",
            "axiMem_wrData",
            "axiMem_rdData_d",
            "axiMem_wrResp_r",
        ],
    )

    enable_difftest = has_all_ports(text, DIFF_PORTS)
    wrapper = render_wrapper(enable_difftest)
    output_v.write_text(wrapper, encoding="utf-8")

    print(f"Generated: {output_v}")
    print(f"Difftest bridge: {'enabled' if enable_difftest else 'disabled'}")


if __name__ == "__main__":
    main()
