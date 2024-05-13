#
# A macro to build libldap
macro(ldap_build)
    message(STATUS "Choosing bundled LDAP")

    # https://git.openldap.org/openldap/openldap
    set(LDAP_VERSION 2.6.7)
    set(LDAP_HASH cf71b4b455ab8dfc8fdd4e247d697ccd)
    set(LDAP_URL https://www.openldap.org/software/download/OpenLDAP/openldap-release/openldap-${LDAP_VERSION}.tgz)

    # Reusing approach from BuildLibCURL.cmake
    get_filename_component(OPENSSL_INSTALL_DIR ${OPENSSL_INCLUDE_DIR} DIRECTORY)

    include(ExternalProject)
    ExternalProject_Add(bundled-ldap
        DEPENDS ${LDAP_OPENSSL_DEPS} bundled-sasl
        SOURCE_DIR ${CMAKE_SOURCE_DIR}/vendor/openldap-${LDAP_VERSION}
        # PATCH_COMMAND
            # OpenLDAP builds everything (including MAN pages) unconditionally,
            # thus we have to patch its sources so as not to install soelim (Groff).
            #
            # NB: This should be done manually every time we update the vendored sources!
            # sed -i.old "/SUBDIRS/s/clients servers tests doc//" Makefile.in
        CONFIGURE_COMMAND <SOURCE_DIR>/configure
            "CC=${CMAKE_C_COMPILER}"
            "CFLAGS=${DEPENDENCY_CFLAGS}"
            "CPPFLAGS=${DEPENDENCY_CPPFLAGS} -I${OPENSSL_INCLUDE_DIR} -I${SASL_INCLUDE_DIR}"
            "LDFLAGS=-L${OPENSSL_INSTALL_DIR}/lib -L${SASL_INSTALL_DIR}/lib"
            "LIBS=-lssl -lcrypto -ldl -lpthread"
            --prefix=<INSTALL_DIR>

            --with-cyrus-sasl
            --with-tls=openssl

            --enable-static
            --disable-shared

            --enable-local
            --enable-ipv6

            --disable-debug
            --disable-slapd
    )

    unset(OPENSSL_INSTALL_DIR)

    ExternalProject_Get_Property(bundled-ldap install_dir)
    set(LDAP_INSTALL_DIR ${install_dir})
    unset(install_dir)

    # Unfortunately, we can't use find_library here,
    # since the package hasn't been built yet.
    # We set the same vars as in FindLDAP.cmake.
    set(LDAP_FOUND TRUE)
    set(LDAP_INCLUDE_DIR ${LDAP_INSTALL_DIR}/include)
    set(LDAP_LIBRARIES
        ${LDAP_INSTALL_DIR}/lib/libldap.a
        ${LDAP_INSTALL_DIR}/lib/liblber.a
    )

    ExternalProject_Add_Step(bundled-ldap byproducts
        BYPRODUCTS ${LDAP_LIBRARIES})

    # On OS X we may also need to link libresolv.dylib.
    # However, note that newer OS X releases don't have that file;
    # instead, it's provided via a built-in dynamic linker cache.
    if(APPLE)
        find_library(RESOLV_LIBRARIES NAMES resolv PATHS
            /usr/lib
            /usr/local/opt/openldap/lib
            /usr/local/lib
            NO_CMAKE_SYSTEM_PATH)
        if(NOT "${RESOLV_LIBRARIES}" STREQUAL "RESOLV_LIBRARIES-NOTFOUND")
            set(LDAP_LIBRARIES ${LDAP_LIBRARIES} ${RESOLV_LIBRARIES})
        endif()
    endif()

    message(STATUS "Found LDAP includes: ${LDAP_INCLUDE_DIR}")
    message(STATUS "Found LDAP libraries: ${LDAP_LIBRARIES}")
endmacro()
