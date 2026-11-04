## bugfix/fiber

* Fixed inconsistent `cpu_instructions` measurements for short fiber execution
  intervals on Linux/x86, including on hybrid CPUs, by ordering RDPMC reads.
