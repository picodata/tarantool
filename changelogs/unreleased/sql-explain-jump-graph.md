## feature/sql

* `EXPLAIN` has a new facet, `graph`: `EXPLAIN (graph) SELECT ...`. It adds a
  first column, `graph`, that draws the jumps between the VDBE instructions, as
  radare2 does. The lines of forward jumps are box-drawing characters, the
  lines of backward jumps are dots. `graph [4, 9]` draws only the jumps that
  start or end at these addresses of the main program, and marks the ends of
  the other jumps with a middle dot. `graph []` draws no jumps, only the dots.
  An instruction whose jump target is not known before the run, such as
  `Yield`, also has a middle dot. Plain `EXPLAIN` does not show the graph. The
  pseudocode of an instruction in a loop is now indented.
