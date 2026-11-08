import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.*;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;

// Decompile every function whose (demangled) name contains one of the script args.
// Usage: -postScript DecompByName.java QmiVendorService IpcOverQmiChannel
public class DecompByName extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] targets = getScriptArgs();
        FunctionManager fm = currentProgram.getFunctionManager();
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        for (Function f : fm.getFunctions(true)) {
            String name = f.getName(true);
            boolean hit = false;
            for (String t : targets) {
                if (name.contains(t)) { hit = true; break; }
            }
            if (!hit) continue;
            println("=== FUNC " + name + " at " + f.getEntryPoint() + " ===");
            try {
                DecompileResults res = decomp.decompileFunction(f, 180, monitor);
                if (res != null && res.getDecompiledFunction() != null) {
                    String c = res.getDecompiledFunction().getC();
                    println(c.length() > 20000 ? c.substring(0, 20000) : c);
                } else {
                    println("(decompile null)");
                }
            } catch (Exception e) {
                println("(decompile failed: " + e + ")");
            }
        }
        decomp.dispose();
    }
}
