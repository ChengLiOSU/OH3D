#include "PositionBasedDeformProcessor.h"
#include "TransformFunc.h"
#include "MatrixManager.h"

#include "Volume.h"
#include "PolyMesh.h"
#include "Particle.h"

#include <cuda_runtime.h>
#include <helper_cuda.h>
#include <helper_math.h>


//!!! NOTE !!! spacing not considered yet!!!! in the global functions

#define USED_FOR_TV

//#ifdef USED_FOR_TV
//typedef int channelVolumeVoxelType;
//#else
//typedef float channelVolumeVoxelType;
//#endif
typedef float channelVolumeVoxelType;


texture<float, 3, cudaReadModeElementType>  volumeTexInput;
surface<void, cudaSurfaceType3D>			volumeSurfaceOut;

texture<channelVolumeVoxelType, 3, cudaReadModeElementType>  channelVolumeTex;
surface<void, cudaSurfaceType3D>			channelVolumeSurface;

texture<int, 3, cudaReadModeElementType>  tvChannelVolumeTex;

PositionBasedDeformProcessor::PositionBasedDeformProcessor(std::shared_ptr<Volume> ori, std::shared_ptr<MatrixManager> _m, std::shared_ptr<Volume> ch)
{
	volume = ori;
	matrixMgr = _m;
	channelVolume = ch;
	spacing = volume->spacing;
	InitCudaSupplies();
	sdkCreateTimer(&timer);
	sdkCreateTimer(&timerFrame);

	dataType = VOLUME;
};

PositionBasedDeformProcessor::PositionBasedDeformProcessor(std::shared_ptr<PolyMesh> ori, std::shared_ptr<MatrixManager> _m, std::shared_ptr<Volume> ch)
{
	poly = ori;
	matrixMgr = _m;
	channelVolume = ch;
	spacing = channelVolume->spacing;

	sdkCreateTimer(&timer);
	sdkCreateTimer(&timerFrame);

	dataType = MESH;
	
	//NOTE!! here doubled the space. Hopefully it is large enough
	cudaMalloc(&d_vertexCoords, sizeof(float)*poly->vertexcount * 3 *2);
	cudaMalloc(&d_norms, sizeof(float)*poly->vertexcount * 3 * 2);
	cudaMalloc(&d_vertexCoords_init, sizeof(float)*poly->vertexcount * 3 * 2);
	cudaMalloc(&d_indices, sizeof(unsigned int)*poly->facecount * 3*2);
	//cudaMalloc(&d_faceValid, sizeof(bool)*poly->facecount);
	cudaMalloc(&d_numAddedFaces, sizeof(int));
	cudaMalloc(&d_vertexDeviateVals, sizeof(float)*poly->vertexcount * 2);
	cudaMalloc(&d_vertexColorVals, sizeof(float)*poly->vertexcount * 2);
};

PositionBasedDeformProcessor::PositionBasedDeformProcessor(std::shared_ptr<Particle> ori, std::shared_ptr<MatrixManager> _m, std::shared_ptr<Volume> ch)
{
	particle = ori;
	matrixMgr = _m;
	channelVolume = ch;
	spacing = channelVolume->spacing;

	InitCudaSupplies();
	sdkCreateTimer(&timer);
	sdkCreateTimer(&timerFrame);

	dataType = PARTICLE;

	d_vec_posOrig.assign(&(particle->pos[0]), &(particle->pos[0]) + particle->numParticles);
	d_vec_posTarget.assign(&(particle->pos[0]), &(particle->pos[0]) + particle->numParticles);
}

void PositionBasedDeformProcessor::updateParticleData(std::shared_ptr<Particle> ori)
{
	particle = ori;
	d_vec_posOrig.assign(&(particle->pos[0]), &(particle->pos[0]) + particle->numParticles);
	//d_vec_posTarget.assign(&(particle->pos[0]), &(particle->pos[0]) + particle->numParticles);
	
	//process(0, 0, 0, 0);

	if (lastDataState == DEFORMED){
		doParticleDeform(r);
	}
	else{

	}
}


__device__ bool inTunnel(float3 pos, float3 start, float3 end, float deformationScale, float deformationScaleVertical, float3 dir2nd)
{
	float3 tunnelVec = normalize(end - start);
	float tunnelLength = length(end - start);
	float3 voxelVec = pos - start;
	float l = dot(voxelVec, tunnelVec);
	if (l > 0 && l < tunnelLength){
		float disToStart = length(voxelVec);
		float l2 = dot(voxelVec, dir2nd);
		if (abs(l2) < deformationScaleVertical){
			float3 prjPoint = start + l*tunnelVec + l2*dir2nd;
			float3 dir = normalize(pos - prjPoint);
			float dis = length(pos - prjPoint);
			if (dis < deformationScale / 2.0){
				return true;
			}
		}
	}
	return false;
}

__device__ float3 sampleDis(float3 pos, float3 start, float3 end, float r, float deformationScaleVertical, float3 dir2nd)
{
	const float3 noChangeMark = make_float3(-1, -2, -3);
	const float3 emptyMark = make_float3(-3, -2, -1);

	float3 tunnelVec = normalize(end - start);
	float tunnelLength = length(end - start);

	float3 voxelVec = pos - start;
	float l = dot(voxelVec, tunnelVec);
	if (l > 0 && l < tunnelLength){
		float disToStart = length(voxelVec);
		float l2 = dot(voxelVec, dir2nd);
		if (abs(l2) < deformationScaleVertical){
			float3 prjPoint = start + l*tunnelVec + l2*dir2nd;
			float3 dir = normalize(pos - prjPoint);
			float dis = length(pos - prjPoint);

			if (dis < r / 2){
				return emptyMark;
			}
			else if (dis < r){
				float3 samplePos = prjPoint + dir*(r - (r - dis) * 2);
				return samplePos;
			}
			else{
				return noChangeMark;
			}
		}
		else{
			return noChangeMark;
		}
	}
	else{
		return noChangeMark;
	}
}



__global__ void
d_updateVolumebyMatrixInfo_rect(cudaExtent volumeSize, float3 start, float3 end, float3 spacing, float r, float deformationScale, float deformationScaleVertical, float3 dir2nd)
{
	int x = blockIdx.x*blockDim.x + threadIdx.x;
	int y = blockIdx.y*blockDim.y + threadIdx.y;
	int z = blockIdx.z*blockDim.z + threadIdx.z;

	if (x >= volumeSize.width || y >= volumeSize.height || z >= volumeSize.depth)
	{
		return;
	}

	float3 pos = make_float3(x, y, z) * spacing;

	float3 tunnelVec = normalize(end - start);
	float tunnelLength = length(end - start);

	float3 voxelVec = pos - start;
	float l = dot(voxelVec, tunnelVec);
	if (l > 0 && l < tunnelLength){
		float disToStart = length(voxelVec);
		float l2 = dot(voxelVec, dir2nd);
		if (abs(l2) < deformationScaleVertical){
			float3 prjPoint = start + l*tunnelVec + l2*dir2nd;
			float3 dir = normalize(pos - prjPoint);
			float dis = length(pos - prjPoint);

			if (dis < r){
				float res = 0;
				surf3Dwrite(res, volumeSurfaceOut, x * sizeof(float), y, z);
			}
			else if (dis < deformationScale){
				float3 prjPoint = start + l*tunnelVec + l2*dir2nd;
				float3 dir = normalize(pos - prjPoint);
				float3 samplePos = prjPoint + dir* (dis - r) / (deformationScale - r)*deformationScale; 
				samplePos /= spacing;

				float res = tex3D(volumeTexInput, samplePos.x + 0.5, samplePos.y + 0.5, samplePos.z + 0.5);
				surf3Dwrite(res, volumeSurfaceOut, x * sizeof(float), y, z);

			}
			else{
				float res = tex3D(volumeTexInput, x + 0.5, y + 0.5, z + 0.5);
				surf3Dwrite(res, volumeSurfaceOut, x * sizeof(float), y, z);
			}
		}
		else{
			float res = tex3D(volumeTexInput, x + 0.5, y + 0.5, z + 0.5);
			surf3Dwrite(res, volumeSurfaceOut, x * sizeof(float), y, z);
		}
	}
	else{
		float res = tex3D(volumeTexInput, x + 0.5, y + 0.5, z + 0.5);
		surf3Dwrite(res, volumeSurfaceOut, x * sizeof(float), y, z);
	}
	return;
}


