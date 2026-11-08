import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;

public class FindCaller extends GhidraScript {
    @Override
    public void run() throws Exception {
        Address addr = currentAddress.getAddress(getScriptArgs()[0]);
        FunctionManager fm = currentProgram.getFunctionManager();
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        for (Reference ref : getReferencesTo(addr)) {
            Function f = fm.getFunctionContaining(ref.getFromAddress());
            println("Ref from " + ref.getFromAddress() + " in " + (f != null ? f.getName() : "null"));
            if (f != null) {
                DecompileResults res = decomp.decompileFunction(f, 60, monitor);
                if (res != null && res.getDecompiledFunction() != null) {
                    println(res.getDecompiledFunction().getC());
                }
            }
        }
        decomp.dispose();
    }
}
