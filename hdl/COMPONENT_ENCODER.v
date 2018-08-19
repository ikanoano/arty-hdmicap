`default_nettype none
`timescale 1 ps / 1 ps

module COMPONENT_ENCODER #(
  parameter IS_Y      = 1,
  parameter DCT_TH    = 28
) (
  input   wire          clk,
  input   wire          rst,

  input   wire          page,

  input   wire          valid,
  input   wire[8-1:0]   pix,
  input   wire[8-1:0]   x_mcu,      // assign from -1 to h_mcu + 1
  input   wire[3-1:0]   y_in_mcu,
  input   wire[3-1:0]   x_in_mcu,
  input   wire          vsync,

  input   wire[8-1:0]   e_x_mcu,    // must be valid before ereq is asserted
  input   wire          ereq,
  output  reg [6-1:0]   elen,       // 0 <= ilength <= 32
  output  reg [32-1:0]  edata
);
localparam  SCALE     = 7;
localparam  DCTSHIFT  = SCALE + 2;
localparam  QSHIFTMIN = 3;
localparam  RSLTLEN   = 24 - DCTSHIFT - QSHIFTMIN;

// dct
reg [RSLTLEN-1:0] dct_results[0:DCT_TH-1];
generate genvar gi;
  for (gi = 0; gi < DCT_TH; gi = gi + 1) begin
    (* ram_style = "block" *)
    reg [24-1:0]  sum_acc[0:2*256-1];   // 2 page * 256 mcu

    wire[8-1:0] coscos; // signed
    DCT_COSTABLE #(gi, SCALE) cost (.r(y_in_mcu), .c(x_in_mcu), .o(coscos));

    reg [24-1:0]  memo, rmemo;
    wire[24-1:0]  P;
    wire          storeP, storeP_pre1;
    DSP dsp (
      .clk(clk),
      .load(x_in_mcu==0),
    //.clear(x_in_mcu==0 && y_in_mcu==0),
      .idelay(valid && x_in_mcu==7),  // to be storeP
      .A(pix),  // pix is level shifted in DSP by subtracting 128
      .B(coscos),
      .rrC(rmemo),
      .D(128),
      .P(P),
      .odelay_pre1(storeP_pre1),
      .odelay(storeP)
    );

    wire[8-1:0]   baseA = x_mcu + 1 - (storeP_pre1 ? 2 : 0);
    wire[8-1:0]   baseB = e_x_mcu;
    wire[9-1:0]   addrA = { page, baseA};
    wire[9-1:0]   addrB = {~page, baseB};
    reg [9-1:0]   raddrA;
    reg [24-1:0]  result;
    reg           clear;
    always @(posedge clk) begin
      raddrA  <= addrA;
      clear   <= y_in_mcu==0; // TODO: into dsp
      rmemo   <= clear ? 0 : memo;

      // port A
      memo <= sum_acc[raddrA];
      if(storeP) sum_acc[raddrA] <= P;

      // port B
      result <= sum_acc[addrB];
    end

    // rest of dct and quantize
    localparam  QSHIFT = IS_Y ? (
        gi<6  ? 3 : 4
      ) : (
        gi<1  ? 3 :
        gi<3  ? 4 :
        gi<6  ? 5 :
        gi<10 ? 6 : 7
      );
    always @(posedge clk) begin
      // add 1 if result < 0
      dct_results[gi] <= (result >>> (DCTSHIFT + QSHIFT)) + result[24-1];
    end

    // assertion
    initial if(QSHIFT<QSHIFTMIN) begin $display("invalid Q"); $finish(); end
    always @(posedge clk) if(valid && x_mcu>=253) begin
      $display("invalid x_mcu %x", x_mcu); $finish();
    end
    always @(posedge clk) if(valid && storeP && x_in_mcu==7) begin
      $display("bad timing to read memo"); $finish();
    end
  end
endgenerate



// huffman encoding
reg [21-1:0]  dc_huff[0:12-1];
reg [21-1:0]  ac_huff[0:256-1];
initial $readmemh(IS_Y ? "dc_y_huff.hex" : "dc_c_huff.hex", dc_huff, 0, 12-1);
initial $readmemh(IS_Y ? "ac_y_huff.hex" : "ac_c_huff.hex", ac_huff, 0, 256-1);