__global__ void
d_updateVolumebyMatrixInfo_tunnel_rect(cudaExtent volumeSize, float3 start, float3 end, float3 spacing, float r, float deformationScale, float deformationScaleVertical, float3 dir2nd)
{
	int x = blockIdx.x*blockDim.x + threadIdx.x;
	int y = blockIdx.y*blockDim.y + threadIdx.y;
	int z = blockIdx.z*blockDim.z + threadIdx.z;

	if (x >= volumeSize.width || y >= volumeSize.height || z >= volumeSize.depth)
	{
		return;
	}

	float3 pos = make_float3(x, y, z) * spacing;
	float3 tunnelVec = normalize(end - start);
	float tunnelLength = length(end - start);

	float3 voxelVec = pos - start;
	float l = dot(voxelVec, tunnelVec);
	if (l > 0 && l < tunnelLength){
		float disToStart = length(voxelVec);
		float l2 = dot(voxelVec, dir2nd);
		if (abs(l2) < deformationScaleVertical){
			float3 prjPoint = start + l*tunnelVec + l2*dir2nd;
			float3 dir = normalize(pos - prjPoint);
			float dis = length(pos - prjPoint);

			if (dis < r / 2){
				channelVolumeVoxelType res2 = 1;
				surf3Dwrite(res2, channelVolumeSurface, x * sizeof(channelVolumeVoxelType), y, z);
			}
			else if (dis < deformationScale){
				float3 prjPoint = start + l*tunnelVec + l2*dir2nd;
				float3 dir = normalize(pos - prjPoint);
				float3 samplePos = prjPoint + dir* (dis - r) / (deformationScale - r)*deformationScale;
				
				samplePos /= spacing;
				channelVolumeVoxelType res2 = tex3D(channelVolumeTex, samplePos.x, samplePos.y, samplePos.z);
				surf3Dwrite(res2, channelVolumeSurface, x * sizeof(channelVolumeVoxelType), y, z);
			}
			else{
				channelVolumeVoxelType res2 = tex3D(channelVolumeTex, x, y, z);
				surf3Dwrite(res2, channelVolumeSurface, x * sizeof(channelVolumeVoxelType), y, z);
			}
		}
		else{
			channelVolumeVoxelType res2 = tex3D(channelVolumeTex, x, y, z);
			surf3Dwrite(res2, channelVolumeSurface, x * sizeof(channelVolumeVoxelType), y, z);
		}
	}
	else{
		channelVolumeVoxelType res2 = tex3D(channelVolumeTex, x, y, z);
		surf3Dwrite(res2, channelVolumeSurface, x * sizeof(channelVolumeVoxelType), y, z);
	}
	return;
}

__global__ void
d_posInDeformedChannelVolume(float3 pos, int3 dims, float3 spacing, bool* inChannel)
{
	float3 ind = pos / spacing;
	if (ind.x >= 0 && ind.x < dims.x && ind.y >= 0 && ind.y < dims.y && ind.z >= 0 && ind.z<dims.z) {
		channelVolumeVoxelType res = tex3D(channelVolumeTex, ind.x, ind.y, ind.z);
		if (res > 0.5)
			*inChannel = true;
		else
			*inChannel = false;
	}
	else{
		*inChannel = true;
	}
}


__global__ void d_updatePolyMeshbyMatrixInfo_rect(float* vertexCoords_init, float* vertexCoords, int vertexcount, 
	float3 start, float3 end, float3 spacing, float r, float deformationScale, float deformationScaleVertical, float3 dir2nd,
	float* vertexDeviateVals)
{
	int i = blockDim.x * blockIdx.x + threadIdx.x;
	if (i >= vertexcount)	return;
	vertexDeviateVals[i] = 0;
	
	float3 pos = make_float3(vertexCoords_init[3 * i], vertexCoords_init[3 * i + 1], vertexCoords_init[3 * i + 2]) * spacing;
	vertexCoords[3 * i] = pos.x;
	vertexCoords[3 * i + 1] = pos.y;
	vertexCoords[3 * i + 2] = pos.z;

	float3 tunnelVec = normalize(end - start);
	float tunnelLength = length(end - start);

	float3 voxelVec = pos - start;
	float l = dot(voxelVec, tunnelVec);
	if (l > 0 && l < tunnelLength){
		float l2 = dot(voxelVec, dir2nd);
		if (abs(l2) < deformationScaleVertical){
			float3 prjPoint = start + l*tunnelVec + l2*dir2nd;
			float dis = length(pos - prjPoint);

			//!!NOTE!! the case dis==0 is not processed!! suppose this case will not happen by some spacial preprocessing
			if (dis > 0 && dis < deformationScale){
				float3 dir = normalize(pos - prjPoint);

				float newDis = deformationScale - (deformationScale - dis) / deformationScale * (deformationScale - r);
				float3 newPos = prjPoint + newDis * dir;
				vertexCoords[3 * i] = newPos.x;
				vertexCoords[3 * i + 1] = newPos.y;
				vertexCoords[3 * i + 2] = newPos.z;

				vertexDeviateVals[i] = length(newPos - pos) / (deformationScale / 2); //value range [0,1]
			}
		}
	}

	return;
}

void PositionBasedDeformProcessor::doPolyDeform(float degree)
{
	if (!deformData)
		return;
	int threadsPerBlock = 64;
	int blocksPerGrid = (poly->vertexcount + threadsPerBlock - 1) / threadsPerBlock;

	d_updatePolyMeshbyMatrixInfo_rect << <blocksPerGrid, threadsPerBlock >> >(d_vertexCoords_init, d_vertexCoords, poly->vertexcount,
		tunnelStart, tunnelEnd, channelVolume->spacing, degree, deformationScale, deformationScaleVertical, rectVerticalDir, d_vertexDeviateVals);

	cudaMemcpy(poly->vertexCoords, d_vertexCoords, sizeof(float)*poly->vertexcount * 3, cudaMemcpyDeviceToHost);
	if (isColoringDeformedPart)
	{
		cudaMemcpy(poly->vertexDeviateVals, d_vertexDeviateVals, sizeof(float)*poly->vertexcount, cudaMemcpyDeviceToHost);
	}
}

struct functor_particleDeform
{
	int n;
	float3 start, end, dir2nd;
	float3 spacing;
	float r, deformationScale, deformationScaleVertical;
	
	template<typename Tuple>
	__device__ __host__ void operator() (Tuple t){//float2 screenPos, float4 clipPos) {
		float4 posf4 = thrust::get<0>(t);
		float3 pos = make_float3(posf4.x, posf4.y, posf4.z) * spacing;
		float3 newPos;
		float3 tunnelVec = normalize(end - start);
		float tunnelLength = length(end - start);

		float3 voxelVec = pos - start;
		float l = dot(voxelVec, tunnelVec);
		if (l > 0 && l < tunnelLength){
			float disToStart = length(voxelVec);
			float l2 = dot(voxelVec, dir2nd);
			if (abs(l2) < deformationScaleVertical){
				float3 prjPoint = start + l*tunnelVec + l2*dir2nd;
				float3 dir = normalize(pos - prjPoint);
				float dis = length(pos - prjPoint);

				if (dis < deformationScale){
					float newDis = deformationScale - (deformationScale - dis) / deformationScale * (deformationScale - r);
					newPos = prjPoint + newDis * dir;
				}
				else{
					newPos = pos;
				}
			}
			else{
				newPos = pos;
			}
		}
		else{
			newPos = pos;
		}
		thrust::get<1>(t) = make_float4(newPos.x, newPos.y, newPos.z, 1);

	}


