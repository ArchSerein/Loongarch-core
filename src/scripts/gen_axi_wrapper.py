#!/usr/bin/env python3
"""
Generate a wrapper module to adapt mkCoreAxiTop AXI signals to standard AXI4 interface.
"""

import re
import sys

MK_CORE_AXI_TOP_V = '/root/Loongarch-core/src/build/verilog/mkCoreAxiTop.v'
OUTPUT_V = '/root/Loongarch-core/src/build/verilog/mkCoreAxiTop_wrapper.v'

AXI_BUNDLED_SIGNALS = {
    'araddr': {'width': 45, 'split': [
        ('arid', 44, 41),
        ('araddr', 40, 9),
        ('arlen', 8, 1),
    ]},
    'awaddr': {'width': 45, 'split': [
        ('awid', 44, 41),
        ('awaddr', 40, 9),
        ('awlen', 8, 1),
    ]},
    'wdata': {'width': 37, 'split': [
        ('wdata', 36, 5),
        ('wstrb', 4, 1),
        ('wlast', 0, 0),
    ]},
}

STANDARD_AXI_SIGNALS = [
    ('input', '', 'clk', 'Clock'),
    ('input', '', 'reset', 'Reset (active high)'),
    ('input', '[31:0]', 'intrpt', 'Interrupt'),
    ('input', '', 'intrpt_en', 'Interrupt enable'),
    ('output', '', 'hostToCpu_rdy', 'Host to CPU ready'),
    ('output', '[17:0]', 'cpuToHost', 'CPU to host data'),
    ('output', '', 'cpuToHostValid', 'CPU to host valid'),
    ('input', '', 'cpuToHost_rdy', 'CPU to host ready'),
    ('input', '', 'cpuToHostValid_rdy', 'CPU to host valid ready'),
    ('input', '', 'EN_cpuToHost', 'Enable CPU to host'),
    ('output', '[101:0]', 'debug_commit', 'Debug commit'),
    ('output', '', 'debug_commitValid', 'Debug commit valid'),
    ('input', '', 'debug_commit_rdy', 'Debug commit ready'),
    ('input', '', 'debug_commitValid_rdy', 'Debug commit valid ready'),
    ('input', '', 'EN_debug_commit', 'Enable debug commit'),
    ('', '', '', ''),
    ('output', '[3:0]', 'arid', 'AXI Read ID'),
    ('output', '[31:0]', 'araddr', 'AXI Read Address'),
    ('output', '[7:0]', 'arlen', 'AXI Read Length'),
    ('output', '[2:0]', 'arsize', 'AXI Read Size'),
    ('output', '[1:0]', 'arburst', 'AXI Read Burst'),
    ('output', '[1:0]', 'arlock', 'AXI Read Lock'),
    ('output', '[3:0]', 'arcache', 'AXI Read Cache'),
    ('output', '[2:0]', 'arprot', 'AXI Read Protection'),
    ('output', '', 'arvalid', 'AXI Read Valid'),
    ('input', '', 'arready', 'AXI Read Ready'),
    ('', '', '', ''),
    ('input', '[3:0]', 'rid', 'AXI Read Response ID'),
    ('input', '[31:0]', 'rdata', 'AXI Read Data'),
    ('input', '[1:0]', 'rresp', 'AXI Read Response'),
    ('input', '', 'rlast', 'AXI Read Last'),
    ('input', '', 'rvalid', 'AXI Read Valid'),
    ('output', '', 'rready', 'AXI Read Ready'),
    ('', '', '', ''),
    ('output', '[3:0]', 'awid', 'AXI Write ID'),
    ('output', '[31:0]', 'awaddr', 'AXI Write Address'),
    ('output', '[7:0]', 'awlen', 'AXI Write Length'),
    ('output', '[2:0]', 'awsize', 'AXI Write Size'),
    ('output', '[1:0]', 'awburst', 'AXI Write Burst'),
    ('output', '[1:0]', 'awlock', 'AXI Write Lock'),
    ('output', '[3:0]', 'awcache', 'AXI Write Cache'),
    ('output', '[2:0]', 'awprot', 'AXI Write Protection'),
    ('output', '', 'awvalid', 'AXI Write Valid'),
    ('input', '', 'awready', 'AXI Write Ready'),
    ('', '', '', ''),
    ('output', '[3:0]', 'wid', 'AXI Write Data ID'),
    ('output', '[31:0]', 'wdata', 'AXI Write Data'),
    ('output', '[3:0]', 'wstrb', 'AXI Write Strobe'),
    ('output', '', 'wlast', 'AXI Write Last'),
    ('output', '', 'wvalid', 'AXI Write Valid'),
    ('input', '', 'wready', 'AXI Write Ready'),
    ('', '', '', ''),
    ('input', '[3:0]', 'bid', 'AXI Write Response ID'),
    ('input', '[1:0]', 'bresp', 'AXI Write Response'),
    ('input', '', 'bvalid', 'AXI Write Response Valid'),
    ('output', '', 'bready', 'AXI Write Response Ready'),
]

