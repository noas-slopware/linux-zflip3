// SPDX-License-Identifier: MIT
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.*;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;

public class DecompImsReg extends GhidraScript {
    @Override
    public void run() throws Exception {
        FunctionManager fm = currentProgram.getFunctionManager();
        String[] targets = {
            "TxStartImsReg",
            "TxStopImsReg",
            "TxSetImsRegStateChanged",
            "SetStartImsReg",
            "SetStopImsReg",
            "SetImsRegStateChanged",
            "QmiImsService",
            "GetImsSdmSetting",
            "SetImsSdmSetting",
            "TxSetRegMgrConfig",
            "TxSetSdmSipConfig",
            "TxSetSdmSmsFormat",
            "TxSetSdmImsDomain"
        };
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        for (Function f : fm.getFunctions(true)) {
            String name = f.getName();
            boolean hit = false;
            for (String t : targets) {
                if (name.contains(t)) { hit = true; break; }
            }
            if (!hit) continue;
            println("=== FUNC " + name + " at " + f.getEntryPoint() + " ===");
            try {
                DecompileResults res = decomp.decompileFunction(f, 120, monitor);
                if (res != null && res.getDecompiledFunction() != null) {
                    String c = res.getDecompiledFunction().getC();
                    println(c.length() > 12000 ? c.substring(0, 12000) : c);
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
