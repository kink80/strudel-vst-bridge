cmake_minimum_required(VERSION 3.22)
project(strudel-vst-bridge VERSION 0.3.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)

# JUCE
FetchContent_Declare(juce
    GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
    GIT_TAG 8.0.6
    GIT_SHALLOW ON)
FetchContent_MakeAvailable(juce)

# IXWebSocket
FetchContent_Declare(ixwebsocket
    GIT_REPOSITORY https://github.com/machinezone/IXWebSocket.git
    GIT_TAG v11.4.6
    GIT_SHALLOW ON)
set(USE_TLS OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(ixwebsocket)

juce_add_gui_app(strudel-vst-bridge
    PRODUCT_NAME "strudel-vst-bridge"
    COMPANY_NAME "Strudel"
    BUNDLE_ID "cc.strudel.vstbridge")

juce_generate_juce_header(strudel-vst-bridge)

target_sources(strudel-vst-bridge PRIVATE
    src/Main.cpp
    src/PluginHost.cpp
    src/AudioRouter.cpp
    src/WsServer.cpp
    src/WsProtocol.cpp
    src/PluginWindow.cpp)

target_include_directories(strudel-vst-bridge PRIVATE src)

target_compile_definitions(strudel-vst-bridge PRIVATE
    JUCE_WEB_BROWSER=0
    JUCE_USE_CURL=0
    JUCE_PLUGINHOST_AU=1
    JUCE_PLUGINHOST_VST3=1
    JUCE_PLUGINHOST_LV2=0
    JUCE_APPLICATION_NAME_STRING="$<TARGET_PROPERTY:strudel-vst-bridge,JUCE_PRODUCT_NAME>"
    JUCE_APPLICATION_VERSION_STRING="$<TARGET_PROPERTY:strudel-vst-bridge,VERSION>")

target_link_libraries(strudel-vst-bridge PRIVATE
    juce::juce_audio_basics
    juce::juce_audio_devices
    juce::juce_audio_formats
    juce::juce_audio_processors
    juce::juce_audio_utils
    juce::juce_core
    juce::juce_events
    juce::juce_gui_basics
    juce::juce_gui_extra
    ixwebsocket::ixwebsocket
    juce::juce_recommended_config_flags
    juce::juce_recommended_warning_flags)