PORT_MAPPING = {
    'CLK': 'clk',
    'RST_N': 'reset',
    'hostToCpu_startpc': 'intrpt',
    'EN_hostToCpu': 'intrpt_en',
    'RDY_hostToCpu': 'hostToCpu_rdy',
    'cpuToHost': 'cpuToHost',
    'cpuToHostValid': 'cpuToHostValid',
    'RDY_cpuToHost': 'cpuToHost_rdy',
    'RDY_cpuToHostValid': 'cpuToHostValid_rdy',
    'EN_cpuToHost': 'EN_cpuToHost',
    'axiMem_rdAddrValid': 'arvalid',
    'RDY_axiMem_rdAddrValid': 'arready',
    'EN_axiMem_rdAddr': 'EN_araddr',
    'axiMem_rdAddr': 'araddr_bundled',
    'RDY_axiMem_rdAddr': 'araddr_rdy',
    'axiMem_rdData_d': 'rdata',
    'EN_axiMem_rdData': 'rready',
    'RDY_axiMem_rdData': 'rdata_rdy',
    'axiMem_wrAddrValid': 'awvalid',
    'RDY_axiMem_wrAddrValid': 'awready',
    'EN_axiMem_wrAddr': 'EN_awaddr',
    'axiMem_wrAddr': 'awaddr_bundled',
    'RDY_axiMem_wrAddr': 'awaddr_rdy',
    'axiMem_wrDataValid': 'wvalid',
    'RDY_axiMem_wrDataValid': 'wready',
    'EN_axiMem_wrData': 'EN_wdata',
    'axiMem_wrData': 'wdata_bundled',
    'RDY_axiMem_wrData': 'wdata_rdy',
    'axiMem_wrResp_r': 'bresp',
    'EN_axiMem_wrResp': 'bready',
    'RDY_axiMem_wrResp': 'bresp_rdy',
    'diffCommit': 'debug_commit',
    'diffCommitValid': 'debug_commitValid',
    'RDY_diffCommit': 'debug_commit_rdy',
    'RDY_diffCommitValid': 'debug_commitValid_rdy',
    'EN_diffCommit': 'EN_debug_commit',
}


