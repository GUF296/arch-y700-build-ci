cmake_minimum_required(VERSION 3.16)

project(tb321fu_ksystemstats_adreno_freq VERSION 0.1)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(ECM 6.6 REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})

include(KDEInstallDirs)
include(KDECMakeSettings)
include(KDECompilerSettings NO_POLICY_SCOPE)

find_package(Qt6 6.6 REQUIRED CONFIG COMPONENTS Core)
find_package(KF6 6.6 REQUIRED COMPONENTS CoreAddons I18n)
find_package(KSysGuard 6.6 REQUIRED)

add_library(ksystemstats_plugin_tb321fu_gpu MODULE tb321fu_gpu.cpp)
target_link_libraries(ksystemstats_plugin_tb321fu_gpu Qt6::Core KF6::CoreAddons KF6::I18n KSysGuard::SystemStats)

install(TARGETS ksystemstats_plugin_tb321fu_gpu DESTINATION ${KDE_INSTALL_QTPLUGINDIR}/ksystemstats)
