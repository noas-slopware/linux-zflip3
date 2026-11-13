// SPDX-License-Identifier: MIT
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;

public class DumpInsts extends GhidraScript {
    @Override
    public void run() throws Exception {
        Address addr = currentAddress.getAddress(getScriptArgs()[0]);
        int n = Integer.parseInt(getScriptArgs()[1]);
        InstructionIterator iter = currentProgram.getListing().getInstructions(addr, true);
        int i = 0;
        while (iter.hasNext() && i < n) {
            Instruction inst = iter.next();
            println(inst.getAddress() + ": " + inst.toString());
            i++;
        }
    }
}
