set(ICU_VERSION 71_1)
set(ICU_HASH e06ffc96f59762bd3c929b217445aaec)
set(ICU_PATCHES_DIR ${PROJECT_SOURCE_DIR}/patches)
set(ICU_INSTALL_DIR ${BUNDLED_LIBS_INSTALL_DIR}/icu-prefix)
set(ICU_INCLUDE_DIR ${ICU_INSTALL_DIR}/include)
set(ICU_I18N_LIBRARY ${ICU_INSTALL_DIR}/lib/libicui18n.a)
set(ICU_UC_LIBRARY ${ICU_INSTALL_DIR}/lib/libicuuc.a)
set(ICU_DATA_LIBRARY ${ICU_INSTALL_DIR}/lib/libicudata.a)
set(ICU_CFLAGS "${DEPENDENCY_CFLAGS} -O2")
set(ICU_CXXFLAGS "${DEPENDENCY_CXXFLAGS} -O2")
set(ICU_CPPFLAGS "")
set(ICU_LDFLAGS "")

if(APPLE)
    set(ICU_CFLAGS "${ICU_CFLAGS} ${CMAKE_C_SYSROOT_FLAG} ${CMAKE_OSX_SYSROOT}")
    set(ICU_CXXFLAGS "${ICU_CXXFLAGS} ${CMAKE_C_SYSROOT_FLAG} ${CMAKE_OSX_SYSROOT}")
    set(ICU_CPPFLAGS "${ICU_CPPFLAGS} ${CMAKE_C_SYSROOT_FLAG} ${CMAKE_OSX_SYSROOT}")
endif()

ExternalProject_Add(bundled-icu-project
    PREFIX ${ICU_INSTALL_DIR}
    SOURCE_DIR ${CMAKE_SOURCE_DIR}/vendor/icu4c-${ICU_VERSION}
    BINARY_DIR ${ICU_INSTALL_DIR}/src/icu-build
    STAMP_DIR ${ICU_INSTALL_DIR}/src/icu-stamp
    CONFIGURE_COMMAND <SOURCE_DIR>/source/configure
        CC=${CMAKE_C_COMPILER}
        CXX=${CMAKE_CXX_COMPILER}
        CFLAGS=${ICU_CFLAGS}
        CXXFLAGS=${ICU_CXXFLAGS}
        CPPFLAGS=${ICU_CPPFLAGS}
        LDFLAGS=${ICU_LDFLAGS}

        --with-data-packaging=static
        --prefix=<INSTALL_DIR>
        --disable-shared
        --enable-static
        --disable-renaming
        --disable-tests
        --disable-samples
    INSTALL_COMMAND
        $(MAKE) install &&
        ${CMAKE_COMMAND} -E touch <BINARY_DIR>/uconfig.h &&
        cat <BINARY_DIR>/uconfig.h.prepend <INSTALL_DIR>/include/unicode/uconfig.h >> <BINARY_DIR>/uconfig.h &&
        ${CMAKE_COMMAND} -E copy_if_different <BINARY_DIR>/uconfig.h <INSTALL_DIR>/include/unicode/uconfig.h
    BUILD_BYPRODUCTS ${ICU_I18N_LIBRARY} ${ICU_UC_LIBRARY} ${ICU_DATA_LIBRARY}
)

add_library(bundled-icu-i18n STATIC IMPORTED GLOBAL)
set_target_properties(bundled-icu-i18n PROPERTIES IMPORTED_LOCATION
    ${ICU_I18N_LIBRARY})
add_dependencies(bundled-icu-i18n bundled-icu-project)

add_library(bundled-icu-uc STATIC IMPORTED GLOBAL)
set_target_properties(bundled-icu-uc PROPERTIES IMPORTED_LOCATION
    ${ICU_UC_LIBRARY})
add_dependencies(bundled-icu-uc bundled-icu-project)

add_library(bundled-icu-data STATIC IMPORTED GLOBAL)
set_target_properties(bundled-icu-data PROPERTIES IMPORTED_LOCATION
    ${ICU_DATA_LIBRARY})
add_dependencies(bundled-icu-data bundled-icu-project)

add_custom_target(bundled-icu
    DEPENDS bundled-icu-i18n bundled-icu-uc bundled-icu-data)

set(ICU_FOUND TRUE)
set(ICU_ROOT ${ICU_INSTALL_DIR})
set(ICU_LIBRARIES ${ICU_I18N_LIBRARY} ${ICU_UC_LIBRARY} ${ICU_DATA_LIBRARY}
    ${CMAKE_DL_LIBS})
set(ICU_INCLUDE_DIRS ${ICU_INCLUDE_DIR})

set(HAVE_ICU_STRCOLLUTF TRUE)

message(STATUS "Using bundled icu")