	functor_particleDeform(int _n, float3 _start, float3 _end, float3 _spacing, float _r, float _deformationScale, float _deformationScaleVertical, float3 _dir2nd)
		: n(_n), start(_start), end(_end), spacing(_spacing), r(_r), deformationScale(_deformationScale), deformationScaleVertical(_deformationScaleVertical), dir2nd(_dir2nd){}
};

void PositionBasedDeformProcessor::doParticleDeform(float degree)
{
	if (!deformData)
		return;
	int count = particle->numParticles;

	//for debug
//	std::vector<float4> tt(count);
//	//thrust::copy(tt.begin(), tt.end(), d_vec_posTarget.begin());
//	std::cout << "pos of region 0 before: " << tt[0].x << " " << tt[0].y << " " << tt[0].z << std::endl;

	thrust::for_each(
		thrust::make_zip_iterator(
		thrust::make_tuple(
		d_vec_posOrig.begin(),
		d_vec_posTarget.begin()
		)),
		thrust::make_zip_iterator(
		thrust::make_tuple(
		d_vec_posOrig.end(),
		d_vec_posTarget.end()
		)),
		functor_particleDeform(count, tunnelStart, tunnelEnd, channelVolume->spacing, degree, deformationScale, deformationScaleVertical, rectVerticalDir));

	thrust::copy(d_vec_posTarget.begin(), d_vec_posTarget.end(), &(particle->pos[0]));

//	std::cout << "moved particles by: " << degree <<" with count "<<count<< std::endl;
//	std::cout << "pos of region 0: " << particle->pos[0].x << " " << particle->pos[0].y << " " << particle->pos[0].z << std::endl;

}


void PositionBasedDeformProcessor::doVolumeDeform(float degree)
{
	if (!deformData)
		return;

	cudaExtent size = volume->volumeCuda.size;
	unsigned int dim = 32;
	dim3 blockSize(dim, dim, 1);
	dim3 gridSize(iDivUp(size.width, blockSize.x), iDivUp(size.height, blockSize.y), iDivUp(size.depth, blockSize.z));

	cudaChannelFormatDesc cd = volume->volumeCudaOri.channelDesc;
	checkCudaErrors(cudaBindTextureToArray(volumeTexInput, volume->volumeCudaOri.content, cd));
	checkCudaErrors(cudaBindSurfaceToArray(volumeSurfaceOut, volume->volumeCuda.content));

	d_updateVolumebyMatrixInfo_rect << <gridSize, blockSize >> >(size, tunnelStart, tunnelEnd, volume->spacing, degree, deformationScale, deformationScaleVertical, rectVerticalDir);
	checkCudaErrors(cudaUnbindTexture(volumeTexInput));
}

void PositionBasedDeformProcessor::doVolumeDeform2Tunnel(float degree, float degreeClose)
{
	cudaExtent size = volume->volumeCuda.size;
	unsigned int dim = 32;
	dim3 blockSize(dim, dim, 1);
	dim3 gridSize(iDivUp(size.width, blockSize.x), iDivUp(size.height, blockSize.y), iDivUp(size.depth, blockSize.z));

	cudaChannelFormatDesc cd = volume->volumeCudaOri.channelDesc;
	
	checkCudaErrors(cudaBindTextureToArray(volumeTexInput, volume->volumeCudaOri.content, cd));
	checkCudaErrors(cudaBindSurfaceToArray(volumeSurfaceOut, volumeCudaIntermediate->content));
	d_updateVolumebyMatrixInfo_rect << <gridSize, blockSize >> >(size, lastTunnelStart, lastTunnelEnd, volume->spacing, degreeClose, deformationScale, deformationScaleVertical, lastDeformationDirVertical);
	checkCudaErrors(cudaUnbindTexture(volumeTexInput));

	checkCudaErrors(cudaBindTextureToArray(volumeTexInput, volumeCudaIntermediate->content, cd));
	checkCudaErrors(cudaBindSurfaceToArray(volumeSurfaceOut, volume->volumeCuda.content));
	d_updateVolumebyMatrixInfo_rect << <gridSize, blockSize >> >(size, tunnelStart, tunnelEnd, volume->spacing, degree, deformationScale, deformationScaleVertical, rectVerticalDir); //this function is not changed for time varying particle data yet

	checkCudaErrors(cudaUnbindTexture(volumeTexInput));

}

void PositionBasedDeformProcessor::doChannelVolumeDeform()
{
	cudaExtent size = channelVolume->volumeCuda.size;
	unsigned int dim = 32;
	dim3 blockSize(dim, dim, 1);
	dim3 gridSize(iDivUp(size.width, blockSize.x), iDivUp(size.height, blockSize.y), iDivUp(size.depth, blockSize.z));

	cudaChannelFormatDesc cd2 = channelVolume->volumeCuda.channelDesc;
	checkCudaErrors(cudaBindTextureToArray(channelVolumeTex, channelVolume->volumeCudaOri.content, cd2));
	checkCudaErrors(cudaBindSurfaceToArray(channelVolumeSurface, channelVolume->volumeCuda.content));

	d_updateVolumebyMatrixInfo_tunnel_rect << <gridSize, blockSize >> >(size, tunnelStart, tunnelEnd, channelVolume->spacing, deformationScale, deformationScale, deformationScaleVertical, rectVerticalDir);
	checkCudaErrors(cudaUnbindTexture(channelVolumeTex));
}

__global__ void
d_checkPlane(float3 planeCenter, int3 size, float3 spacing, float3 dir_y, float3 dir_z, int ycount, int zcount, bool* d_inchannel)
{
	int i = blockDim.x * blockIdx.x + threadIdx.x;
	if (i >= ycount * zcount)	return;

	int z = i / ycount;
	int y = i - z * ycount;
	z = z - zcount / 2;
	y = y - ycount / 2;
	float3 v = planeCenter + y*dir_y + z*dir_z;
	
	//assume spacing (1,1,1)
	if (v.x >= 0 && v.x < size.x && v.y >= 0 && v.y < size.y && v.z >= 0 && v.z < size.z){
		channelVolumeVoxelType res = tex3D(channelVolumeTex, v.x, v.y, v.z);
		if (res < 0.5){
			*d_inchannel = true;
		}
	}
}

