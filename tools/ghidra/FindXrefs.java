// SPDX-License-Identifier: MIT
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSetView;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;

public class FindXrefs extends GhidraScript {
    @Override
    public void run() throws Exception {
        long[] targets = {0xc3cf7867L, 0xc3cf7819L};
        Memory mem = currentProgram.getMemory();
        FunctionManager fm = currentProgram.getFunctionManager();
        for (long t : targets) {
            Address taddr = toAddr(t);
            println("=== refs to " + taddr + " ===");
            // search all memory for 4-byte LE value
            byte[] pat = new byte[]{(byte)(t & 0xff), (byte)((t>>8)&0xff), (byte)((t>>16)&0xff), (byte)((t>>24)&0xff)};
            AddressSetView found = mem.getLoadedAndInitializedAddressSet();
            Address addr = found.getMinAddress();
            int count = 0;
            while (addr != null && count < 50) {
                Address hit = mem.findBytes(addr, pat, new byte[]{1,1,1,1}, true, monitor);
                if (hit == null) break;
                Function f = fm.getFunctionContaining(hit);
                println("  const at " + hit + (f != null ? " in " + f.getName() + " (" + f.getEntryPoint() + ")" : " (no function)"));
                // disassemble around hit if no function
                if (f == null) {
                    Listing list = currentProgram.getListing();
                    Instruction ins = list.getInstructionAt(hit);
                    if (ins == null) {
                        disassemble(hit);
                        ins = list.getInstructionAt(hit);
                    }
                    if (ins != null) println("    insn: " + ins);
                }
                addr = hit.add(4);
                count++;
            }
        }
    }
}
