// SPDX-License-Identifier: MIT
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.*;

public class ListFuncs extends GhidraScript {
    @Override
    public void run() throws Exception {
        String filter = "";
        String[] args = getScriptArgs();
        if (args.length > 0) filter = args[0].toLowerCase();
        FunctionManager fm = currentProgram.getFunctionManager();
        int count = 0;
        for (Function f : fm.getFunctions(true)) {
            String name = f.getName(true);
            if (filter.isEmpty() || name.toLowerCase().contains(filter)) {
                println(name + " at " + f.getEntryPoint());
                count++;
                if (count > 100) {
                    println("... truncated (100 matches)");
                    break;
                }
            }
        }
        println("Total listed: " + count);
    }
}
