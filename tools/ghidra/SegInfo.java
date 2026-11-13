// SPDX-License-Identifier: MIT
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.mem.*;
public class SegInfo extends GhidraScript {
    @Override
    public void run() throws Exception {
        for (String s : new String[]{"c3cf7867","c3cf7819","c21ce867"}) {
            Address a = getAddressFactory().getDefaultAddressSpace().getAddress(s);
            MemoryBlock b = currentProgram.getMemory().getBlock(a);
            println(s + " -> block=" + (b != null ? b.getName() + " [" + b.getStart() + "-" + b.getEnd() + "] R" + (b.isRead()?"":"!") + "W" + (b.isWrite()?"":"!") + "X" + (b.isExecute()?"":"!") : "NONE"));
        }
        for (MemoryBlock b : currentProgram.getMemory().getBlocks()) {
            if (b.isExecute()) println("EXEC: " + b.getName() + " " + b.getStart() + "-" + b.getEnd());
        }
    }
}
