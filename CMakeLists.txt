cmake_minimum_required(VERSION 3.20)
project(NppJsonViewer LANGUAGES CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")

# Host header path — NppPluginInterfaceMac.h, Scintilla.h etc.
set(NPP_MACOS_DIR     "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(NPP_WIN_DIR       "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus")
set(SCINTILLA_INCLUDE "${NPP_WIN_DIR}/scintilla/include")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")

# Bundled header-only RapidJSON (NPP-JSONViewer fork — RawNumber fix).
set(RAPIDJSON_INCLUDE "${CMAKE_SOURCE_DIR}/external/rapidjson_include")

# Default to Release with optimization when not specified — matches
# ComparePlus / ElasticTabstops / etc. pattern in this sibling repo.
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

add_library(NppJsonViewer SHARED
    src/NppJsonViewer.mm
    src/JsonParser.mm
    src/JsonFormatter.mm
    src/JsonPanel.mm
    src/JsonSettingsDialog.mm
)
target_include_directories(NppJsonViewer PRIVATE
    ${NPP_PLUGIN_INCLUDE}
    ${SCINTILLA_INCLUDE}
    ${RAPIDJSON_INCLUDE}
    src)
target_link_libraries(NppJsonViewer PRIVATE
    "-framework Cocoa")
target_compile_options(NppJsonViewer PRIVATE
    -Wall -Wno-unused-parameter
    -fvisibility=hidden
    # ARC — matches XmlNavigator / NppMarkdownPanel pattern. Applied only
    # to Objective-C++ TUs via generator expression.
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
set_target_properties(NppJsonViewer PROPERTIES PREFIX "" SUFFIX ".dylib")

set(PLUGIN_INSTALL_DIR "$ENV{HOME}/.notepad++/plugins/NppJsonViewer")
install(TARGETS NppJsonViewer DESTINATION "${PLUGIN_INSTALL_DIR}")