def generate_wrapper():
    port_decls = []
    for direction, width, name, comment in STANDARD_AXI_SIGNALS:
        if name == '':
            port_decls.append('')
        elif direction == '':
            port_decls.append(f"    {name},")
        elif width:
            port_decls.append(f"    {direction:6s}  {width:8s} {name},")
        else:
            port_decls.append(f"    {direction:6s}            {name},")

    wrapper = f"""module mkCoreAxiTop_wrapper (
{chr(10).join(port_decls)}
);

    wire [44:0] araddr_bundled;
    wire [44:0] awaddr_bundled;
    wire [36:0] wdata_bundled;
    wire        arvalid_int, awvalid_int, wvalid_int;
    wire        arready_int, awready_int, wready_int;
    wire        bresp_int;

    mkCoreAxiTop u_core (
        .aclk                   (clk),
        .aresetn                (reset),

        .EN_cpuToHost           (EN_cpuToHost),
        .cpuToHost              (cpuToHost),
        .cpuToHost_rdy          (cpuToHost_rdy),

        .cpuToHostValid         (cpuToHostValid),
        .cpuToHostValid_rdy     (cpuToHostValid_rdy),

        .EN_debug_commit        (EN_debug_commit),
        .debug_commit           (debug_commit),
        .debug_commit_rdy       (debug_commit_rdy),

        .debug_commitValid      (debug_commitValid),
        .debug_commitValid_rdy  (debug_commitValid_rdy),

        .intrpt                 (intrpt),
        .intrpt_en              (intrpt_en),
        .hostToCpu_rdy         (hostToCpu_rdy),

        .arvalid                (arvalid_int),
        .arready                (arready),
        .araddr                (araddr_bundled),
        .araddr_rdy           (arready),

        .rdata                 (rdata),
        .rready                (rready),
        .rdata_rdy             (rvalid),

        .awvalid               (awvalid_int),
        .awready               (awready),
        .awaddr               (awaddr_bundled),
        .awaddr_rdy           (awready),

        .wvalid                (wvalid_int),
        .wready                (wready),
        .wdata                (wdata_bundled),
        .wdata_rdy            (wready),

        .bresp                (bresp_int),
        .bready               (bready),
        .bresp_rdy            (bvalid)
    );

    assign arid      = araddr_bundled[44:41];
    assign araddr    = araddr_bundled[40: 9];
    assign arlen     = araddr_bundled[ 8: 1];
    assign arsize    = {{1'b0, araddr_bundled[0]}};
    assign arburst   = 2'b01;
    assign arlock    = 2'b00;
    assign arcache   = 4'b0011;
    assign arprot    = 3'b000;
    assign arvalid   = arvalid_int;

    assign awid      = awaddr_bundled[44:41];
    assign awaddr    = awaddr_bundled[40: 9];
    assign awlen     = awaddr_bundled[ 8: 1];
    assign awsize    = {{1'b0, awaddr_bundled[0]}};
    assign awburst   = 2'b01;
    assign awlock    = 2'b00;
    assign awcache   = 4'b0011;
    assign awprot    = 3'b000;
    assign awvalid   = awvalid_int;

    assign wdata     = wdata_bundled[36: 5];
    assign wstrb     = wdata_bundled[ 4: 1];
    assign wlast     = wdata_bundled[ 0];
    assign wvalid    = wvalid_int;

    assign bresp     = bresp_int;

endmodule
"""
    return wrapper


def rename_original_core():
    """Rename signals in the original mkCoreAxiTop.v file."""
    with open(MK_CORE_AXI_TOP_V, 'r') as f:
        content = f.read()

    content = content.replace('module mkCoreAxiTop(CLK,\n\t\t    RST_N,', 
                              'module mkCoreAxiTop(clk,\n\t\t    reset,')

    for old_name, new_name in PORT_MAPPING.items():
        content = re.sub(r'\b' + re.escape(old_name) + r'\b', new_name, content)

    content = content.replace('input  CLK;', 'input  clk;')
    content = content.replace('input  RST_N;', 'input  reset;')

    return content


def main():
    print("Step 1: Generating mkCoreAxiTop_wrapper.v...")
    wrapper = generate_wrapper()
    with open(OUTPUT_V, 'w') as f:
        f.write(wrapper)
    print(f"  Created: {OUTPUT_V}")

    print("\nStep 2: Generating renamed mkCoreAxiTop.v...")
    renamed_content = rename_original_core()
    renamed_path = '/root/Loongarch-core/src/build/verilog/mkCoreAxiTop_renamed.v'
    with open(renamed_path, 'w') as f:
        f.write(renamed_content)
    print(f"  Created: {renamed_path}")

    print("\nDone!")
    print(f"\nUse the wrapper as:")
    print(f"  mkCoreAxiTop_wrapper u_core (.*);")


if __name__ == '__main__':
    main()
