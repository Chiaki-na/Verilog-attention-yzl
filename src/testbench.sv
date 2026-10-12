`timescale 1ns/1ns
module tb ();
parameter S = 8;
parameter d = 4;
reg clk;
reg rst_n;
reg start;
reg signed [7:0] q_in,k_in,v_in;
reg q_valid,kv_valid;
wire data_ready;
wire signed [7:0] out_data;
wire out_valid,done;
wire [3:0] state_now;
reg [7:0] q_mem [0:d-1];
reg [7:0] k_mem [0:S*d-1];
reg [7:0] v_mem [0:S*d-1];
wire [S-1:0] key;
attention_ip #(.S(S),.d(d)) u1(
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .q_in(q_in),
    .k_in(k_in),
    .v_in(v_in),
    .q_valid(q_valid),
    .kv_valid(kv_valid),
    .data_ready(data_ready),
    .out_data(out_data),
    .out_valid(out_valid),
    .done(done),
    .state_now(state_now),
    .key(key)
);

initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
end

initial begin
    integer i;
    integer j;
    rst_n = 1'b0;
    q_in = 8'b0;
    k_in = 8'b0;
    v_in = 8'b0;
    start = 1'b0;
    q_valid = 1'b0;
    kv_valid = 1'b0;
    $readmemh("q_mem.hex",q_mem);
    $readmemh("k_mem.hex",k_mem);
    $readmemh("v_mem.hex",v_mem);
    #20
    rst_n = 1'b1;
    #10
    start = 1'b1;
    #10
    start = 1'b0;
    q_valid = 1'b1;
    for (i=0;i<d;i=i+1) begin
        q_in = q_mem[i];
        #10;
    end
    q_valid = 1'b0;
    kv_valid = 1'b1;
    for (j=0;j<S*d;j=j+1) begin
        k_in = k_mem[j];
        v_in = v_mem[j];
        #10;
    end
    kv_valid = 1'b0;
    wait(done == 1'b1);
    #10
    $finish;
        
end
initial begin
    $dumpfile("wave.vcd");
    $dumpvars(0,tb);
end
endmodule