void PositionBasedDeformProcessor::computeTunnelInfo(float3 centerPoint)
{
	if (isForceDeform) //just for testing, may not be precise
	{
		//when this funciton is called, suppose we already know that centerPoint is not inWall
		float3 tunnelAxis = normalize(matrixMgr->getViewVecInLocal());
		//rectVerticalDir = targetUpVecInLocal;
		if (abs(dot(targetUpVecInLocal, tunnelAxis)) < 0.9){
			rectVerticalDir = normalize(cross(cross(tunnelAxis, targetUpVecInLocal), tunnelAxis));
		}
		else{
			rectVerticalDir = matrixMgr->getViewVecInLocal();
		}

		//old method
		float step = 0.5;
		tunnelStart = centerPoint;
		//while (!channelVolume->inRange(tunnelStart / spacing) || channelVolume->getVoxel(tunnelStart / spacing) > 0.5){
		while (!channelVolume->inRange(tunnelStart / spacing) || inChannelInOriData(tunnelStart / spacing)){
			tunnelStart += tunnelAxis*step;
		}
		tunnelEnd = tunnelStart + tunnelAxis*step;
		//while (channelVolume->inRange(tunnelEnd / spacing) && channelVolume->getVoxel(tunnelEnd / spacing) < 0.5){
		while (channelVolume->inRange(tunnelEnd / spacing) && !inChannelInOriData(tunnelEnd / spacing)){
			tunnelEnd += tunnelAxis*step;
		}



		/* //new method

		//when this funciton is called, suppose we already know that centerPoint is NOT inWall
		float3 tunnelAxis = normalize(matrixMgr->getViewVecInLocal());
		//rectVerticalDir = targetUpVecInLocal;
		if (abs(dot(targetUpVecInLocal, tunnelAxis)) < 0.9){
			rectVerticalDir = normalize(cross(cross(tunnelAxis, targetUpVecInLocal), tunnelAxis));
		}
		else{
			rectVerticalDir = matrixMgr->getViewVecInLocal();
		}

		float step = 1;

		bool* d_planeHasSolid;
		cudaMalloc(&d_planeHasSolid, sizeof(bool)* 1);
		cudaChannelFormatDesc cd2 = channelVolume->volumeCudaOri.channelDesc;
		checkCudaErrors(cudaBindTextureToArray(channelVolumeTex, channelVolume->volumeCudaOri.content, cd2));

		int ycount = ceil(deformationScale) * 2 + 1;
		int zcount = ceil(deformationScaleVertical) * 2 + 1;
		int threadsPerBlock = 64;
		int blocksPerGrid = (ycount*zcount + threadsPerBlock - 1) / threadsPerBlock;

		float3 dir_y = normalize(cross(rectVerticalDir, tunnelAxis));

		tunnelStart = centerPoint;
		bool startNotFound = true;
		while (startNotFound){
			tunnelStart += tunnelAxis*step;
			bool temp = false;
			cudaMemcpy(d_planeHasSolid, &temp, sizeof(bool)* 1, cudaMemcpyHostToDevice);
			d_checkPlane << <blocksPerGrid, threadsPerBlock >> >(tunnelStart, channelVolume->size, channelVolume->spacing, dir_y, rectVerticalDir, ycount, zcount, d_planeHasSolid);
			cudaMemcpy(&startNotFound, d_planeHasSolid, sizeof(bool)* 1, cudaMemcpyDeviceToHost);
			startNotFound = !startNotFound;
		}

		tunnelEnd = tunnelStart;
		bool endNotFound = true;
		while (endNotFound){
			tunnelEnd += tunnelAxis*step;
			bool temp = false;
			cudaMemcpy(d_planeHasSolid, &temp, sizeof(bool)* 1, cudaMemcpyHostToDevice);
			d_checkPlane << <blocksPerGrid, threadsPerBlock >> >(tunnelEnd, channelVolume->size, channelVolume->spacing, dir_y, rectVerticalDir, ycount, zcount, d_planeHasSolid);
			cudaMemcpy(&endNotFound, d_planeHasSolid, sizeof(bool)* 1, cudaMemcpyDeviceToHost);
		}

		std::cout << "tunnelStart: " << tunnelStart.x << " " << tunnelStart.y << " " << tunnelStart.z << std::endl;
		std::cout << "centerPoint: " << centerPoint.x << " " << centerPoint.y << " " << centerPoint.z << std::endl;
		std::cout << "tunnelEnd: " << tunnelEnd.x << " " << tunnelEnd.y << " " << tunnelEnd.z << std::endl << std::endl;
		cudaFree(d_planeHasSolid);
		*/
	}
	else{	
		//when this funciton is called, suppose we already know that centerPoint is inWall
		float3 tunnelAxis = normalize(matrixMgr->getViewVecInLocal());
		//rectVerticalDir = targetUpVecInLocal;
		if (abs(dot(targetUpVecInLocal, tunnelAxis)) < 0.9){
			rectVerticalDir = normalize(cross(cross(tunnelAxis, targetUpVecInLocal), tunnelAxis));
		}
		else{
			rectVerticalDir = matrixMgr->getViewVecInLocal();
		}

		
		//old method
		float step = 0.5;
		tunnelEnd = centerPoint + tunnelAxis*step;
		//while (channelVolume->inRange(tunnelEnd / spacing) && channelVolume->getVoxel(tunnelEnd / spacing) < 0.5){
		while (channelVolume->inRange(tunnelEnd / spacing) && !inChannelInOriData(tunnelEnd / spacing)){
			tunnelEnd += tunnelAxis*step;
		}
		tunnelStart = centerPoint;
		//while (channelVolume->inRange(tunnelStart / spacing) && channelVolume->getVoxel(tunnelStart / spacing) < 0.5){	
		while (channelVolume->inRange(tunnelStart / spacing) && !inChannelInOriData(tunnelStart / spacing)){
			tunnelStart -= tunnelAxis*step;
		}
		

		/* //new method
		float step = 1;

		bool* d_planeHasSolid;
		cudaMalloc(&d_planeHasSolid, sizeof(bool)* 1);
		cudaChannelFormatDesc cd2 = channelVolume->volumeCudaOri.channelDesc;
		checkCudaErrors(cudaBindTextureToArray(channelVolumeTex, channelVolume->volumeCudaOri.content, cd2));

		int ycount = ceil(deformationScale) * 2 + 1;
		int zcount = ceil(deformationScaleVertical) * 2 + 1;
		int threadsPerBlock = 64;
		int blocksPerGrid = (ycount*zcount + threadsPerBlock - 1) / threadsPerBlock;

		float3 dir_y = normalize(cross(rectVerticalDir, tunnelAxis));

		tunnelStart = centerPoint;
		bool startNotFound = true;
		while (startNotFound){
			tunnelStart -= tunnelAxis*step;
			bool temp = false;
			cudaMemcpy(d_planeHasSolid, &temp, sizeof(bool)* 1, cudaMemcpyHostToDevice);
			d_checkPlane << <blocksPerGrid, threadsPerBlock >> >(tunnelStart, channelVolume->size, channelVolume->spacing, dir_y, rectVerticalDir, ycount, zcount, d_planeHasSolid);
			cudaMemcpy(&startNotFound, d_planeHasSolid, sizeof(bool)* 1, cudaMemcpyDeviceToHost);
		}
		
		tunnelEnd = centerPoint;
		bool endNotFound = true;
		while (endNotFound){
			tunnelEnd += tunnelAxis*step;
			bool temp = false;
			cudaMemcpy(d_planeHasSolid, &temp, sizeof(bool)* 1, cudaMemcpyHostToDevice);
			d_checkPlane << <blocksPerGrid, threadsPerBlock >> >(tunnelEnd, channelVolume->size, channelVolume->spacing, dir_y, rectVerticalDir, ycount, zcount, d_planeHasSolid);
			cudaMemcpy(&endNotFound, d_planeHasSolid, sizeof(bool)* 1, cudaMemcpyDeviceToHost);
		}

		//std::cout << "tunnelStart: " << tunnelStart.x << " " << tunnelStart.y << " " << tunnelStart.z << std::endl;
		//std::cout << "centerPoint: " << centerPoint.x << " " << centerPoint.y << " " << centerPoint.z << std::endl;
		//std::cout << "tunnelEnd: " << tunnelEnd.x << " " << tunnelEnd.y << " " << tunnelEnd.z << std::endl << std::endl;
		cudaFree(d_planeHasSolid);
		*/
	}
}


