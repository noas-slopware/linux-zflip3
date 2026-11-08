import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.mem.*;
import ghidra.program.model.listing.*;

public class FindXrefs2 extends GhidraScript {
    @Override
    public void run() throws Exception {
        long[] targets = {0xc3cf7867L, 0xc3cf7819L};
        Memory mem = currentProgram.getMemory();
        FunctionManager fm = currentProgram.getFunctionManager();
        for (long t : targets) {
            println("=== refs to " + Long.toHexString(t) + " in EXEC blocks ===");
            byte[] pat = new byte[]{(byte)(t&0xff),(byte)((t>>8)&0xff),(byte)((t>>16)&0xff),(byte)((t>>24)&0xff)};
            for (MemoryBlock b : mem.getBlocks()) {
                if (!b.isExecute()) continue;
                Address addr = b.getStart();
                int count = 0;
                while (addr != null && addr.compareTo(b.getEnd()) < 0 && count < 20) {
                    Address hit = mem.findBytes(addr, pat, new byte[]{1,1,1,1}, true, monitor);
                    if (hit == null || hit.compareTo(b.getEnd()) > 0) break;
                    Function f = fm.getFunctionContaining(hit);
                    println("  " + hit + (f != null ? " in " + f.getName() + " @ " + f.getEntryPoint() : " (no func)"));
                    if (f != null && count == 0) {
                        // print first 30 instructions of this function
                        Listing list = currentProgram.getListing();
                        InstructionIterator insns = list.getInstructions(f.getBody(), true);
                        int ic = 0;
                        while (insns.hasNext() && ic < 30) {
                            println("    " + insns.next());
                            ic++;
                        }
                    }
                    addr = hit.add(4);
                    count++;
                }
            }
        }
    }
}
