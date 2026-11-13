// SPDX-License-Identifier: MIT
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;

public class DecompByAddress extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        FunctionManager fm = currentProgram.getFunctionManager();
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        for (String arg : args) {
            Address addr = currentAddress.getAddress(arg);
            Function f = fm.getFunctionAt(addr);
            if (f == null) f = fm.getFunctionContaining(addr);
            if (f != null) {
                println("=== FUNC " + f.getName() + " at " + f.getEntryPoint() + " ===");
                DecompileResults res = decomp.decompileFunction(f, 60, monitor);
                if (res != null && res.getDecompiledFunction() != null) {
                    println(res.getDecompiledFunction().getC());
                }
            } else {
                println("No function at " + arg);
            }
        }
        decomp.dispose();
    }
}
