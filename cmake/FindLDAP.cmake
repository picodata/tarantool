# - Find LDAP header and library
# The module defines the following variables:
#
#  LDAP_FOUND - true if libldap was found
#  LDAP_INCLUDE_DIR - the directory of the LDAP headers
#  LDAP_LIBRARIES - the libraries needed for linking

# Support preference of static libs by adjusting CMAKE_FIND_LIBRARY_SUFFIXES
if(BUILD_STATIC)
    set(_openldap_ORIG_CMAKE_FIND_LIBRARY_SUFFIXES ${CMAKE_FIND_LIBRARY_SUFFIXES})
    set(CMAKE_FIND_LIBRARY_SUFFIXES .a)
endif()

if(APPLE)
    find_path(LDAP_INCLUDE_DIR ldap.h PATHS
        /usr/local/include
        /usr/local/opt/openldap/include
        /opt/local/include
        NO_CMAKE_SYSTEM_PATH)
    find_library(LDAP_LIBRARIES NAMES ldap PATHS
        /usr/local/lib
        /usr/local/opt/openldap/lib
        /opt/local/lib
        NO_CMAKE_SYSTEM_PATH)
    find_library(LBER_LIBRARIES NAMES lber PATHS
        /usr/local/lib
        /usr/local/opt/openldap/lib
        /opt/local/lib
        NO_CMAKE_SYSTEM_PATH)

    # On OS X we may also need to link libresolv.dylib.
    # However, note that newer OS X releases don't have that file;
    # instead, it's provided via a built-in dynamic linker cache.
    if(_openldap_ORIG_CMAKE_FIND_LIBRARY_SUFFIXES)
        set(CMAKE_FIND_LIBRARY_SUFFIXES ${_openldap_ORIG_CMAKE_FIND_LIBRARY_SUFFIXES})
    endif()
    find_library(RESOLV_LIBRARIES NAMES resolv PATHS
        /usr/lib
        /usr/local/opt/openldap/lib
        /usr/local/lib
        NO_CMAKE_SYSTEM_PATH)
else()
    find_path(LDAP_INCLUDE_DIR ldap.h)
    find_library(LDAP_LIBRARIES NAMES ldap)
    find_library(LBER_LIBRARIES NAMES lber)
endif()

if(LDAP_INCLUDE_DIR AND LDAP_LIBRARIES)
    set(LDAP_FOUND TRUE)
endif()

if(LDAP_FOUND)
    set(LDAP_LIBRARIES ${LDAP_LIBRARIES} ${LBER_LIBRARIES})
    if(NOT "${RESOLV_LIBRARIES}" STREQUAL "RESOLV_LIBRARIES-NOTFOUND")
        set(LDAP_LIBRARIES ${LDAP_LIBRARIES} ${RESOLV_LIBRARIES})
    endif()
    message(STATUS "Found LDAP includes: ${LDAP_INCLUDE_DIR}")
    message(STATUS "Found LDAP libraries: ${LDAP_LIBRARIES}")
else()
    message(FATAL_ERROR "Could not find LDAP library")
endif()

mark_as_advanced(LDAP_INCLUDE_DIR LDAP_LIBRARIES LBER_LIBRARIES)

# Restore the original find library ordering
if(BUILD_STATIC)
  set(CMAKE_FIND_LIBRARY_SUFFIXES ${_openldap_ORIG_CMAKE_FIND_LIBRARY_SUFFIXES})
endif()
