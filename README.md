# kosmo-riscv

一个从零手写的 **RISC-V (RV32I 子集) 五级流水 CPU**，跑在紫光同创 **PG2K100**（Kosmo2 开发板）上，用于「集成电路设计竞赛 · RISC-V 处理器设计」赛道。

- 语言：SystemVerilog / Verilog（纯 RTL，无 IP、无 Vivado 生成的核）
- 指令集：RV32I 的 24 条整数指令（竞赛要求全集），额外支持 `lb/lh/lbu/lhu`、`AUIPC`、`CSR` 系列
- 流水线：**经典五级** IF → ID → EX → MEM → WB，带旁路（forwarding）与 load-use 停顿
- 实测：跑自带的 45 条指令测试程序 **1605 个时钟周期**跑完，结果 `0x4e84` = 20100（正确），**CPI ≈ 1.07**
- 真实固件（2035 条指令）20 万周期仿真：`CPI = 1.073`、无跑飞、无非法地址
- 综合：Vivado 2023.2+ 综合通过，`LUT 3119 / FF 1687 / RAMB36 64`（含 64 KB 指令 ROM）
- 频率：紫光 PDS 实测 Fmax **75.3 / 110.1 / 130.8 MHz**（50 / 100 / 125 MHz 三版约束，全部时序收敛）

> 本仓库的 RTL 已经**逐行写了中文注释**，目标是「看得懂原理的人能照着复刻出来」，而不是只能跑的黑盒。

---

## 一、三分钟上手

### 方式 A：只想看结果（跑仿真，不需要建工程）

前提：本机装了 Vivado（默认路径 `D:\vivado\2025.2\Vivado\bin`，其它路径改下面第 1 步）。

```bat
cd sim
run_xsim.bat
```

看到下面两行就是成功：

```
RESULT_CYCLES=1604 DONEVAL=00004e84
TOTAL_CYCLES=1605 DRAM0=00004e84
```

- `TOTAL_CYCLES=1605`：从复位释放到程序跑完，一共 1605 个时钟周期
- `DONEVAL=00004e84`：程序把结果 20100（0x4e84）写到了 `0x8010_00F0`，测试平台捕获到就算 DONE
- `DRAM0=00004e84`：数据存储器第 0 个字的最终值

如果提示找不到 `xvlog.bat`，说明 Vivado 不在默认路径。把 `sim/run_xsim.bat` 里这一行改掉：

```bat
set VIVADO_BIN=D:\vivado\2025.2\Vivado\bin
```

### 方式 B：想在 Vivado 里看代码 / 看波形 / 看综合

Vivado 的 Tcl Console 里：

```tcl
cd /path/to/kosmo-riscv
source scripts/create_project.tcl
```

会生成 `kosmo_riscv/kosmo_rtl.xpr`，双击打开即可。然后：

- 看仿真：左侧 `Run Simulation` → `Run Behavioral Simulation`
- 看综合：左侧 `Run Synthesis`，跑完点 `Open Synthesized Design` → 左侧 `Schematic`
- 看资源：`Report Utilization`

> ⚠️ 工程里的器件是 **Artix-7 xc7a100tcsg324-1 占位**。Vivado 器件库里没有紫光 PG2K100。
> 所以这个工程**只能**看代码、跑仿真、看综合结构和时序估算 —— **出不了能烧到 Kosmo 板子上的位流**。

### 方式 C：要真位流（烧紫光板）

必须用 **Pango Design Suite（PDS）**，器件选 `PG2K100 - MBG400 - 速度等级 -6`：

```
create_project ... -synthesize_tool 2 -family Kosmo2 -device PG2K100 -package MBG400 -speedgrade -6
```

流程：`compile` → `synthesize` → `dev_map` → `place` → `route` → `route_optimize` → `gen_bit_stream`，产物是 `top.sbit`。
详细步骤见 [`docs/03_操作手册.md`](docs/03_操作手册.md)。

---

## 二、目录结构 & 每个文件是干什么的

