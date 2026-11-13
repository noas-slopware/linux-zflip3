// SPDX-License-Identifier: MIT
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;

public class FindIms2 extends GhidraScript {
    @Override
    public void run() throws Exception {
        // 1. symbols matching IMS
        SymbolTable st = currentProgram.getSymbolTable();
        SymbolIterator it = st.getAllSymbols(false);
        int n = 0;
        while (it.hasNext() && n < 40) {
            Symbol s = it.next();
            String name = s.getName();
            if (name.contains("cmph_initate") || name.contains("IMS_enable") ||
                name.contains("evaluate_volte") || name.contains("IMSEnabled") ||
                name.contains("ims_agent") || name.contains("IMS_REG_SET")) {
                println("SYM " + name + " at " + s.getAddress());
                n++;
            }
        }
        // 2. defined strings + xrefs
        Listing listing = currentProgram.getListing();
        DataIterator dit = listing.getDefinedData(true);
        int checked = 0, hits = 0;
        while (dit.hasNext() && hits < 10) {
            Data d = dit.next();
            checked++;
            if (d.getValue() instanceof String) {
                String s = (String) d.getValue();
                if (s.contains("No IMS_Enable efs exist") || s.contains("Change wrong IMS_Enable")) {
                    Address a = d.getAddress();
                    println("STR '" + s.substring(0, Math.min(40, s.length())) + "' at " + a);
                    for (Reference ref : getReferencesTo(a)) {
                        Function f = getFunctionContaining(ref.getFromAddress());
                        println("  xref from " + ref.getFromAddress() + (f != null ? " in " + f.getName() + " @ " + f.getEntryPoint() : ""));
                    }
                    hits++;
                }
            }
            if (checked > 2000000) break;
        }
        println("checked " + checked + " defined data items");
    }
}
