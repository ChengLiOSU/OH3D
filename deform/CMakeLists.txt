cmake_minimum_required(VERSION 2.6)
project(deform)
set(SHARED_LIB_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR})
set(SHARED_LIB_INCLUDE_DIR ${SHARED_LIB_INCLUDE_DIR} PARENT_SCOPE)

find_package(CUDA REQUIRED)

list(APPEND CUDA_NVCC_FLAGS "-arch=sm_50;-std=c++11;-DVERBOSE")
#SET(CUDA_PROPAGATE_HOST_FLAGS OFF)

if(TARGET deform)
	message("deform is already defined")
else()

include_directories(${SHARED_LIB_INCLUDE_DIR}
	${CUDA_TOOLKIT_INCLUDE}
 	${CUDA_SDK_ROOT_DIR}/common/inc 
)

set(SRCS 
	Lens.cpp
	ScreenLensDisplaceProcessor.cu 
	MeshDeformProcessor.cu
	PhysicalVolumeDeformProcessor.cu
	PhysicalParticleDeformProcessor.cu
	)

set(HDRS	Lens.h
			GridMesh.h
			LineSplitGridMesh.h
			MeshDeformProcessor.h
			TransformFunc.h
			PhysicalVolumeDeformProcessor.h
			PhysicalParticleDeformProcessor.h
			ScreenLensDisplaceProcessor.h
			)

if(BUILD_TEST)
	set(HDRS ${HDRS} PositionBasedDeformProcessor.h)
	set(SRCS ${SRCS} PositionBasedDeformProcessor.cu)
endif()

cuda_add_library(${PROJECT_NAME}  STATIC ${HDRS} ${SRCS})
set(CUDA_NVCC_FLAGS_DEBUG "-g -G")

endif()