```
kosmo-riscv/
├── README.md                  ← 你正在看的这份
├── docs/
│   ├── 01_五级流水详解.md       ← 流水线原理、逐拍时序、三条关键机制
│   ├── 02_模块逐个详解.md       ← 27 个文件逐个讲：作用/端口/内部结构/复刻要点
│   ├── 03_操作手册.md           ← 仿真、建工程、综合、出位流、烧板全流程
│   └── 04_踩坑记录.md           ← 开发中真实踩过的坑（含 Vivado/PDS/仿真器报错原文）
├── rtl/                       ← 全部 RTL 源码（27 个文件，带逐行中文注释）
├── constrs/
│   └── kosmo_pins.xdc         ← 引脚 + 时钟约束（Vivado 格式）
├── sim/
│   ├── tb.sv                  ← 仿真测试平台（模拟指令 ROM + 数据 RAM + 结果捕获）
│   ├── prog.hex               ← 测试程序机器码（$readmemh 读它）
│   ├── prog.s                 ← 同一程序的汇编源码（人看）
│   ├── asm.py                 ← 简陋的汇编器（改程序后重新生成 prog.hex）
│   └── run_xsim.bat           ← 一键跑仿真（xvlog → xelab → xsim）
└── scripts/
    └── create_project.tcl     ← 一键建 Vivado 工程
```

### 2.1 核心流水线（12 个文件）

| 文件 | 一句话职责 | 关键点 |
|---|---|---|
| `rtl/cpu_myCPU.sv` | **CPU 顶层**：只做连线，把五级串起来 | 所有级间寄存器的连接、`perip_rd_addr` 的取法都在这 |
| `rtl/cpu_IFU.sv` | **IF 级**：取指令、管 PC | `pc` 复位到 `0x8000_0000`；`snpc = pc+4`；四优先级更新 PC（复位/停顿/跳转/顺序） |
| `rtl/cpu_IDU.sv` | **ID 级**：译码 + 读寄存器 + 算立即数 | 最大的一块（219 行），opcode→控制信号全在这；`inv_flag` 是给 ALU 取反用的 |
| `rtl/cpu_IFID_EX_Reg.sv` | **ID/EX 流水寄存器** | 同时装 ID 的输出和 EX 的输入；被冲刷时控制信号必须清 0 |
| `rtl/cpu_EXU.sv` | **EX 级**：ALU 运算 + 分支判断 | `Ex_result = alu_result ^ inv_flag`（一条线搞定取反） |
| `rtl/cpu_ALU.sv` | ALU：11 种运算 | 预计算与/或/异或/移位，再用 `case` 选 |
| `rtl/cpu_add.sv` | 加减法器（ALU 内部用） | `sub` 时用 `~d2 + 1` 实现补码减法 |
| `rtl/cpu_sext.sv` | 符号扩展器（load 用） | `lb/lh` 要把 8/16 位符号扩展到 32 位 |
| `rtl/cpu_EX_LSWB_Reg.sv` | **EX/MEM 流水寄存器** | WB 级是纯组合，所以这是最后一级触发器 |
| `rtl/cpu_LSU.sv` | **MEM 级**：访存 | 字节/半字/字 + 符号/零扩展；地址和数据都是组合输出 |
| `rtl/cpu_WBU.sv` | **WB 级**：选写回值 | 跳转/CSR 优先 → load → ALU；`R_wen & valid` 防幽灵写回 |
| `rtl/cpu_Control.sv` | **控制中枢**：旁路、停顿、冲刷 | 全 CPU 的"交通警察"，纯组合，无状态 |

### 2.2 支撑模块（6 个文件）

