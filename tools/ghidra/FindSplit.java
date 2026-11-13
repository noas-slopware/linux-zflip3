// SPDX-License-Identifier: MIT
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.mem.*;
import ghidra.program.model.listing.*;
public class FindSplit extends GhidraScript {
    @Override
    public void run() throws Exception {
        Memory mem = currentProgram.getMemory();
        FunctionManager fm = currentProgram.getFunctionManager();
        // low halves of c3cf7867 and c3cf7819, high half c3cf
        byte[] lo1 = new byte[]{0x67, 0x78};
        byte[] lo2 = new byte[]{0x19, 0x78};
        byte[] hi = new byte[]{(byte)0xcf, (byte)0xc3};
        for (MemoryBlock b : mem.getBlocks()) {
            if (!b.isExecute()) continue;
            for (byte[] lo : new byte[][]{lo1, lo2}) {
                Address addr = b.getStart();
                int count = 0;
                while (addr != null && count < 30) {
                    Address hit = mem.findBytes(addr, lo, new byte[]{1,1}, true, monitor);
                    if (hit == null || hit.compareTo(b.getEnd()) > 0) break;
                    // check for high half within +-16 bytes
                    boolean hasHi = false;
                    for (int d = -16; d <= 16; d += 2) {
                        try {
                            byte[] w = new byte[2];
                            mem.getBytes(hit.add(d), w);
                            if (w[0] == hi[0] && w[1] == hi[1]) { hasHi = true; break; }
                        } catch (Exception e) {}
                    }
                    if (hasHi) {
                        Function f = fm.getFunctionContaining(hit);
                        println("HIT " + hit + (f != null ? " in " + f.getName() + " @ " + f.getEntryPoint() : " (no func)"));
                        if (f == null) {
                            // force disassemble
                            disassemble(hit);
                            Listing list = currentProgram.getListing();
                            for (int i = -2; i <= 4; i++) {
                                Instruction ins = list.getInstructionAt(hit.add(i*4));
                                if (ins != null) println("    " + ins);
                            }
                        }
                    }
                    addr = hit.add(2);
                    count++;
                }
            }
        }
    }
}
