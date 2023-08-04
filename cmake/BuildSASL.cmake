#
# A macro to build libsasl2
macro(sasl_build)
    message(STATUS "Choosing bundled SASL")

    # https://github.com/cyrusimap/cyrus-sasl
    # Tarball is already pre-configured (autoconf) as opposed to git sources.
    set(SASL_VERSION 2.1.28)
    set(SASL_HASH 6f228a692516f5318a64505b46966cfa)
    set(SASL_URL https://github.com/cyrusimap/cyrus-sasl/releases/download/cyrus-sasl-${SASL_VERSION}/cyrus-sasl-${SASL_VERSION}.tar.gz)

    # Reusing approach from BuildLibCURL.cmake
    get_filename_component(OPENSSL_INSTALL_DIR ${OPENSSL_INCLUDE_DIR} DIRECTORY)

    # NB: $(MAKE) will preserve jobserver in Makefiles.
    if("${CMAKE_GENERATOR}" STREQUAL "Unix Makefiles")
        set(MAKE_EXECUTABLE "$(MAKE)")
    else()
        set(MAKE_EXECUTABLE "make")
    endif()

    include(ExternalProject)
    ExternalProject_Add(bundled-sasl
        DEPENDS ${LDAP_OPENSSL_DEPS}
        SOURCE_DIR ${CMAKE_SOURCE_DIR}/vendor/cyrus-sasl-${SASL_VERSION}
        CONFIGURE_COMMAND <SOURCE_DIR>/configure
            "CC=${CMAKE_C_COMPILER}"
            "CFLAGS=${DEPENDENCY_CFLAGS}"
            "CPPFLAGS=${DEPENDENCY_CPPFLAGS} -I${OPENSSL_INCLUDE_DIR}"
            "LDFLAGS=-L${OPENSSL_INSTALL_DIR}/lib"
            "LIBS=-lssl -lcrypto -ldl -lpthread"
            --prefix=<INSTALL_DIR>

            --with-openssl=${OPENSSL_INSTALL_DIR}
            --with-dblib=none

            --enable-static
            --disable-shared

            # Auth plugins listed below
            --enable-anon
            --enable-cram
            --enable-digest
            --enable-otp
            --enable-plain
            --enable-scram

            --disable-gssapi
            --disable-krb4

            --disable-macos-framework
            --disable-sample

        # HACK: prevent `am--refresh` rule from reconfiguring the project.
        # Further reading: https://stackoverflow.com/a/5745366.
        BUILD_COMMAND ${MAKE_EXECUTABLE}
            AUTOCONF=: AUTOHEADER=: AUTOMAKE=: ACLOCAL=: all
        INSTALL_COMMAND ${MAKE_EXECUTABLE}
            AUTOCONF=: AUTOHEADER=: AUTOMAKE=: ACLOCAL=: install
    )

    unset(OPENSSL_INSTALL_DIR)

    ExternalProject_Get_Property(bundled-sasl install_dir)
    set(SASL_INSTALL_DIR ${install_dir})
    unset(install_dir)

    # Unfortunately, we can't use find_library here,
    # since the package hasn't been built yet.
    # We set the same vars as in FindSASL.cmake.
    set(SASL_FOUND TRUE)
    set(SASL_INCLUDE_DIR ${SASL_INSTALL_DIR}/include)
    set(SASL_LIBRARIES
        ${SASL_INSTALL_DIR}/lib/libsasl2.a
        ${SASL_INSTALL_DIR}/lib/sasl2/libanonymous.a
        ${SASL_INSTALL_DIR}/lib/sasl2/libcrammd5.a
        ${SASL_INSTALL_DIR}/lib/sasl2/libdigestmd5.a
        ${SASL_INSTALL_DIR}/lib/sasl2/libotp.a
        ${SASL_INSTALL_DIR}/lib/sasl2/libplain.a
        ${SASL_INSTALL_DIR}/lib/sasl2/libscram.a
    )

    ExternalProject_Add_Step(bundled-sasl byproducts
        BYPRODUCTS ${SASL_LIBRARIES})

    message(STATUS "Found SASL includes: ${SASL_INCLUDE_DIR}")
    message(STATUS "Found SASL libraries: ${SASL_LIBRARIES}")
endmacro()
