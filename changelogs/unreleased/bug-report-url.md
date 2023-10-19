## feature/core

When crashing a message will now direct users to report bugs at support@picodata.io.
This info can also be changed at build time by adding a preprocessor definition
for `PICODATA_BUG_REPORT_INFO`, e.g. by adding this line to a `CMakeLists.txt`:
```cmake
add_definitions(-DPICODATA_BUG_REPORT_INFO="support@picodata.io")
```