bool PositionBasedDeformProcessor::inChannelInDeformedData(float3 pos)
{
	bool* d_inchannel;
	cudaMalloc(&d_inchannel, sizeof(bool)* 1);
	cudaChannelFormatDesc cd2 = channelVolume->volumeCudaOri.channelDesc;
	checkCudaErrors(cudaBindTextureToArray(channelVolumeTex, channelVolume->volumeCuda.content, cd2));
	d_posInDeformedChannelVolume << <1, 1 >> >(pos, channelVolume->size, channelVolume->spacing, d_inchannel);
	bool inchannel;
	cudaMemcpy(&inchannel, d_inchannel, sizeof(bool)* 1, cudaMemcpyDeviceToHost);
	cudaFree(d_inchannel);
	return inchannel;
}

bool PositionBasedDeformProcessor::inChannelInOriData(float3 pos)
{
	bool* d_inchannel;
	cudaMalloc(&d_inchannel, sizeof(bool)* 1);
	cudaChannelFormatDesc cd2 = channelVolume->volumeCudaOri.channelDesc;
	checkCudaErrors(cudaBindTextureToArray(channelVolumeTex, channelVolume->volumeCudaOri.content, cd2));
	d_posInDeformedChannelVolume << <1, 1 >> >(pos, channelVolume->size, channelVolume->spacing, d_inchannel);
	bool inchannel;
	cudaMemcpy(&inchannel, d_inchannel, sizeof(bool)* 1, cudaMemcpyDeviceToHost);
	cudaFree(d_inchannel);
	return inchannel;
}

__global__ void d_disturbVertex(float* vertexCoords, int vertexcount,
	float3 start, float3 end, float3 spacing, float deformationScaleVertical, float3 dir2nd)
{
	int i = blockDim.x * blockIdx.x + threadIdx.x;
	if (i >= vertexcount)	return;

	float3 pos = make_float3(vertexCoords[3 * i], vertexCoords[3 * i + 1], vertexCoords[3 * i + 2]) * spacing;
	vertexCoords[3 * i] = pos.x;
	vertexCoords[3 * i + 1] = pos.y;
	vertexCoords[3 * i + 2] = pos.z;

	float3 tunnelVec = normalize(end - start);
	float tunnelLength = length(end - start);
	
	float thr = 0.000001;
	float disturb = 0.00001;

	float3 n = normalize(cross(dir2nd, tunnelVec));
	float3 disturbVec = n*disturb;

	float3 voxelVec = pos - start;
	float l = dot(voxelVec, tunnelVec);
	if (l > 0 && l < tunnelLength){
		float l2 = dot(voxelVec, dir2nd);
		if (abs(l2) < deformationScaleVertical){
			float3 prjPoint = start + l*tunnelVec + l2*dir2nd;
			float dis = length(pos - prjPoint);

			//when dis==0 , disturb the vertex a little to avoid numerical error
			if (dis < thr){
				vertexCoords[3 * i] += disturbVec.x;
				vertexCoords[3 * i + 1] += disturbVec.y;
				vertexCoords[3 * i + 2] += disturbVec.z;
			}
		}
	}

	return;
}

__global__ void d_modifyMesh(float* vertexCoords, unsigned int* indices, int facecount, int vertexcount, float* norms, float3 start, float3 end, float3 spacing, float r, float deformationScale, float deformationScaleVertical, float3 dir2nd, int* numAddedFaces, float* vertexColorVals)
{
	int i = blockDim.x * blockIdx.x + threadIdx.x;
	if (i >= facecount)	return;


	uint3 inds = make_uint3(indices[3 * i], indices[3 * i + 1], indices[3 * i + 2]);
	float3 v1 = make_float3(vertexCoords[3 * inds.x], vertexCoords[3 * inds.x + 1], vertexCoords[3 * inds.x + 2]);
	float3 v2 = make_float3(vertexCoords[3 * inds.y], vertexCoords[3 * inds.y + 1], vertexCoords[3 * inds.y + 2]);
	float3 v3 = make_float3(vertexCoords[3 * inds.z], vertexCoords[3 * inds.z + 1], vertexCoords[3 * inds.z + 2]);
	
	float3 norm1 = make_float3(norms[3 * inds.x], norms[3 * inds.x + 1], norms[3 * inds.x + 2]);
	float3 norm2 = make_float3(norms[3 * inds.y], norms[3 * inds.y + 1], norms[3 * inds.y + 2]);
	float3 norm3 = make_float3(norms[3 * inds.z], norms[3 * inds.z + 1], norms[3 * inds.z + 2]);

	//suppose any 2 points of the triangle are not overlapping
	float dis12 = length(v2 - v1);
	float3 l12 = normalize(v2 - v1);
	float dis23 = length(v3 - v2);
	float3 l23 = normalize(v3 - v2);
	float dis31 = length(v1 - v3);
	float3 l31 = normalize(v1 - v3);

	float3 tunnelVec = normalize(end - start);
	float tunnelLength = length(end - start);
	
	//https://en.wikipedia.org/wiki/Line%E2%80%93plane_intersection
	float3 n = normalize(cross(dir2nd, tunnelVec));
	bool para12 = abs(dot(l12, n)) < 0.000001;
	bool para23 = abs(dot(l23, n)) < 0.000001;
	bool para31 = abs(dot(l31, n)) < 0.000001;
	float d12intersect = dot(start - v1, n) / (para12 ? 0.000001 : dot(l12, n));
	float d23intersect = dot(start - v2, n) / (para23 ? 0.000001 : dot(l23, n));
	float d31intersect = dot(start - v3, n) / (para31 ? 0.000001 : dot(l31, n));
	bool hasIntersect12 = (!para12) && d12intersect > 0 && d12intersect < dis12;
	bool hasIntersect23 = (!para23) && d23intersect > 0 && d23intersect < dis23;
	bool hasIntersect31 = (!para31) && d31intersect > 0 && d31intersect < dis31;


	int separateVectex, bottomV1, bottomV2;
	float3 intersect1, intersect2, disturb = 0.0001*n;
	float3 intersectNorm1, intersectNorm2; //temporary solution for norms
	//assume it is impossible that hasIntersect12 && hasIntersect23 && hasIntersect31
	if (hasIntersect12 && hasIntersect23){
		separateVectex = inds.y;// separateVectex = 2;
		if (dot(v2 - start, n) < 0) disturb = -disturb;
		bottomV1 = inds.x;
		bottomV2 = inds.z;
		intersect1 = v1 + d12intersect * l12;
		intersect2 = v2 + d23intersect * l23;

		intersectNorm1 = normalize((norm2 * d12intersect + norm1 * (dis12 - d12intersect)) / dis12);
		intersectNorm2 = normalize((norm3 * d23intersect + norm2 * (dis23 - d23intersect)) / dis23);
	}
	else if (hasIntersect23 && hasIntersect31){
		separateVectex = inds.z; // separateVectex = 3;
		if (dot(v3 - start, n) < 0) disturb = -disturb;
		bottomV1 = inds.y;
		bottomV2 = inds.x;
		intersect1 = v2 + d23intersect * l23;
		intersect2 = v3 + d31intersect * l31;

		intersectNorm1 = normalize((norm3 * d23intersect + norm2 * (dis23 - d23intersect)) / dis23);
		intersectNorm2 = normalize((norm1 * d31intersect + norm3 * (dis31 - d31intersect)) / dis31);
	}
	else if (hasIntersect31 && hasIntersect12){
		separateVectex = inds.x; //separateVectex = 1;
		if (dot(v1 - start, n) < 0) disturb = -disturb;
		bottomV1 = inds.z;
		bottomV2 = inds.y; 
		intersect1 = v3 + d31intersect * l31;
		intersect2 = v1 + d12intersect * l12;

		intersectNorm1 = normalize((norm1 * d31intersect + norm3 * (dis31 - d31intersect)) / dis31);
		intersectNorm2 = normalize((norm2 * d12intersect + norm1 * (dis12 - d12intersect)) / dis12);
	}
	//NOTE!!! one case is now missing. it is possible that only one of the three booleans is true
	else{
		return;
	}

	float projLength1long = dot(intersect1 - start, tunnelVec);
	float projLength1short = dot(intersect1 - start, dir2nd);
	float projLength2long = dot(intersect2 - start, tunnelVec);
	float projLength2short = dot(intersect2 - start, dir2nd);
	if ((projLength1long > 0 && projLength1long < tunnelLength && abs(projLength1short) < deformationScaleVertical)
		|| (projLength2long > 0 && projLength2long < tunnelLength && abs(projLength2short) < deformationScaleVertical)){
		indices[3 * i] = 0;
		indices[3 * i + 1] = 0;
		indices[3 * i + 2] = 0;

		int numAddedFacesBefore = atomicAdd(numAddedFaces, 3); //each divided triangle creates 3 new faces

		int curNumVertex = vertexcount + 4 * numAddedFacesBefore / 3; //each divided triangle creates 4 new vertex
		vertexCoords[3 * curNumVertex] = intersect1.x + disturb.x;
		vertexCoords[3 * curNumVertex + 1] = intersect1.y + disturb.y;
		vertexCoords[3 * curNumVertex + 2] = intersect1.z + disturb.z;
		vertexCoords[3 * (curNumVertex + 1)] = intersect2.x + disturb.x;
		vertexCoords[3 * (curNumVertex + 1) + 1] = intersect2.y + disturb.y;
		vertexCoords[3 * (curNumVertex + 1) + 2] = intersect2.z + disturb.z;
		vertexCoords[3 * (curNumVertex + 2)] = intersect1.x - disturb.x;
		vertexCoords[3 * (curNumVertex + 2) + 1] = intersect1.y - disturb.y;
		vertexCoords[3 * (curNumVertex + 2) + 2] = intersect1.z - disturb.z;
		vertexCoords[3 * (curNumVertex + 3)] = intersect2.x - disturb.x;
		vertexCoords[3 * (curNumVertex + 3) + 1] = intersect2.y - disturb.y;
		vertexCoords[3 * (curNumVertex + 3) + 2] = intersect2.z - disturb.z;


		vertexColorVals[curNumVertex] = vertexColorVals[separateVectex];
		vertexColorVals[curNumVertex + 1] = vertexColorVals[separateVectex];
		vertexColorVals[curNumVertex + 2] = vertexColorVals[separateVectex];
		vertexColorVals[curNumVertex + 3] = vertexColorVals[separateVectex];

		norms[3 * curNumVertex] = intersectNorm1.x;
		norms[3 * curNumVertex + 1] = intersectNorm1.y;
		norms[3 * curNumVertex + 2] = intersectNorm1.z;
		norms[3 * (curNumVertex + 1)] = intersectNorm2.x;
		norms[3 * (curNumVertex + 1) + 1] = intersectNorm2.y;
		norms[3 * (curNumVertex + 1) + 2] = intersectNorm2.z;
		norms[3 * (curNumVertex + 2)] = intersectNorm1.x;
		norms[3 * (curNumVertex + 2) + 1] = intersectNorm1.y;
		norms[3 * (curNumVertex + 2) + 2] = intersectNorm1.z;
		norms[3 * (curNumVertex + 3)] = intersectNorm2.x;
		norms[3 * (curNumVertex + 3) + 1] = intersectNorm2.y;
		norms[3 * (curNumVertex + 3) + 2] = intersectNorm2.z;


		int curNumFaces = numAddedFacesBefore + facecount;

		indices[3 * curNumFaces] = separateVectex;
		indices[3 * curNumFaces + 1] = curNumVertex + 1;  //order of vertex matters! use counter clockwise
		indices[3 * curNumFaces + 2] = curNumVertex;
		indices[3 * (curNumFaces + 1)] = bottomV1;
		indices[3 * (curNumFaces + 1) + 1] = curNumVertex + 2;
		indices[3 * (curNumFaces + 1) + 2] = curNumVertex + 3;
		indices[3 * (curNumFaces + 2)] = bottomV2;
		indices[3 * (curNumFaces + 2) + 1] = bottomV1;
		indices[3 * (curNumFaces + 2) + 2] = curNumVertex + 3;
	}
	else {
		return;
	}

}


