set(lib_sources crypto.c)

set_source_files_compile_flags(${lib_sources})
add_library(tcrypto STATIC ${lib_sources})
target_link_libraries(tcrypto ${OPENSSL_LIBRARIES} core)

if (ENABLE_BUNDLED_OPENSSL)
    add_dependencies(tcrypto bundled-openssl)
endif()
