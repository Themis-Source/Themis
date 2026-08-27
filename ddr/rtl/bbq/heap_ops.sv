`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/15/2025 01:57:49 PM
// Design Name: 
// Module Name: heap_ops
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
package heap_ops;

typedef enum logic [2:0] {
    HEAP_OP_ENQUE = 0,
    HEAP_OP_DEQUE_MIN,
    HEAP_OP_DEQUE_MAX,
    HEAP_OP_SWAP_IN,
    HEAP_OP_SWAP_OUT
} heap_op_t;

endpackage
