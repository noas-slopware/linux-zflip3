import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.*;
import ghidra.program.model.symbol.*;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;

public class FindStr extends GhidraScript {
    @Override
    public void run() throws Exception {
        String needle = getScriptArgs()[0];
        FunctionManager fm = currentProgram.getFunctionManager();
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        Memory mem = currentProgram.getMemory();
        for (MemoryBlock b : mem.getBlocks()) {
            Address addr = b.getStart();
            while (addr != null && addr.compareTo(b.getEnd()) < 0) {
                Data d = getDataAt(addr);
                if (d != null && d.getValue() instanceof String) {
                    String s = (String) d.getValue();
                    if (s.contains(needle)) {
                        println("FOUND string at " + addr + ": " + s);
                        for (Reference ref : getReferencesTo(addr)) {
                            Function f = fm.getFunctionContaining(ref.getFromAddress());
                            println("  ref from " + ref.getFromAddress() + " in " + (f != null ? f.getName() : "null"));
                            if (f != null) {
                                DecompileResults res = decomp.decompileFunction(f, 60, monitor);
                                if (res != null && res.getDecompiledFunction() != null) {
                                    println(res.getDecompiledFunction().getC());
                                }
                            }
                        }
                    }
                    addr = addr.add(d.getLength());
                } else {
                    addr = addr.add(1);
                }
            }
        }
        decomp.dispose();
    }
}