void PositionBasedDeformProcessor::modifyPolyMesh()
{
	cudaMemcpy(d_vertexCoords, poly->vertexCoords, sizeof(float)*poly->vertexcount * 3, cudaMemcpyHostToDevice);
	cudaMemcpy(d_indices, poly->indices, sizeof(unsigned int)*poly->facecount * 3, cudaMemcpyHostToDevice);
	cudaMemcpy(d_norms, poly->vertexNorms, sizeof(float)*poly->vertexcount * 3, cudaMemcpyHostToDevice);

	cudaMemset(d_vertexDeviateVals, 0, sizeof(float)*poly->vertexcount * 2);
	cudaMemcpy(d_vertexColorVals, poly->vertexColorVals, sizeof(float)*poly->vertexcount, cudaMemcpyHostToDevice);

	cudaMemset(d_numAddedFaces, 0, sizeof(int));
	

	int threadsPerBlock = 64;
	int blocksPerGrid = (poly->vertexcount + threadsPerBlock - 1) / threadsPerBlock;

	d_disturbVertex << <blocksPerGrid, threadsPerBlock >> >(d_vertexCoords, poly->vertexcount,
		tunnelStart, tunnelEnd, channelVolume->spacing, deformationScaleVertical, rectVerticalDir);

	threadsPerBlock = 64;
	blocksPerGrid = (poly->facecount + threadsPerBlock - 1) / threadsPerBlock;
	d_modifyMesh << <blocksPerGrid, threadsPerBlock >> >(d_vertexCoords, d_indices, poly->facecountOri, poly->vertexcountOri, d_norms,
		tunnelStart, tunnelEnd, channelVolume->spacing, deformationScale, deformationScale, deformationScaleVertical, rectVerticalDir,
		d_numAddedFaces, d_vertexColorVals);
	
	int numAddedFaces;
	cudaMemcpy(&numAddedFaces, d_numAddedFaces, sizeof(int), cudaMemcpyDeviceToHost);
	std::cout << "added new face count " << numAddedFaces << std::endl;

	poly->facecount += numAddedFaces;
	poly->vertexcount += numAddedFaces / 3 * 4;

	std::cout << "old face count " << poly->facecountOri << std::endl;
	std::cout << "new face count " << poly->facecount << std::endl;
	std::cout << "old vertex count " << poly->vertexcountOri << std::endl;
	std::cout << "new vertex count " << poly->vertexcount << std::endl;

	cudaMemcpy(poly->indices, d_indices, sizeof(unsigned int)*poly->facecount * 3, cudaMemcpyDeviceToHost);
	cudaMemcpy(poly->vertexCoords, d_vertexCoords, sizeof(float)*poly->vertexcount * 3, cudaMemcpyDeviceToHost);
	cudaMemcpy(poly->vertexNorms, d_norms, sizeof(float)*poly->vertexcount * 3, cudaMemcpyDeviceToHost);
	cudaMemcpy(poly->vertexColorVals, d_vertexColorVals, sizeof(float)*poly->vertexcount, cudaMemcpyDeviceToHost);

	cudaMemcpy(d_vertexCoords_init, d_vertexCoords, sizeof(float)*poly->vertexcount * 3, cudaMemcpyDeviceToHost);
}