| 文件 | 一句话职责 | 关键点 |
|---|---|---|
| `rtl/cpu_Data_hazard.sv` | 冒险检测：算出旁路选择码 | 输出 4 档码：00 原值 / 01 EX 结果 / 10 MEM 结果 / 11 load 数据 |
| `rtl/cpu_RegisterFile.sv` | 32×32 位寄存器堆 | 两个组合读口 + 一个同步写口；x0 双保险恒 0 |
| `rtl/cpu_Reg_Stack.sv` | 寄存器堆 + CSR 的打包壳 | ID 级只要例化它一个就够 |
| `rtl/cpu_CSR.sv` | CSR 寄存器组 | mepc/mcause/mstatus/mtvec + 两个只读 ID |
| `rtl/cpu_Reg.sv` | 通用带复位/使能的寄存器 | 流水寄存器都是用它的行为写的 |
| `rtl/cpu_para.sv` | 宏定义集合 | opcode、ALU 操作码，全项目共用 |

### 2.3 外设与板级（9 个文件）

| 文件 | 一句话职责 | 关键点 |
|---|---|---|
| `rtl/top.v` | **板级顶层**：CPU + ROM + DRAM + 外设 + 串口 | 复位同步、`ms_uart_tx` 每 0.5 秒发一帧毫秒值 |
| `rtl/IROM.v` | 指令 ROM（16 位地址、32 位宽） | 内部 `$readmemh` 初始化，综合成 BRAM |
| `rtl/DRAM.v` | 数据 RAM（16 位地址、32 位宽） | **1 拍寄存读** —— 这就是当年那个 bug 的源头 |
| `rtl/dram_driver.sv` | DRAM 的读写驱动（吞掉 1 拍延迟） | 读地址由 **EX 级**给出，写地址由 MEM 级给出 |
| `rtl/perip_bridge.sv` | 外设总线桥 + 地址译码 | DRAM/SW/KEY/SEG/LED/CNT 六个地址窗口 |
| `rtl/counter.sv` | 毫秒计数器 | 50 MHz 下数 50000 个周期 = 1 ms |
| `rtl/uart.sv` | 标准 UART 收发（115200 8N1） | 有半位对齐、三级同步，可复用 |
| `rtl/display_seg.sv` | 8 位数码管动态扫描 | 16 分频，两组四位轮流点亮 |
| `rtl/seg7.sv` | 七段译码查表 | 0~F 十六进制字形 |

---

## 三、五级流水长什么样

```
        ┌──────────┐   ┌──────────────┐   ┌──────────┐   ┌────────────────┐   ┌─────────┐
  PC ──►│   IFU    │──►│ IFID_EX_Reg  │──►│   EXU    │──►│ EX_LSWB_Reg    │──►│   WBU   │──► 写寄存器堆
        │ 取指     │   │ (ID/EX 寄存器)│   │ ALU/分支 │   │ (EX/MEM 寄存器) │   │ 选写回  │
        └──────────┘   └──────┬───────┘   └──────────┘   └───────┬────────┘   └─────────┘
                              │                                  │
                          ┌───▼────┐                        ┌────▼────┐
                          │  IDU   │◄── RegisterFile/CSR    │   LSU   │◄──► DRAM
                          │ 译码    │      (Reg_Stack)       │  访存    │
                          └────────┘                        └─────────┘
                              ▲
                          ┌───┴────────┐
                          │  Control   │  ← 旁路选择 / load-use 停顿 / 分支冲刷
                          └────────────┘
```

一条 `add x3, x3, x2` 在五级里各拍做什么：

| 拍 | IF | ID | EX | MEM | WB |
|---|---|---|---|---|---|
| 1 | 取 add | | | | |
| 2 | 取下一条 | 译码 add，读 x3/x2 | | | |
| 3 | 再取下一条 | … | ALU 算出结果 | | |
| 4 | … | … | … | 数据通路传下去 | |
| 5 | … | … | … | … | 结果写回 x3 |

理想情况每拍完成一条 → CPI ≈ 1。实测 1.07，多出来的 0.07 就是**分支冲刷**和 **load-use 停顿**的开销。

三条关键机制（详见 [`docs/01_五级流水详解.md`](docs/01_五级流水详解.md)）：

1. **旁路（forwarding）**：EX 要用的操作数可能还没写回寄存器堆，直接从 EX/MEM 的结果线拉过来。
   `cpu_Data_hazard.sv` 算出 4 档码，`cpu_Control.sv` 用它二选一。
