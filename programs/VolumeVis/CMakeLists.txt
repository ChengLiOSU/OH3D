cmake_minimum_required(VERSION 2.8.5 FATAL_ERROR)

PROJECT (VolumeVis)

find_package(OpenGL REQUIRED)
find_package(Qt5Widgets REQUIRED)

include_directories(
	${SHARED_LIB_INCLUDE_DIR}
	${CMAKE_CURRENT_SOURCE_DIR}
	${CUDA_TOOLKIT_INCLUDE} 
	${PROJECT_BINARY_DIR}
	${CMAKE_BINARY_DIR}
	${CUDA_SDK_ROOT_DIR}/common/inc 
	required)
		
set( SRCS 
	main.cpp 
	window.cpp 
	
	)
set( HDRS  
	window.h 

    )

configure_file(config.txt config.txt COPYONLY)

set(CMAKE_INCLUDE_CURRENT_DIR ON)
set(CMAKE_AUTOMOC ON)

add_executable(${PROJECT_NAME} ${SRCS} ${HDRS} config.txt)
qt5_use_modules(${PROJECT_NAME} OpenGL Gui Widgets)
target_link_libraries(${PROJECT_NAME} 
	Qt5::Widgets  
	${OPENGL_LIBRARIES} 
	deform
	io
	interact
	render
	dataModel
)

if(USE_OSVR)
	target_link_libraries(${PROJECT_NAME} osvr::osvrClientKitCpp)
endif()
