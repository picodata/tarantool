set(OPENSSL_VERSION 3.2.3)
set(OPENSSL_HASH 84de91765a572c5711945c723e6b99d8)
set(OPENSSL_PATCHES_DIR ${PROJECT_SOURCE_DIR}/patches)
set(OPENSSL_INSTALL_DIR ${BUNDLED_LIBS_INSTALL_DIR}/openssl-prefix)
set(OPENSSL_INCLUDE_DIR ${OPENSSL_INSTALL_DIR}/include)
set(OPENSSL_CRYPTO_LIBRARY ${OPENSSL_INSTALL_DIR}/lib/libcrypto.a)
set(OPENSSL_SSL_LIBRARY ${OPENSSL_INSTALL_DIR}/lib/libssl.a)
set(OPENSSL_CFLAGS "${DEPENDENCY_CFLAGS} -O2")
set(OPENSSL_CPPFLAGS "")
set(OPENSSL_LDFLAGS "")

if(APPLE)
    set(OPENSSL_CFLAGS "${OPENSSL_CFLAGS} ${CMAKE_C_SYSROOT_FLAG} ${CMAKE_OSX_SYSROOT}")
    set(OPENSSL_CPPFLAGS "${OPENSSL_CPPFLAGS} ${CMAKE_C_SYSROOT_FLAG} ${CMAKE_OSX_SYSROOT}")
endif()

ExternalProject_Add(bundled-openssl-project
    PREFIX ${OPENSSL_INSTALL_DIR}
    SOURCE_DIR ${CMAKE_SOURCE_DIR}/vendor/openssl-${OPENSSL_VERSION}
    BINARY_DIR ${OPENSSL_INSTALL_DIR}/src/openssl-build
    STAMP_DIR ${OPENSSL_INSTALL_DIR}/src/openssl-stamp
    CONFIGURE_COMMAND <SOURCE_DIR>/config
        CC=${CMAKE_C_COMPILER}
        CXX=${CMAKE_CXX_COMPILER}
        CFLAGS=${OPENSSL_CFLAGS}
        CPPFLAGS=${OPENSSL_CPPFLAGS}
        LDFLAGS=${OPENSSL_LDFLAGS}

        --prefix=<INSTALL_DIR>
        --libdir=lib
        no-shared
        no-module
    INSTALL_COMMAND ${CMAKE_MAKE_PROGRAM} install_sw
    BUILD_BYPRODUCTS ${OPENSSL_CRYPTO_LIBRARY} ${OPENSSL_SSL_LIBRARY}
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)

add_library(bundled-openssl-ssl STATIC IMPORTED GLOBAL)
set_target_properties(bundled-openssl-ssl PROPERTIES IMPORTED_LOCATION
    ${OPENSSL_SSL_LIBRARY})
add_dependencies(bundled-openssl-ssl bundled-openssl-project)

add_library(bundled-openssl-crypto STATIC IMPORTED GLOBAL)
set_target_properties(bundled-openssl-crypto PROPERTIES IMPORTED_LOCATION
    ${OPENSSL_CRYPTO_LIBRARY})
add_dependencies(bundled-openssl-crypto bundled-openssl-project)

add_custom_target(bundled-openssl
    DEPENDS bundled-openssl-ssl bundled-openssl-crypto)

set(OPENSSL_FOUND TRUE)
set(OPENSSL_LIBRARIES ${OPENSSL_SSL_LIBRARY} ${OPENSSL_CRYPTO_LIBRARY}
    ${CMAKE_DL_LIBS})
set(OPENSSL_INCLUDE_DIRS ${OPENSSL_INCLUDE_DIR})

message(STATUS "Using bundled openssl")
