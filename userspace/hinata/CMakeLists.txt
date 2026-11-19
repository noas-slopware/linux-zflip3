# SPDX-License-Identifier: GPL-3.0-or-later
cmake_minimum_required(VERSION 3.20)
project(hinata VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(ECM 6.0 REQUIRED NO_MODULE)
list(APPEND CMAKE_MODULE_PATH ${ECM_MODULE_PATH})
include(KDEInstallDirs)
include(KDECMakeSettings)

find_package(Qt6 6.6 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2)
find_package(KF6Kirigami REQUIRED)
qt_policy(SET QTP0001 NEW)
find_package(PkgConfig REQUIRED)
pkg_check_modules(LCB REQUIRED IMPORTED_TARGET libcellbroadcast-0.0 glib-2.0 gio-2.0)

qt_add_executable(hinata src/main.cpp src/alertmodel.cpp src/alertmodel.h)
qt_add_qml_module(hinata
    URI codes.noa.hinata
    VERSION 1.0
    QML_FILES src/qml/Main.qml src/qml/AlertPage.qml
)
target_link_libraries(hinata PRIVATE Qt6::Gui Qt6::Qml Qt6::Quick Qt6::QuickControls2 PkgConfig::LCB)
target_include_directories(hinata PRIVATE src)
# GLib's headers name struct members "signals"; Qt's keyword macros would rewrite them
target_compile_definitions(hinata PRIVATE QT_NO_KEYWORDS LIBCELLBROADCAST_USE_UNSTABLE_API)

install(TARGETS hinata ${KDE_INSTALL_TARGETS_DEFAULT_ARGS})
install(FILES codes.noa.Hinata.desktop DESTINATION ${KDE_INSTALL_APPDIR})
