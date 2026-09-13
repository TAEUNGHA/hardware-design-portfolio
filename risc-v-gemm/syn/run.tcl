set TOPDESIGN RISCVSINGLE
set RTL_FILES [list "./../rtl/alu.v" \
        "./../rtl/REGFILE.v" \
	"./../rtl/EXTEND.v" \
        "./../rtl/MAINDEC.v" \
        "./../rtl/ALUDEC.v" \
        "./../rtl/PR_IF_ID.v" \
        "./../rtl/PR_ID_EX.v" \
        "./../rtl/PR_EX_MEM.v" \
        "./../rtl/PR_MEM_WB.v" \
        "./../rtl/DATAPATH.v" \
        "./../rtl/CONTROLLER.v" \
        "./../rtl/${TOPDESIGN}.v" \ ]
read_file -format verilog ${RTL_FILES}
current_design ${TOPDESIGN}
link
check_design
source ./sdc/RISC.sdc -verbose
check_timing
write_file -format ddc -output ./outputs/${TOPDESIGN}_unmapped.ddc
compile_ultra
ungroup -all -flatten
report_constraint -all_violators
write_file -format verilog -output ./outputs/${TOPDESIGN}_gate.v
write_file -format ddc -output ./outputs/${TOPDESIGN}_gate.ddc
write_sdf ./outputs/${TOPDESIGN}_gate.sdf
