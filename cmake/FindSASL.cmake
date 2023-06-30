# - Find SASL header and library
# The module defines the following variables:
#
#  SASL_FOUND - true if libldap was found
#  SASL_INCLUDE_DIR - the directory of the SASL headers
#  SASL_LIBRARIES - the libraries needed for linking

# Support preference of static libs by adjusting CMAKE_FIND_LIBRARY_SUFFIXES
if(BUILD_STATIC)
    set(_cyrus_sasl_ORIG_CMAKE_FIND_LIBRARY_SUFFIXES ${CMAKE_FIND_LIBRARY_SUFFIXES})
    set(CMAKE_FIND_LIBRARY_SUFFIXES .a)
endif()

find_path(SASL_INCLUDE_DIR sasl/sasl.h)
find_library(SASL_LIBRARIES NAMES sasl2)

if(SASL_INCLUDE_DIR AND SASL_LIBRARIES)
    set(SASL_FOUND TRUE)
endif()

if(SASL_FOUND)
    message(STATUS "Found SASL includes: ${SASL_INCLUDE_DIR}")
    message(STATUS "Found SASL libraries: ${SASL_LIBRARIES}")
else()
    message(FATAL_ERROR "Could not find SASL library")
endif()

if(BUILD_STATIC)
    get_filename_component(sasl_lib_dir ${SASL_LIBRARIES} DIRECTORY)
    file(GLOB_RECURSE SASL_PLUGINS "${sasl_lib_dir}/sasl2/*.a")
    set(SASL_LIBRARIES ${SASL_LIBRARIES} ${SASL_PLUGINS})
    unset(sasl_lib_dir)
endif()

mark_as_advanced(SASL_INCLUDE_DIR SASL_LIBRARIES)

# Restore the original find library ordering
if(BUILD_STATIC)
  set(CMAKE_FIND_LIBRARY_SUFFIXES ${_cyrus_sasl_ORIG_CMAKE_FIND_LIBRARY_SUFFIXES})
endif()