2. **load-use 停顿**：`lw` 后紧跟用该数据的指令，必须停 1 拍。
   `stall_condition = EXU_mem_ren && (rs1_hazard || rs2_hazard)`。
3. **分支冲刷**：分支在 EX 级才判定，前面已经取进来的 2 条指令要作废。
   `dnpc_flag` 拉高 → IF 跳转 + 两级流水寄存器清 `valid`。

---

## 四、引脚与板卡（紫光 Kosmo2 / PG2K100-MBG400）

| 信号 | 引脚 | 说明 |
|---|---|---|
| `clk` | **T9** | 50 MHz 有源晶振 |
| `rst_n` | **W13** | BTN0，**低有效** |
| `led[0]` | G14 | LED0_4，低电平点亮 |
| `led[1]` | E18 | LED0_5，低电平点亮 |
| `led[2]` | E19 | LED0_6，低电平点亮 |
| `led[3]` | F16 | LED0_7，低电平点亮 |
| `led[4]` | F17 | LED0_0，低电平点亮 |
| `led[5]` | H18 | LED0_2，低电平点亮 |
| `led[6]` | E17 | LED0_3，低电平点亮 |
| `led[7]` | H15 | LED1_0，高电平点亮（**唯一高有效**） |
| `uart_tx` | **W6** | J8 排针第 23 脚，115200 8N1 |

约束文件 `constrs/kosmo_pins.xdc` 里已经写好，PDS 用的话转成 `.fdc` 即可（格式见 `docs/03`）。

> 板子手册两处矛盾：`Kosmo硬件手册_V1.1` 说 T9 是 50 MHz，`Kosmo2-MES2K100-实验指导手册` 的 LED 例程说 27 MHz。
> 如果实测计时偏慢 46%，把 `rtl/counter.sv` 里两处 `49999` 改成 `26999`（注释里标了位置）。

---

## 五、已知限制

1. **只实现了 RV32I 整数子集**：没有 `M`（乘除）、没有 `F/D`、没有压缩指令。
2. **异常只做了一半**：`cpu_CSR.sv` 有 mepc/mcause/mtvec 和陷入通路，但没有真正的中断/异常处理程序，`mtvec` 复位为 0，真异常会跳 0 死循环。
3. **没有 Cache**：指令和数据都直连 BRAM，靠 BRAM 本身的 1 拍延迟。
4. **DRAM 读是 1 拍寄存输出**，所以 `load` 必须在 MEM 级等一拍；我们的修法是把读地址提前到 EX 级给出（零成本），而不是加一个停顿拍。详见 `docs/04_踩坑记录.md` 第一条。
5. **Vivado 工程是占位器件**，只能看结构，出不了紫光位流。

---

## 六、性能数据（可复现）

| 项目 | 数值 | 怎么得到 |
|---|---|---|
| 测试程序周期数 | **1605** | `sim/run_xsim.bat` |
| CPI | **1.07** | 1605 ÷ 1500 条指令（实际 1496 条有效） |
| 真实固件 CPI | **1.073** | 20 万周期仿真（2035 条指令的固件） |
| load-use 停顿 | 6.8% | 同上 |
| 分支重定向 | 12.3% | 同上 |
| Fmax (50 MHz 约束) | 75.3 MHz | PDS `report_timing` |
| Fmax (100 MHz 约束) | 110.1 MHz | 同上 |
| Fmax (125 MHz 约束) | 130.8 MHz | 同上 |
| LUT / FF / RAMB36 | 3119 / 1687 / 64 | Vivado `report_utilization` |

三种频率下的实际用时（同一段程序周期数固定，时间只跟频率成反比）：

| 频率 | 相对 50 MHz | 若 50 MHz 用时 T |
|---|---|---|
| 50 MHz | 1.0× | T |
| 100 MHz | 2.0× | T / 2 |
| 125 MHz | 2.5× | T / 2.5 |

---

## 七、许可

仅用于学习与竞赛。代码为原创手写，未使用任何第三方 IP 核。
