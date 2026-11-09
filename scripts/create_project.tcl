# =============================================================================
# create_project.tcl —— 一键把本仓库建成一个 Vivado 工程（用于看代码 / 仿真 / 看综合结构）
# =============================================================================
# 用法（二选一）：
#   1) Vivado GUI 的 Tcl Console 里：  cd <本仓库目录>  然后  source scripts/create_project.tcl
#   2) 命令行：  vivado -mode batch -source scripts/create_project.tcl
#
# 生成物：<本仓库>/kosmo_riscv/kosmo_rtl.xpr
#
# 注意：这里用的器件是 Artix-7 的 xc7a100tcsg324-1 做占位。
#   Vivado 器件库里没有紫光 PG2K100，所以这个工程只能用来：
#     * 看代码 / 跑仿真 / 看综合后的层次与资源
#     * 做时序估算（数字是 Artix-7 的，不是紫光板子的）
#   真正能烧到 Kosmo 板子上的位流，必须用 Pango Design Suite 生成。
# =============================================================================

# --- 0) 自动定位仓库根目录（脚本放在 scripts/ 下，所以取上一级）----------------
set here   [file normalize [file dirname [info script]]]
set root   [file normalize [file join $here ..]]
puts "REPO_ROOT = $root"

# --- 1) 器件（占位）----------------------------------------------------------
set PART "xc7a100tcsg324-1"

# --- 2) 建工程 ---------------------------------------------------------------
set proj_dir  [file join $root kosmo_riscv]
set proj_name kosmo_rtl
create_project $proj_name $proj_dir -part $PART -force

# --- 3) 加源文件 -------------------------------------------------------------
# 必须一个一个加：本仓库路径可能含空格，一次性传列表会被拆散
set rtl_files [glob -nocomplain [file join $root rtl *.sv]]
set rtl_v     [glob -nocomplain [file join $root rtl *.v]]
foreach f [concat $rtl_files $rtl_v] {
    add_files -norecurse $f
}

# --- 4) 加约束 ---------------------------------------------------------------
add_files -fileset constrs_1 -norecurse [file join $root constrs kosmo_pins.xdc]

# --- 5) 加仿真 testbench（放到 sim_1）---------------------------------------
add_files -fileset sim_1 -norecurse [file join $root sim tb.sv]
set_property file_type {Verilog} [get_files [file join $root sim tb.sv]]

# --- 6) 顶层 ----------------------------------------------------------------
set_property top top [get_filesets sources_1]
set_property top tb  [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "DONE. 工程已生成: [file join $proj_dir $proj_name.xpr]"
puts "下一步：打开工程后点 Run Synthesis，或直接 Run Simulation。"
