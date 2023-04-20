#
# A macro to build the bundled libcoro
macro(libcoro_build)
    set(coro_src
        ${PROJECT_SOURCE_DIR}/third_party/coro/coro.c
    )
    set_source_files_properties(${coro_src} PROPERTIES
                                COMPILE_FLAGS "${DEPENDENCY_CFLAGS} -fomit-frame-pointer")

    add_library(coro STATIC ${coro_src})

    set(LIBCORO_INCLUDE_DIR ${PROJECT_SOURCE_DIR}/third_party/coro)
    set(LIBCORO_LIBRARIES coro)

    if (${CMAKE_SYSTEM_PROCESSOR} MATCHES "86" OR ${CMAKE_SYSTEM_PROCESSOR} MATCHES "amd64")
        target_compile_definitions(coro PUBLIC "-DCORO_ASM")
    elseif (${CMAKE_SYSTEM_PROCESSOR} MATCHES "arm" OR ${CMAKE_SYSTEM_PROCESSOR} MATCHES "aarch64")
        target_compile_definitions(coro PUBLIC "-DCORO_ASM")
    else()
        target_compile_definitions(coro PUBLIC "-DCORO_SJLJ")
    endif()

    unset(coro_src)
endmacro(libcoro_build)
