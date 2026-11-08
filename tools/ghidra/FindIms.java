import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.*;
import ghidra.program.model.symbol.*;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;

public class FindIms extends GhidraScript {
    @Override
    public void run() throws Exception {
        FunctionManager fm = currentProgram.getFunctionManager();
        String[] targets = {"cmph_initate_sub_config", "evaluate_volte_enabled",
            "policyman_ims_config", "policyman_get_service_domain",
            "ss_write_IMS_enabled", "cmsds_init_read_gen_sub_config",
            "handleIMSGlobalInit", "IMS_enable"};
        for (Function f : fm.getFunctions(true)) {
            String name = f.getName();
            for (String t : targets) {
                if (name.contains(t)) {
                    println("FOUND " + t + " at " + f.getEntryPoint());
                }
            }
        }
        // string refs
        Memory mem = currentProgram.getMemory();
        for (String needle : new String[]{"No IMS_Enable efs exist", "Change wrong IMS_Enable"}) {
            MemoryBlock[] blocks = mem.getBlocks();
            for (MemoryBlock b : blocks) {
                Address addr = b.getStart();
                while (addr != null && addr.compareTo(b.getEnd()) < 0) {
                    Data d = getDataAt(addr);
                    if (d != null && d.getValue() instanceof String) {
                        String s = (String) d.getValue();
                        if (s.contains(needle)) {
                            println("STRING '" + needle + "' at " + addr);
                            for (Reference ref : getReferencesTo(addr)) {
                                Function fc = fm.getFunctionContaining(ref.getFromAddress());
                                println("  ref from " + ref.getFromAddress() + (fc != null ? " in " + fc.getName() : ""));
                            }
                        }
                        addr = addr.add(d.getLength());
                    } else {
                        addr = addr.add(1);
                    }
                }
            }
        }
        // decompile cmph function if found
        for (Function f : fm.getFunctions(true)) {
            if (f.getName().contains("cmph_initate_sub_config")) {
                DecompInterface decomp = new DecompInterface();
                decomp.openProgram(currentProgram);
                DecompileResults res = decomp.decompileFunction(f, 120, monitor);
                if (res != null && res.getDecompiledFunction() != null) {
                    String c = res.getDecompiledFunction().getC();
                    println("=== DECOMPILE cmph_initate_sub_config ===");
                    println(c.length() > 8000 ? c.substring(0, 8000) : c);
                }
                decomp.dispose();
                break;
            }
        }
    }
}
