#ifndef VOLUME_H
#define VOLUME_H

#include <stdio.h>
#include <stdlib.h>

#include <math.h>
#include <memory>
#include <string>
#include <iostream>

#include <cuda_runtime.h>
#include <helper_cuda.h>

#include "myDefine.h"

typedef float VolumeType;

class VolumeCUDA
{
public:
	cudaExtent size;
	cudaArray *content = 0;
	cudaChannelFormatDesc channelDesc;
	
	void VolumeCUDA_init(int3 _size, float *volumeVoxelValues, int allowStore, int numChannels = 1);
	void VolumeCUDA_init(int3 _size, unsigned short *volumeVoxelValues, int allowStore, int numChannels = 1);
	void VolumeCUDA_contentUpdate(unsigned short *volumeVoxelValues, int allowStore, int numChannels = 1);


	~VolumeCUDA();

	void VolumeCUDA_deinit();
};



class Volume
{
public:

	int3 size;
	
	float *values = 0; //used to store the voxel values. generally normalized to [0,1] if used for volume rendering

	//float getVoxel(int3 v){
	//	return values[v.z*size.x*size.y + v.y*size.x + v.x];
	//};

	float getVoxel(float3 v){
		return values[int(v.z)*size.x*size.y + int(v.y)*size.x + int(v.x)];
	};
	bool inRange(float3 v){
		return v.x >= 0 && v.x < size.x && v.y >= 0 && v.y < size.y &&v.z >= 0 && v.z < size.z;
	}
	void setSize(int3 s){ 
		size = s;
		if (values != 0){
			delete values;
		}
		values = new float[size.x*size.y*size.z];
		memset(values, 0, sizeof(float)*size.x*size.y*size.z);
	};

	Volume(bool _so = false){ originSaved = _so; };
	//Volume(){ };

	~Volume()
	{
		if (!values) delete values;
	};


	float3 spacing = make_float3(1.0,1.0,1.0);
	float3 dataOrigin = make_float3(0, 0, 0);
	void GetPosRange(float3& posMin, float3& posMax);

	bool originSaved;
	VolumeCUDA volumeCudaOri;
	VolumeCUDA volumeCuda; //using two copies, since the volumeCuda might be deformed

	void initVolumeCuda();
	void reset();

	void saveRawToFile(const char *);

	static void rawFileInfo(std::string dataPath, int3 & dims, float3 &spacing, std::shared_ptr<RayCastingParameters> & rcp, std::string  &subfolder)
	{
		if (std::string(dataPath).find("MGHT2") != std::string::npos){
			dims = make_int3(320, 320, 256);
			spacing = make_float3(0.7f, 0.7f, 0.7f);
		}
		else if (std::string(dataPath).find("MGHT1") != std::string::npos){
			dims = make_int3(256, 256, 176);
			spacing = make_float3(1.0f, 1.0f, 1.0f);
			rcp = std::make_shared<RayCastingParameters>(1.0, 0.2, 0.7, 0.44, 0.29, 1.25, 512, 0.25f, 1.3, false);
		}
		else if (std::string(dataPath).find("nek128") != std::string::npos){
			dims = make_int3(128, 128, 128);
			spacing = make_float3(2, 2, 2); //to fit the streamline of nek256
		}
		else if (std::string(dataPath).find("nek256") != std::string::npos){
			dims = make_int3(256, 256, 256);
			spacing = make_float3(1, 1, 1);
		}
		else if (std::string(dataPath).find("cthead") != std::string::npos){
			dims = make_int3(208, 256, 225);
			spacing = make_float3(1, 1, 1);
		}
		else if (std::string(dataPath).find("brat") != std::string::npos){
			dims = make_int3(160, 216, 176);
			spacing = make_float3(1, 1, 1);
			rcp = std::make_shared<RayCastingParameters>(1.0, 0.2, 0.7, 0.44, 0.25, 1.25, 512, 0.25f, 1.3, false); //for brat
		}
		else if (std::string(dataPath).find("engine") != std::string::npos){
			dims = make_int3(149, 208, 110);
			spacing = make_float3(1, 1, 1);
			rcp = std::make_shared<RayCastingParameters>(0.8, 0.4, 1.2, 1.0, 0.05, 1.25, 512, 0.25f, 1.0, false);
			subfolder = "engine";
		}
		else if (std::string(dataPath).find("knee") != std::string::npos){
			dims = make_int3(379, 229, 305);
			spacing = make_float3(1, 1, 1);
		}
		else if (std::string(dataPath).find("181") != std::string::npos){
			dims = make_int3(181, 217, 181);
			spacing = make_float3(1, 1, 1);
			rcp = std::make_shared<RayCastingParameters>(1.8, 1.0, 1.5, 1.0, 0.3, 2.6, 512, 0.25f, 1.0, false); //for 181
			subfolder = "181";
		}
		else{
			std::cout << "volume data name not recognized" << std::endl;
			exit(0);
		}
	};
};
#endif