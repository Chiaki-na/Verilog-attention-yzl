# Attention 加速器 IP 设计与验证

数字组招生考核 A 题。用 Verilog RTL 实现单头 Attention（softmax）加速器，配合 Python golden model 对照验证。

## 项目简介

- 规模：Batch=1，Head=1，Token 数 `S=8`，Head 维度 `d=4`
- 输入：`Q[1×4]`、`K[8×4]`、`V[8×4]`，均为 8-bit 有符号
- 输出：`O[1×4]`，8-bit 有符号；额外输出稀疏 `key` 掩码（加分项 D）
- 定点：weight 采用 **Q0.4**（4 个二进制小数位，即 ×16），指数用 LUT 查表
- 加分项：C 参数化（S/d 可配）、D 稀疏 Attention、E 指数方法综述、G [256,64] 规模分析

## 目录结构

```
.
├── src
│   └── attention.v          # RTL 顶层（参数化 S/d，9 状态状态机）
│   └── testbench.sv         # testbench
│   └── q_mem.hex            # Q 文档（十六进制）
│   └── k_mem.hex            # K 文档（十六进制）
│   └── v_mem.hex            # V 文档（十六进制）
├── doc/
│   └── report.pdf       # 设计报告（LaTeX）
│   └── slides.pptx      # ppt报告
└── README.md
```

## 依赖

| 工具 | 用途 | 备注 |
|------|------|------|
| iverilog | 编译 / 仿真 | 本机为 2015 老版（见下方「坑」） |
| vvp | 运行仿真 | 随 iverilog 附带 |
| GTKWave | 查看波形 | `wave.vcd` |
| Python 3 | 运行 golden model | 无第三方依赖 |
| XeLaTeX + ctex | 编译设计报告 | `doc/report.tex` |

## 快速开始

### 1. 跑 golden model（先得到期望输出）

```bash
python golden/golden.py      # 默认手算例 Q=[1,0,0,0] → O=[1,2,3,4]
python golden/golden.py 1    # 从键盘输入 Q/K/V
```

### 2. 编译 + 仿真

```bash
iverilog -g2012 -o sim/simv attention.v testbench.sv
vvp sim/simv
```

仿真结束时 `out_data` 依次输出 4 个结果，随后 `done=1`。

### 3. 看波形

```bash
gtkwave wave.vcd
```

## 接口说明

顶层模块 `attention_ip`：

```verilog
module attention_ip #(parameter S = 8, parameter d = 4)(
    input  clk, rst_n, start,
    input  signed [7:0] q_in, k_in, v_in,
    input  q_valid, kv_valid,
    output reg data_ready,
    output reg signed [7:0] out_data,
    output reg out_valid, done,
    output reg [3:0] state_now,       // 调试用：当前状态
    output reg [S-1:0] key            // 加分项 D：稀疏索引掩码
);
```

| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| `clk` / `rst_n` | in | 1 | 时钟 / 低有效复位 |
| `start` | in | 1 | 启动脉冲，IDLE 拉高进入 LOAD_Q |
| `q_in` / `k_in` / `v_in` | in | 8 | 数据输入，8-bit 有符号 |
| `q_valid` | in | 1 | Q 输入有效（拉高 d 拍灌入 Q） |
| `kv_valid` | in | 1 | K/V 输入有效（拉高 S×d 拍灌入 K、V） |
| `data_ready` | out | 1 | 输入握手（LOAD_Q/LOAD_KV 末拍拉高） |
| `out_data` | out | 8 | 输出结果，OUTPUT 状态逐拍给出 O[0..3] |
| `out_valid` | out | 1 | 输出有效 |
| `done` | out | 1 | 一次计算完成 |
| `state_now` | out | 4 | 当前状态（调试） |
| `key` | out | S | 稀疏掩码，第 j 位=1 表示 token j 入选 |

## 算法流程（软硬件一致）

```
1. score_j = Q · K_j          = Σ_k Q[k] × K[j][k]      （4 项点积）
2. x_max   = max(score_j)                                 （数值稳定，防 exp 溢出）
3. diff_j  = score_j − x_max                              （≤0 的整数）
4. weight_j = exp(diff_j) 的 Q0.4 定点（×16）查表
5. L       = Σ weight_j
6. ACC_i   = Σ_j weight_j × V[j][i]                       （4 路并行）
7. O_i     = round(ACC_i / L)                             （按符号四舍五入）
```