bool PositionBasedDeformProcessor::inRange(float3 v)
{
	if (dataType == VOLUME){
		return volume->inRange(v / spacing);
	}
	else if (dataType == MESH){
		return poly->inRange(v);
	}
	else if (dataType == PARTICLE){
		return channelVolume->inRange(v / spacing); //actually currently channelVolume->inRange will serve all possibilities. Keep 3 cases in case of unexpected needs.
	}
	else{
		std::cout << " inRange not implemented " << std::endl;
		exit(0);
	}
}

void PositionBasedDeformProcessor::deformDataByDegree(float r)
{
	if (dataType == VOLUME){
		doVolumeDeform(r);
	}
	else if (dataType == MESH){
		doPolyDeform(r);
	}
	else if (dataType == PARTICLE){
		doParticleDeform(r);
	}
	else{
		std::cout << " inRange not implemented " << std::endl;
		exit(0);
	}
}				

void PositionBasedDeformProcessor::deformDataByDegree2Tunnel(float r, float rClose)
{
	if (dataType == VOLUME){
		doVolumeDeform2Tunnel(r, rClose);
	}
	else if (dataType == MESH){
	}
	else if (dataType == PARTICLE){
	}
	else{
		std::cout << " inRange not implemented " << std::endl;
		exit(0);
	}

	return;
}

void PositionBasedDeformProcessor::resetData()
{
	if (dataType == VOLUME){
		volume->reset();

	}
	else if (dataType == MESH){
		poly->reset();
	}
	else if (dataType == PARTICLE){
		particle->reset();
		d_vec_posOrig.assign(&(particle->pos[0]), &(particle->pos[0]) + particle->numParticles);
		d_vec_posTarget.assign(&(particle->pos[0]), &(particle->pos[0]) + particle->numParticles);
	}
	else{
		std::cout << " inRange not implemented " << std::endl;
		exit(0);
	}
}


bool PositionBasedDeformProcessor::process(float* modelview, float* projection, int winWidth, int winHeight)
{
	if (!isActive)
		return false;

	float3 eyeInLocal = matrixMgr->getEyeInLocal();

	if (lastDataState == ORIGINAL){
		if (isForceDeform){
			//if (lastEyeState != inWall){
				lastDataState = DEFORMED;
				//lastEyeState = inWall;

				computeTunnelInfo(eyeInLocal);
				doChannelVolumeDeform();

				if (dataType == MESH){ //for poly data, the original data will be modified, which is not applicable to other types of data
					modifyPolyMesh();
				}

				//start a opening animation
				hasOpenAnimeStarted = true;
				hasCloseAnimeStarted = false; //currently if there is closing procedure for other tunnels, they are finished suddenly
				startOpen = std::clock();
			//}
			//else if (lastEyeState == inWall){
				//from wall to wall
			//}
		}
		//else if (inRange(eyeInLocal) && channelVolume->getVoxel(eyeInLocal / spacing) < 0.5){
		else if (inRange(eyeInLocal) && !inChannelInOriData(eyeInLocal / spacing)){	// in solid area
			// in this case, set the start of deformation
			if (lastEyeState != inWall){
				lastDataState = DEFORMED;
				lastEyeState = inWall;

				computeTunnelInfo(eyeInLocal);
				doChannelVolumeDeform();

				if (dataType == MESH){ //for poly data, the original data will be modified, which is not applicable to other types of data
					modifyPolyMesh();
				}

				//start a opening animation
				hasOpenAnimeStarted = true;
				hasCloseAnimeStarted = false; //currently if there is closing procedure for other tunnels, they are finished suddenly
				startOpen = std::clock();
			}
			else if (lastEyeState == inWall){
				//from wall to wall
			}
		}
		else{
			// either eyeInLocal is out of range, or eyeInLocal is in channel
			//in this case, no state change
		}
	}
	else{ //lastDataState == Deformed
		if (isForceDeform){

		}
		//else if (inRange(eyeInLocal) && channelVolume->getVoxel(eyeInLocal / spacing) < 0.5){
		else if (inRange(eyeInLocal) && !inChannelInOriData(eyeInLocal / spacing) ){
			//in area which is solid in the original volume
			bool inchannel = inChannelInDeformedData(eyeInLocal);
			if (inchannel){
				// not in the solid region in the deformed volume
				// in this case, no change
			}
			else{
				//std::cout <<"Triggered "<< lastDataState << " " << lastEyeState << " " << hasOpenAnimeStarted << " " << hasCloseAnimeStarted << std::endl;
				//even in the deformed volume, eye is still inside the solid region 
				//eye should just move to a solid region

				//poly->reset();
				//channelVolume->reset();

				sdkResetTimer(&timer);
				sdkStartTimer(&timer);

				sdkResetTimer(&timerFrame);

				fpsCount = 0;

				lastOpenFinalDegree = closeStartingRadius;
				lastDeformationDirVertical = rectVerticalDir;
				lastTunnelStart = tunnelStart;
				lastTunnelEnd = tunnelEnd;

				computeTunnelInfo(eyeInLocal);
				doChannelVolumeDeform();

				hasOpenAnimeStarted = true;//start a opening animation
				hasCloseAnimeStarted = true; //since eye should just moved to the current solid, the previous solid should be closed 
				startOpen = std::clock();
			}
		}
		else{// in area which is channel in the original volume
			hasCloseAnimeStarted = true;
			hasOpenAnimeStarted = false;
			startClose = std::clock();

			channelVolume->reset();
			lastDataState = ORIGINAL;
			lastEyeState = inCell;
		}
	}

	if (hasOpenAnimeStarted && hasCloseAnimeStarted){
		//std::cout << "processing as wanted" << std::endl;
		float rClose;
		double past = (std::clock() - startOpen) / (double)CLOCKS_PER_SEC;
		if (past >= totalDuration){
			r = deformationScale / 2;
			hasOpenAnimeStarted = false;
			hasCloseAnimeStarted = false;

			sdkStopTimer(&timer);
			std::cout << "Mixed animation fps: " << fpsCount / (sdkGetAverageTimerValue(&timer) / 1000.f) << std::endl;

			sdkStopTimer(&timer);
			std::cout << "Mixed animation cost each frame: " << sdkGetAverageTimerValue(&timerFrame) << " ms" << std::endl;
		}
		else{
			sdkStartTimer(&timerFrame);
			fpsCount++;

			r = past / totalDuration*deformationScale / 2;
			if (past >= closeDuration){
				hasCloseAnimeStarted = false;
				rClose = 0;
				deformDataByDegree(r);
			}
			else{
				rClose = (1 - past / closeDuration)*closeStartingRadius;
				//doVolumeDeform2Tunnel(r, rClose);  //TO BE IMPLEMENTED
				deformDataByDegree2Tunnel(r, rClose);
			}

			sdkStopTimer(&timerFrame);
		}
	}
	else if (hasOpenAnimeStarted){

		double past = (std::clock() - startOpen) / (double)CLOCKS_PER_SEC;
		if (past >= totalDuration){
			r = deformationScale / 2;
			hasOpenAnimeStarted = false;
			//closeStartingRadius = r;
			closeDuration = totalDuration;//or else closeDuration may be less than totalDuration
		}
		else{
			r = past / totalDuration*deformationScale / 2;
			deformDataByDegree(r);
			closeStartingRadius = r;
			closeDuration = past;
		}

		std::cout << "doing openning with r: " <<r<< std::endl;

	}
	else if (hasCloseAnimeStarted){
		//std::cout << "doing closing" << std::endl;

		double past = (std::clock() - startClose) / (double)CLOCKS_PER_SEC;
		if (past >= closeDuration){
			resetData();
			hasCloseAnimeStarted = false;
			r = 0;
		}
		else{
			r = (1 - past / closeDuration)*closeStartingRadius;
			deformDataByDegree(r);
		}
	}

	return false;
}


