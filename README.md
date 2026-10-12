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
├── attention.v          # RTL 顶层（参数化 S/d，9 状态状态机）
├── q_mem.hex            # Q 激励（十六进制）
├── k_mem.hex            # K 激励（十六进制）
├── v_mem.hex            # V 激励（十六进制）
├── doc/
│   └── report.pdf       # 设计报告（LaTeX）
│   └── slides.pptx      # ppt报告
└── README.md
```
