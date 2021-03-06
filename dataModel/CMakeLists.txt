cmake_minimum_required(VERSION 2.8)
project(dataModel)
#set(SHARED_LIB_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR})
#set(SHARED_LIB_INCLUDE_DIR ${SHARED_LIB_INCLUDE_DIR} PARENT_SCOPE)

find_package(Qt5Widgets REQUIRED)
find_package(CUDA REQUIRED)


if(TARGET dataModel)
message("dataModel is already defined")
else()

#include_directories(${SHARED_LIB_INCLUDE_DIR})
include_directories( ${CUDA_TOOLKIT_INCLUDE} 
	${CUDA_SDK_ROOT_DIR}/common/inc 
)

set(SRCS Volume.cpp Particle.cpp GLMatrixManager.cpp
	LabelVolumeProcessor.cpp
	AnimationByMatrixProcessor.cpp Trace.cpp
	TimeVaryingParticleDeformerManager.cpp #temporarily to speed up for testing...
	)
set(HDRS Volume.h Particle.h
 Processor.h 
    myDefine.h GLMatrixManager.h ColorGradient.h ScreenMarker.h
	LabelVolumeProcessor.h
	AnimationByMatrixProcessor.h
	MatrixManager.h
	myDefineRayCasting.h
	 Trace.h
	TimeVaryingParticleDeformerManager.h
)
add_library(${PROJECT_NAME}  STATIC ${HDRS} ${SRCS})

target_link_libraries(${PROJECT_NAME} 
	Qt5::Widgets  
	)



if(USE_VTK)
	find_package(VTK REQUIRED)
	include(${VTK_USE_FILE}) 
	set( HDRS ${HDRS} MarchingCube.h PolyMesh.h)
	set( SRCS ${SRCS} MarchingCube.cpp PolyMesh.cpp)
	target_link_libraries(${PROJECT_NAME} ${VTK_LIBRARIES})
endif()

endif()