reg [ 6-1:0]  dct_idx;
reg           abort;
wire[ 8-1:0]  sq = dct_results[dct_idx];

reg [ 4-1:0]  bitlen[1:4];
reg [ 5-1:0]  runlen[0:4];
reg [ 9-1:0]  val[1:4];
reg           bsvalid[1:4];
reg           is_dc[0:4];

reg [ 5-1:0]  dc_huff_len,  ac_huff_len;
reg [16-1:0]  dc_huff_code, ac_huff_code;

wire          eob = runlen[1]==5'd16 || dct_idx==DCT_TH;
reg [ 8-1:0]  last_dc;
wire[ 8  :0]  ddc = $signed(sq) - $signed(last_dc);
always @(posedge clk) begin
  //NOTE: don't assert ereq more than 64 cycle
  if(!ereq) begin
    dct_idx   <= 0;           // reset
    abort     <= 0;           // reset
    runlen[0] <= 0;           // reset
    is_dc[0]  <= 1;           // only first cycle is dc part
  end else begin
    dct_idx   <= dct_idx+1;
    abort     <= eob | abort; // assert from the next cycle of eob processing
    runlen[0] <= is_dc[0] ? 0 : runlen[0] + (sq==0 ? 1 : 0);
    is_dc[0]  <= 0;
  end
  if(vsync)                   last_dc <= 0;
  else if(is_dc[0] && ereq)   last_dc <= sq;

  // cycle 0 - initialization for special conditions
  bitlen[1] <= eob ? 0 : ~0;  // set mask if eob
  runlen[1] <= eob ? 0 : runlen[0];
  val[1]    <= is_dc[0] ? $signed(ddc) : $signed(sq); // sub 1 if ddc|dq < 0
  bsvalid[1]<= ereq && (eob || is_dc[0] || (sq>0 && !abort)); // eob || dc || ac
  is_dc[1]  <= is_dc[0];

  // cycle 1 - convert val
  bitlen[2] <= bitlen[1];
  runlen[2] <= runlen[1];
  val[2]    <= val[1]-val[1][8];  // sub 1 if ddc|dq < 0
  bsvalid[2]<= bsvalid[1];
  is_dc[2]  <= is_dc[1];

  // cycle 2 - lookup BITLEN
  bitlen[3] <= bitlen[2] & BITLEN(val[2]);  // if eob, bitlen is masked to be 0
  runlen[3] <= runlen[2];
  val[3]    <= val[2];
  bsvalid[3]<= bsvalid[2];
  is_dc[3]  <= is_dc[2];

  // cycle 3 - lookup hufftable and mask val
  {dc_huff_len, dc_huff_code} <= dc_huff[bitlen[3]];
  {ac_huff_len, ac_huff_code} <= ac_huff[{runlen[3][0+:4],bitlen[3]}];
  bitlen[4] <= bitlen[3];
  runlen[4] <= runlen[3];
  val[4]    <= (val[3] & ~(~9'd0 << bitlen[3]));  // mask obstructive 1
  bsvalid[4]<= bsvalid[3];
  is_dc[4]  <= is_dc[3];

  // cycle 4 - output bitstream
  elen    <=  // huffman code length + value length
    !bsvalid[4] ? 6'd0 : bitlen[4] + (is_dc[4] ? dc_huff_len : ac_huff_len);
  edata   <=  // concatinate huffman code and value
    ((is_dc[4] ? dc_huff_code : ac_huff_code)
      << (bitlen[4][3] ? 8 : bitlen[4][2:0])) | val[4];
end


function[4-1:0] BITLEN (input [9-1:0] v);
  casex(v)
    9'b01xxxxxxx: BITLEN = 4'd8;
    9'b001xxxxxx: BITLEN = 4'd7;
    9'b0001xxxxx: BITLEN = 4'd6;
    9'b00001xxxx: BITLEN = 4'd5;
    9'b000001xxx: BITLEN = 4'd4;
    9'b0000001xx: BITLEN = 4'd3;
    9'b00000001x: BITLEN = 4'd2;
    9'b000000001: BITLEN = 4'd1;
    9'b000000000: BITLEN = 4'd0;
    9'b111111110: BITLEN = 4'd1;
    9'b11111110x: BITLEN = 4'd2;
    9'b1111110xx: BITLEN = 4'd3;
    9'b111110xxx: BITLEN = 4'd4;
    9'b11110xxxx: BITLEN = 4'd5;
    9'b1110xxxxx: BITLEN = 4'd6;
    9'b110xxxxxx: BITLEN = 4'd7;
    9'b10xxxxxxx: BITLEN = 4'd8;
  endcase
endfunction
endmodule

/*
module RAM #(
  parameter WIDTH = 24
) (
  input   wire            clk,

  input   wire[    8-1:0] addr1,
  output  reg [WIDTH-1:0] rdata1,

  input   wire[    8-1:0] addr2,
  output  reg [WIDTH-1:0] rdata2,
  input   wire            we2,
  input   wire[WIDTH-1:0] wdata2
);
reg [WIDTH-1:0] ram[0:256-1];

always @(posedge clk) begin
  rdata1  <= ram[addr1];
  rdata2  <= ram[addr2];
  if(we2) ram[addr2] <= wdata2;
end

endmodule
*/

module DCT_COSTABLE #(
  parameter DCT_IDX = 27,
  parameter SCALE   = 7
) (
  input   wire[3-1:0] r,
  input   wire[3-1:0] c,
  output  wire[8-1:0] o // signed
);
localparam real PI      = 3.141592653589793;

wire[8-1:0] tbl[0:64-1];
localparam  v = //y
  DCT_IDX< 0 ? 0          :
  DCT_IDX< 3 ? DCT_IDX-1  :
  DCT_IDX< 6 ? 5-DCT_IDX  :
  DCT_IDX<10 ? DCT_IDX-6  :
  DCT_IDX<15 ? 14-DCT_IDX :
  DCT_IDX<21 ? DCT_IDX-15 :
  DCT_IDX<28 ? 27-DCT_IDX :
  DCT_IDX<36 ? DCT_IDX-28 : 32'hxxxxxxxx;
localparam  u = //y
  DCT_IDX< 0 ? 0   :
  DCT_IDX< 3 ? 1-v :
  DCT_IDX< 6 ? 2-v :
  DCT_IDX<10 ? 3-v :
  DCT_IDX<15 ? 4-v :
  DCT_IDX<21 ? 5-v :
  DCT_IDX<28 ? 6-v :
  DCT_IDX<36 ? 7-v : 32'hxxxxxxxx;


generate genvar y,x;
  for (y = 0; y < 8; y = y + 1)
  for (x = 0; x < 8; x = x + 1) begin
    localparam  real    cos1 = COS_EXPR(v,y);
    localparam  real    cos2 = COS_EXPR(u,x);
    localparam  integer tmp =
      cos1 *
      cos2 *
      ( (|u && |v)  ? 1.0  :
        (|u || |v)  ? 1.0/1.41421356237 :
                      0.5 ) *
      (1 << SCALE);
    assign tbl[{y[0+:3], x[0+:3]}] = tmp;
  end
endgenerate

assign o = tbl[{r,c}];

//function[64-1:0] COS_EXPR (input [32-1:0] a, input [32-1:0] b);
//  COS_EXPR = $realtobits($cos(PI*(2*b+1)*a/16.0));  
// vivado doesn't know what cos is
//endfunction

//cos((x-16*floor((x+8)/16))*pi/16)*((-1)^floor((x+8)/16))
function real COS_EXPR(input integer a, input integer b);
  COS_EXPR = ((((GETX(a,b)+8)>>4)&1) ? -1.0 : 1.0) * COS((GETX(a,b)-16*((GETX(a,b)+8)>>4))*PI/16.0);
endfunction
function real COS (input real a);
  COS = 1.0
    - a**2 /(2)
    + a**4 /(4*3*2)
    - a**6 /(6*5*4*3*2)
    + a**8 /(8*7*6*5*4*3*2)
    - a**10/(10*9*8*7*6*5*4*3*2)
    + a**12/(12*11*10*9*8*7*6*5*4*3*2);
endfunction
function integer GETX(input integer a, input integer b);
  GETX = (2*b+1)*a;
endfunction

initial if(DCT_IDX>=36) begin $display("invalid DCT_IDX"); $finish(); end
endmodule

`default_nettype wire
