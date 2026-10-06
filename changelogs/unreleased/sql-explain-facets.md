## feature/sql

* **[Breaking change]** `EXPLAIN` takes a list of facets that select its
  columns: `EXPLAIN (opcode, pseudocode) SELECT ...`. The facet `opcode` shows
  the address, the opcode and the operands of each VDBE instruction. The facet
  `pseudocode` shows the address and the pseudocode. Plain `EXPLAIN` now shows
  only `pseudocode`, 2 columns in place of 8: use `EXPLAIN (opcode)` to see the
  opcodes and the operands.
