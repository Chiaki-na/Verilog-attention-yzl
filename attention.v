module attention_ip#(
    parameter S = 8,
    parameter d = 4
)(
input clk, rst_n, start,
input signed [7:0] q_in, k_in, v_in,
input q_valid, kv_valid,
output reg data_ready,
output reg signed [7:0] out_data,
output reg out_valid,done,
output reg [3:0] state_now,
output reg [S-1:0] key);

//s,d 自定义
localparam Sw = $clog2(S);
localparam dw = $clog2(d);
localparam W = 8;      
localparam SCORE_W = 2*W;          
localparam SCOREREG_W = 2*W + dw;    
localparam L_W = $clog2(S*16+1);
localparam ACC_W = 6 + W;      
localparam ACCREG_W = ACC_W + Sw; 

//状态机
localparam
    IDLE =4'h0,
    LOAD_Q=4'h1,
    LOAD_KV=4'h2,
    DOT=4'h3,
    MAX=4'h4,
    EXP=4'h5,
    UPDATE=4'h6,
    NORM=4'h7,
    OUTPUT=4'h8;
reg [3:0] state_next;
always @(posedge clk or negedge rst_n) begin//state_now比state_next慢一拍
    if (!rst_n)
        state_now <= IDLE;
    else
        state_now <= state_next;
end 
always @(*) begin
    done = 0;
    out_valid = 0;
    data_ready = 0;
    state_next = state_now;
    case(state_now)
        IDLE: begin
            if (start)
                state_next = LOAD_Q;
        end
        LOAD_Q: begin
            if (cnt_q == d-1)
                state_next = LOAD_KV;
                data_ready = 1;
        end
        LOAD_KV: begin
            if (cnt_kvi == d-1 && cnt_kvj == S-1)
                state_next = DOT;
                data_ready = 1;
        end
        DOT: begin
            if (cnt_sci == d-1 && cnt_scj == S-1)
                state_next = MAX;
        end
        MAX: begin
            if (MAX_finish == 1)
                state_next = EXP;
        end
        EXP: begin
            if (EXP_finish == 1)
                state_next = UPDATE;
        end
        UPDATE: begin
            if (UPDATE_finsih == 1)
                state_next = NORM;
        end
        NORM: begin
            if (NORM_finish == 1)
                state_next = OUTPUT;
        end
        OUTPUT: begin
            out_valid = 1;
            if (cnt_out == d-1) begin
                state_next = IDLE;
                done = 1;
            end
        end
    endcase
end

//load_q部分,连续四次装载q
reg signed [W-1:0] q_reg [0:d-1];
reg [dw-1:0] cnt_q;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        cnt_q <= 0;
    else
        if (q_valid) begin
            if (cnt_q == d-1)
                cnt_q <= 0;
            else
                cnt_q <= cnt_q + 1'b1;
        end
end

always @(posedge clk) begin
    if (q_valid) begin
        q_reg[cnt_q] <= q_in; 
    end
end

//load_kv,32个周期装完
reg signed [d*W-1:0] k_reg [0:S-1];
reg signed [d*W-1:0] v_reg [0:S-1];
reg [dw-1:0] cnt_kvi;
reg [Sw-1:0] cnt_kvj;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cnt_kvi <= 0;
        cnt_kvj <= 0;
    end
    else begin
        if (kv_valid) begin
            if (cnt_kvi == d-1) begin
                cnt_kvi <= 0;
                cnt_kvj <= cnt_kvj + 1'b1;
            end
            else begin
                cnt_kvi <= cnt_kvi + 1'b1;
            end
        end
    end
end
always @(posedge clk) begin
    if (kv_valid) begin
        k_reg[cnt_kvj][W*cnt_kvi +: W] <= k_in;
        v_reg[cnt_kvj][W*cnt_kvi +: W] <= v_in;
    end
end



//dot得到score
reg signed [SCORE_W-1:0] score;
reg signed [SCOREREG_W-1:0] score_reg [0:S-1];
always @(posedge clk or negedge rst_n) begin//给score累加寄存组做初始化
    if (!rst_n) begin
        integer i;
        for (i=0;i<S;i=i+1) begin
            score_reg[i] <= 16'b0;
        end
    end
end
reg score_valid;
reg [dw-1:0] cnt_sci;
reg [Sw-1:0] cnt_scj;
always @(*) begin
    if (state_now == DOT)
        score_valid = 1;
    else
        score_valid = 0;
end
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cnt_sci <= 0;
        cnt_scj <= 0;
    end
    else begin
        if (score_valid) begin
            if (cnt_sci == d-1) begin
                cnt_sci <= 0;
                cnt_scj <= cnt_scj + 1'b1;
            end
            else begin
                cnt_sci <= cnt_sci + 1'b1;
            end
        end
    end
end
always @(posedge clk) begin
    if (score_valid) begin
        score = q_reg[cnt_sci]*$signed(k_reg[cnt_scj][W*cnt_sci +: W]);
        score_reg[cnt_scj] <= score_reg[cnt_scj] + score;
    end
end

//max
reg signed [SCOREREG_W-1:0] max_1;
reg signed [SCOREREG_W-1:0] max_0;
always @(*) begin//组合逻辑「算」是瞬时的，只有「存」（寄存器）才发生在时钟沿
    integer i;
    max_1 = score_reg[0];
    if (state_now == MAX) begin//组合逻辑没有记忆，输入消失了数出一样消失
        for (i=0;i<S;i=i+1) begin
            if (score_reg[i] >= max_1)
                max_1 = score_reg[i];
        end
    end
end
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        max_0 <= 18'b0;
    end
    else if(state_now == MAX)begin
        max_0 <= max_1;
    end
