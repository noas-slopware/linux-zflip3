// SPDX-License-Identifier: MIT
import ghidra.app.script.GhidraScript;
public class ProgInfo extends GhidraScript {
    @Override
    public void run() throws Exception {
        println("IMAGE BASE: " + currentProgram.getImageBase());
        println("FORMAT: " + currentProgram.getExecutableFormat());
        println("LANG: " + currentProgram.getLanguageID());
        ghidra.program.model.mem.MemoryBlock[] blocks = currentProgram.getMemory().getBlocks();
        println("BLOCKS: " + blocks.length);
        for (int i = 0; i < Math.min(blocks.length, 10); i++) {
            println("  " + blocks[i].getName() + " " + blocks[i].getStart() + "-" + blocks[i].getEnd());
        }
        println("FUNCS: " + currentProgram.getFunctionManager().getFunctionCount());
        println("SYMS: " + currentProgram.getSymbolTable().getNumSymbols());
    }
}
