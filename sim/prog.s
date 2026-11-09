        lui   x1, 0x80100
        lui   x7, 0x80200
        addi  x2, x0, 200
        addi  x3, x0, 0
loop:
        add   x3, x3, x2
        lw    x5, x1, 0
        sw    x3, x1, 0
        add   x6, x3, x5
        or    x3, x6, x3
        addi  x2, x2, -1
        bne   x2, x0, loop
        sw    x3, x7, 240
halt:
        jal   x0, halt
