cmake_minimum_required(VERSION 3.4.1)

# --- ADD THESE 2 LINES ---
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# -------------------------

include_directories(${CMAKE_SOURCE_DIR}/include)
# UPDATE: We renamed the folder to 'sdk' so OpenCV stops complaining.
include("C:/Users/lenovo/StudioProjects/vibravision/android/sdk/native/jni/OpenCVConfig.cmake")

add_library( 
    vibravision
    SHARED
    native_lib.cpp
)

target_link_libraries( 
    vibravision
    ${OpenCV_LIBS}
    log
)