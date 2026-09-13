.text
        .globl main

main:
        # [Initialization]
        addi x10, x0, 0          # baseA
        addi x11, x0, 256        # baseB
        addi x12, x0, 512        # baseC
        addi x13, x0, 768        # STATUS

        add x24, x10, x0
        addi x9, x0, 255         # Mask (0xFF)
        
        addi x18, x0, 8          # i_count
        add  x20, x12, x0        # Row C Base (Start)

loop_i:
        # ==========================================================
        # 1. LOAD ROW A (Reuse for entire J loop)
        # Registers: x3~x8, x14, x15 (Total 8)
        # ==========================================================

        addi x23, x0, 8
        add x26, x11, x0

        lw   x3,  0(x24)
        lw   x4,  4(x24)
        lw   x5,  8(x24)
        lw   x6,  12(x24)
        lw   x7,  16(x24)
        lw   x8,  20(x24)
        lw   x14, 24(x24)
        lw   x15, 28(x24)

        # MASK A
        #and  x3,  x3,  x9
        #and  x4,  x4,  x9
        #and  x5,  x5,  x9
        #and  x6,  x6,  x9
        #and  x7,  x7,  x9
        #and  x8,  x8,  x9
        #and  x14, x14, x9
        #and  x15, x15, x9

        add  x25, x20, x0        # Ptr C (Current Row Start)

loop_j:
        # ==========================================================
        # 2. LOAD COL B (Fully Unrolled)
        # Registers: x16, x17, x19, x21, x22, x27, x29, x31 (Total 8)
        # Stride(32)는 lw의 offset으로 직접 처리
        # ==========================================================
        lw   x16, 0(x26)         # B[0]
        lw   x17, 32(x26)        # B[1]
        lw   x19, 64(x26)        # B[2]
        lw   x21, 96(x26)        # B[3]
        lw   x22, 128(x26)       # B[4]
        lw   x27, 160(x26)       # B[5]
        lw   x29, 192(x26)       # B[6]
        lw   x31, 224(x26)       # B[7]

        # MASK B
        #and  x16, x16, x9
        #and  x17, x17, x9
        #and  x19, x19, x9
        #and  x21, x21, x9
        #and  x22, x22, x9
        #and  x27, x27, x9
        #and  x29, x29, x9
        #and  x31, x31, x9

        # ==========================================================
        # 3. MULTIPLY (A fixed * B col) -> Overwrite B regs
        # ==========================================================
        mul  x16, x3,  x16       # P0
        mul  x17, x4,  x17       # P1
        mul  x19, x5,  x19       # P2
        mul  x21, x6,  x21       # P3
        mul  x22, x7,  x22       # P4
        mul  x27, x8,  x27       # P5
        mul  x29, x14, x29       # P6
        mul  x31, x15, x31       # P7

        # ==========================================================
        # 4. TREE ADDER (Interleaved for 3-Cycle Gap)
        # ==========================================================
        
        # [Level 1] 8 -> 4
        add  x16, x16, x17       # S0 = P0 + P1
        add  x19, x19, x21       # S1 = P2 + P3
        add  x22, x22, x27       # S2 = P4 + P5
        add  x29, x29, x31       # S3 = P6 + P7
        
        # [Gap Fillers] 
        # 다음 단계에서 x16, x19, x22, x29를 읽어야 하므로 3 cycle 대기
        addi x26, x26, 4         # Ptr B++ (Next Column)
        addi x25, x25, 4         # Ptr C++ (Next Cell)
        
        # [Level 2] 4 -> 2
        add  x16, x16, x19       # SS0 = S0 + S1 (Writes x16)
        add  x22, x22, x29       # SS1 = S2 + S3 (Writes x22)
        
        # [Gap Fillers]
        # 다음 단계에서 x16, x22를 읽어야 하므로 3 cycle 대기
        addi x23, x23, -1        # j_count--
        addi x0, x0, 0           # NOP
        addi x0, x0, 0           # NOP
        
        # [Level 3] 2 -> 1
        add  x16, x16, x22       # Final Sum (Writes x16)
        addi x0, x0, 0
        addi x0, x0, 0
        addi x0, x0, 0
        # ==========================================================
        # 5. STORE & CONTROL (beq/jal)
        # ==========================================================
        
        # [Gap Fillers & Store]
        # x16 쓰기 완료 대기 (3 cycle 필요)
        # Ptr C(x25)는 Level 1 Gap Filler에서 이미 +4 되었음.
        # 따라서 현재 위치는 -4(x25)임.
        sw   x16, -4(x25)        # Store C[i][j] (Reads x16: Safe)
        
        # J Loop Check
        # x23(j_count)은 Level 2 Gap Filler에서 업데이트됨 (4 cycle 지남). Safe.
        beq  x23, x0, done_j
        jal  x0,  loop_j

done_j:
        # I Loop Update
        addi x18, x18, -1        # i_count--
        addi x24, x24, 32        # Ptr A += 32 (Next Row)
        addi x20, x20, 32        # Row C Base += 32
        
        # I Loop Check
        # Gap: addi x24, addi x20 -> 2 cycles passed. Need 1 NOP.
        addi x0, x0, 0
        beq  x18, x0, done_i
        jal  x0,  loop_i

done_i:
        # Final Status
        addi x2,  x0, 1
        addi x0, x0, 0
        addi x0, x0, 0
        addi x0, x0, 0
        sw   x2,  0(x13)

done:
        beq  x0,  x0, done