void PositionBasedDeformProcessor::InitCudaSupplies()
{
	volumeTexInput.normalized = false;
	volumeTexInput.filterMode = cudaFilterModeLinear;
	volumeTexInput.addressMode[0] = cudaAddressModeBorder;
	volumeTexInput.addressMode[1] = cudaAddressModeBorder;
	volumeTexInput.addressMode[2] = cudaAddressModeBorder;

	channelVolumeTex.normalized = false;
	channelVolumeTex.filterMode = cudaFilterModePoint;
	channelVolumeTex.addressMode[0] = cudaAddressModeBorder;
	channelVolumeTex.addressMode[1] = cudaAddressModeBorder;
	channelVolumeTex.addressMode[2] = cudaAddressModeBorder;

	tvChannelVolumeTex.normalized = false;
	tvChannelVolumeTex.filterMode = cudaFilterModePoint;
	tvChannelVolumeTex.addressMode[0] = cudaAddressModeBorder;
	tvChannelVolumeTex.addressMode[1] = cudaAddressModeBorder;
	tvChannelVolumeTex.addressMode[2] = cudaAddressModeBorder;
	
	if (volume != 0){
		//currently only for volume deformation
		volumeCudaIntermediate = std::make_shared<VolumeCUDA>();
		volumeCudaIntermediate->VolumeCUDA_deinit();
		volumeCudaIntermediate->VolumeCUDA_init(channelVolume->size, channelVolume->values, 1, 1);
		//volumeCudaIntermediate.VolumeCUDA_init(volume->size, 0, 1, 1);//??
	}
}



__global__ void d_transformChannelVolForTVDataFromExternal(cudaExtent volumeSize)
{
	int x = blockIdx.x*blockDim.x + threadIdx.x;
	int y = blockIdx.y*blockDim.y + threadIdx.y;
	int z = blockIdx.z*blockDim.z + threadIdx.z;

	if (x >= volumeSize.width || y >= volumeSize.height || z >= volumeSize.depth)
	{
		return;
	}

	int label = tex3D(tvChannelVolumeTex, x, y, z);
	if (label < 0){
		channelVolumeVoxelType outv = 1;
		surf3Dwrite(outv, channelVolumeSurface, x * sizeof(channelVolumeVoxelType), y, z);
	}
	else{
		channelVolumeVoxelType outv = 0;
		surf3Dwrite(outv, channelVolumeSurface, x * sizeof(channelVolumeVoxelType), y, z);
	}

	return;
}

void PositionBasedDeformProcessor::updateChannelWithTranformOfTVData(std::shared_ptr<Volume> v)
{
	std::cout << "value exchanged!! " << std::endl;
	cudaExtent size = v->volumeCuda.size;
	unsigned int dim = 32;
	dim3 blockSize(dim, dim, 1);
	dim3 gridSize(iDivUp(size.width, blockSize.x), iDivUp(size.height, blockSize.y), iDivUp(size.depth, blockSize.z));
	
	cudaChannelFormatDesc cd2 = v->volumeCudaOri.channelDesc;
	checkCudaErrors(cudaBindTextureToArray(tvChannelVolumeTex, v->volumeCudaOri.content, cd2));
	
	checkCudaErrors(cudaBindSurfaceToArray(channelVolumeSurface, channelVolume->volumeCudaOri.content));

	d_transformChannelVolForTVDataFromExternal << <gridSize, blockSize >> >(size);

	if (lastDataState == DEFORMED){
		doChannelVolumeDeform();
	}
	else{
		cudaMemcpy3DParms copyParams = { 0 };
		copyParams.srcArray = channelVolume->volumeCudaOri.content;
		copyParams.dstArray = channelVolume->volumeCuda.content;
		copyParams.extent = channelVolume->volumeCuda.size;
		copyParams.kind = cudaMemcpyDeviceToDevice;
		checkCudaErrors(cudaMemcpy3D(&copyParams));
	}
}


__global__ void d_setToBackground(cudaExtent volumeSize)
{
	int x = blockIdx.x*blockDim.x + threadIdx.x;
	int y = blockIdx.y*blockDim.y + threadIdx.y;
	int z = blockIdx.z*blockDim.z + threadIdx.z;

	if (x >= volumeSize.width || y >= volumeSize.height || z >= volumeSize.depth)
	{
		return;
	}

	channelVolumeVoxelType outv = 1;
	surf3Dwrite(outv, channelVolumeSurface, x * sizeof(channelVolumeVoxelType), y, z);

	return;
}


void PositionBasedDeformProcessor::initDeviceRegionMoveVec(int n)
{
	maxLabel = n;
	checkCudaErrors(cudaMalloc(&d_regionMoveVecs, sizeof(float)* (n + 1) * 3));
}

__global__ void d_MoveChannelVol(cudaExtent volumeSize, float* regionMoveVecs)
{
	int x = blockIdx.x*blockDim.x + threadIdx.x;
	int y = blockIdx.y*blockDim.y + threadIdx.y;
	int z = blockIdx.z*blockDim.z + threadIdx.z;

	if (x >= volumeSize.width || y >= volumeSize.height || z >= volumeSize.depth)
	{
		return;
	}


	int label = tex3D(tvChannelVolumeTex, x, y, z);
	if (label < 0){//do nothing
		return;
	}

	float3 moveVec = make_float3(regionMoveVecs[3 * label], regionMoveVecs[3 * label + 1], regionMoveVecs[3 * label + 2]);
	if (moveVec.x > 10000){
		return; //a marker to denote that this region does not exist in the next time step
	}
	int3 newPos = make_int3(x + moveVec.x, y + moveVec.y, z + moveVec.z);

	channelVolumeVoxelType outv = 0;
	surf3Dwrite(outv, channelVolumeSurface, newPos.x * sizeof(channelVolumeVoxelType), newPos.y, newPos.z);

	return;
}

void PositionBasedDeformProcessor::updateChannelWithTranformOfTVData_Intermediate(std::shared_ptr<Volume> v, const std::vector<float3> &regionMoveVec)
{
	cudaMemcpy(d_regionMoveVecs, &(regionMoveVec[0].x), sizeof(float)*(maxLabel + 1) * 3, cudaMemcpyHostToDevice);


	//std::cout << "value exchanged!! " << std::endl;
	cudaExtent size = v->volumeCuda.size;
	unsigned int dim = 32;
	dim3 blockSize(dim, dim, 1);
	dim3 gridSize(iDivUp(size.width, blockSize.x), iDivUp(size.height, blockSize.y), iDivUp(size.depth, blockSize.z));

	checkCudaErrors(cudaBindSurfaceToArray(channelVolumeSurface, channelVolume->volumeCudaOri.content));
	d_setToBackground << <gridSize, blockSize >> >(size);

	cudaChannelFormatDesc cd2 = v->volumeCudaOri.channelDesc;
	checkCudaErrors(cudaBindTextureToArray(tvChannelVolumeTex, v->volumeCudaOri.content, cd2));

	d_MoveChannelVol << <gridSize, blockSize >> >(size, d_regionMoveVecs);

	if (lastDataState == DEFORMED){
		doChannelVolumeDeform();
	}
	else{
		cudaMemcpy3DParms copyParams = { 0 };
		copyParams.srcArray = channelVolume->volumeCudaOri.content;
		copyParams.dstArray = channelVolume->volumeCuda.content;
		copyParams.extent = channelVolume->volumeCuda.size;
		copyParams.kind = cudaMemcpyDeviceToDevice;
		checkCudaErrors(cudaMemcpy3D(&copyParams));
	}
}