end
reg signed [SCOREREG_W-1:0] x_max1 [0:S-1];
reg signed [SCOREREG_W-1:0] x_max0 [0:S-1];
reg MAX_finish;
always @(*) begin
    integer i;
    MAX_finish = 0;
    for (i=0;i<S;i=i+1) begin
        x_max1[i] = score_reg[i] - max_1;
        if (i==S-1) 
            MAX_finish = 1;
    end
end
always @(posedge clk or negedge rst_n) begin
    integer i;
    integer j;
    if (!rst_n) begin
        for (i=0;i<S;i=i+1)begin
            x_max0[i] <= 18'b0;
        end
    end
    else if(state_now == MAX)begin
        for (j=0;j<S;j=j+1)begin
            x_max0[j] <= x_max1[j];
        end
    end
end

//EXP
reg [4:0] weight [0:S-1];
reg EXP_finish;
always @(posedge clk or negedge rst_n) begin
    integer i;
    integer j;
    EXP_finish <= 0;
    if (!rst_n) begin
        for(j=0;j<S;j=j+1) begin
            weight[j] <= 5'b0;
        end
    end
    else if (state_now == EXP) begin
        for (i=0;i<S;i=i+1)begin
            case (x_max0[i])
                0:weight[i] <= 5'b10000;
                -1:weight[i] <= 5'b00110;
                -2:weight[i] <= 5'b00010;
                -3:weight[i] <= 5'b00001;
                default:weight[i] <= 5'b00000;
            endcase
            if (i==S-1)begin
                EXP_finish <= 1;
            end
        end
    end
end


//UPDATE
reg [L_W-1:0] L;
reg signed [d*ACC_W-1:0] ACC [0:S-1];
reg signed [d*ACCREG_W-1:0] ACC_reg;
always @(posedge clk or negedge rst_n) begin
    integer i;
    integer j;
    integer k;
    if (!rst_n) begin
        L <= 8'b0;
        ACC_vaild <= 0;
        for (j=0;j<S;j=j+1)begin
            ACC[j] <= 56'b0;
        end
    end
    else if(state_now == UPDATE && ACC_vaild == 0) begin
        ACC_vaild <= 1;
        for (i=0;i<S;i=i+1)begin
            L = L + {3'b0,weight[i]};//无符号乘以有符号的数为无符号的数
            for (k=0;k<d;k=k+1)begin
                ACC[i][ACC_W*k +: ACC_W] <= $signed(ACC[i][ACC_W*k +: ACC_W]) + $signed({1'b0,weight[i]}) * $signed(v_reg[i][W*k +: W]);
            end
        end
    end
end
reg ACC_vaild;
reg UPDATE_finsih;
always @(posedge clk or negedge rst_n) begin
    integer i;
    integer j;
    integer k;
    if (!rst_n) begin
        ACC_reg <= 64'b0;
        UPDATE_finsih <= 0;
    end
    else if (UPDATE_finsih == 0&&state_now == UPDATE) begin
        if (ACC_vaild == 1) begin
            UPDATE_finsih <= 1;
            for (i=0;i<d;i=i+1)begin
                for (j=0;j<S;j=j+1) begin
                    ACC_reg[ACCREG_W*i +: ACCREG_W] = $signed(ACC_reg[ACCREG_W*i +: ACCREG_W]) + $signed(ACC[j][ACC_W*i +: ACC_W]);
                end
            end
    end
end
end
reg [4:0] max_weight;
always @(*)begin
    integer i;
    max_weight = weight[0];
    if (state_now == UPDATE) begin
        for (i=0;i<S;i=i+1) begin
            if (weight[i]>max_weight)begin
                max_weight = weight[i];
            end
        end
    end
end
always @(posedge clk or negedge rst_n) begin
    integer i;
    if (!rst_n) begin
        key <= '0;
    end
    else if(state_now == UPDATE)begin
        for (i=0;i<S;i=i+1) begin
            if (weight[i] > (max_weight >> 1)) begin
                key[i] <= 1;
            end
            else begin
                key[i] <= 0;
            end
        end
    end
end

//NORM
reg signed [W-1:0] O [0:d-1];//乘以权重后又除以权重之和，位宽与v保持一致
reg signed [ACCREG_W:0] temp [0:d-1];
reg NORM_finish;
always @(*) begin
    integer i;
    for (i=0;i<d;i=i+1) begin
        if ($signed(ACC_reg[ACCREG_W*i +: ACCREG_W]) > 0)
            temp[i] = $signed(ACC_reg[ACCREG_W*i +: ACCREG_W]) + $signed((L >>> 1));
        else 
            temp[i] = $signed(ACC_reg[ACCREG_W*i +: ACCREG_W]) - $signed((L >>> 1));
    end
end
always @(posedge clk or negedge rst_n) begin
    integer i;
    integer j;
    if (!rst_n) begin
        for (i=0;i<d;i=i+1) begin
            O[i] <= 8'b0;
            NORM_finish <= 0;
        end
    end
    else if (state_now == NORM) begin
        for (j=0;j<d;j=j+1) begin
            O[j] <= temp[j] / $signed({1'b0,L});
        end
        NORM_finish <= 1;
    end
end

//output
reg [dw-1:0] cnt_out;
always @(posedge clk or negedge rst_n)begin
    if (!rst_n)
        cnt_out <= 0;
    else if (state_now == OUTPUT) begin
        if (cnt_out == d-1)
            cnt_out <= 0;
        else
            cnt_out <= cnt_out + 1'b1;
    end
end
always @(*) begin
    if(state_now == OUTPUT) begin
        out_data = O[cnt_out];
    end
end


endmodule 