exp 查表（Q0.4，即 `weight = round(exp(diff)×16)`）：

| diff | 0 | −1 | −2 | −3 | ≤−4 |
|------|---|----|----|----|-----|
| weight | 16 (1.0000) | 6 (0.0110) | 2 (0.0010) | 1 (0.0001) | 0 |

> 关键结论：×16 倍率在 `O = round(ACC/L)` 中约掉（ACC、L 带同一倍率），最终输出对倍率不敏感。

## 测试数据

三份激励由 `$readmemh` 读入（十六进制，负数用 8-bit 补码）。

**用例 1（手算例，正数）**：`Q=[1,0,0,0]`，K 第一列 0~7 余 0，V 全 `[1,2,3,4]` → `score=[0..7]`、`x_max=7`、`weight=[0,0,0,0,1,2,6,16]`、`L=25`、`ACC=[25,50,75,100]`、**`O=[1,2,3,4]`**。

**用例 2（负数组）**：`Q=[1,0,0,0]`，K 第一列 `5,4,3,2,1,0,-1,-2`，V：token0=`[-2,-1,1,2]`、token1~3=`[1,1,1,1]`、token4~7=`[0,0,0,0]` → `score=[5,4,3,2,1,0,-1,-2]`、`weight=[16,6,2,1,0,0,0,0]`、`L=25`、`ACC=[-23,-7,25,41]`、**`O=[-1,0,1,2]`**、**`key=0000_0001`**（阈值 `16>>1=8`，仅 token0 入选）。

另有 4 组扩展用例均通过：参数化 `S=10,d=5`（O=[1,2,3,4,5]）、负数四舍五入边界（O=[-1,-1,-2,-2,-3]）、全同 `L=128`（O=[1,2,3,4]）、大 score 稀疏+负数输出（O=[11,24,-43,4]），汇总见报告「验证与仿真」一节。

## 加分项

- **C 参数化**：模块头 `parameter S=8, d=4`，位宽用 `localparam` 由 `$clog2` 推导；testbench 同步参数化并 `#(.S(S),.d(d))` 传参。维度计数器（`cnt_q/cnt_kvi/cnt_sci/cnt_out`）计数到 `d-1` 显式归零，支持任意（非 2 的幂）的 `d`。
- **D 稀疏 Attention**：`output reg [S-1:0] key` 掩码，阈值 `max_weight >> 1`（动态），仅保留 weight 超过阈值的 token。
- **E 指数实现方法综述**：对比 LUT / 分段线性 / 多项式 / CORDIC / 范围缩减+查表，说明本题选 LUT 的原因（`diff` 是整数、仅 4 档非零）。
- **G [256,64] 规模分析**：存储（K/V 各 16KB）、位宽（score 22bit、L 13bit）、计算量（约 3.3×10⁴ 次 MAC）、稀疏性，及「exp LUT 与规模无关」的结论。

## 编译「坑」（本机 iverilog 2015 老版）

- 二进制字面量 `'b` 里只允许 0/1/x/z，**2~9 数字非法**（`8'b2` 直接语法错），多位数要写 `8'h2` 或 `8'd2`。
- `localparam` 里的多进制常量建议用 `4'hN` 而非 `4'bN`。
- 编译命令加 `-g2012`：`iverilog -g2012 -o sim/simv attention.v testbench.sv`

  ## 已知问题 / TODO

- `NORM` 中的 `/`（`O = temp / L`）目前是仿真友好写法，除数 L 为变量**不可综合**，综合需换**倒数 LUT** 或除法器。
- 由于状态机需要将state_next赋给state_now，这个过程需要一拍，而在状态MAX,UPDATE,NORM中由于给state_next赋值下一个状态的时间不合理性，导致周期慢了一拍（在这一拍中RLT没有做任何事情），属于无效拍，需要改正
- qkv输入用$readmemh函数，但是S,d的修改还是在代码上面改，可对S,d也用$readmmh函数输入

> 已解决：`L=128` 溢出——NORM 已用 `{1'b0, L}` 扩到 9-bit，经测试用例 5（全同 L=128）验证正确。














