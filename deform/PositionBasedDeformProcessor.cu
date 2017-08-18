#include "PositionBasedDeformProcessor.h"
#include "Lens.h"
#include "MeshDeformProcessor.h"
#include "TransformFunc.h"
#include "MatrixManager.h"

#include "Volume.h"
#include "PolyMesh.h"
#include "Particle.h"

#include <cuda_runtime.h>
#include <helper_cuda.h>
#include <helper_math.h>


//!!! NOTE !!! spacing not considered yet!!!! in the global functions


texture<float, 3, cudaReadModeElementType>  volumeTexInput;
surface<void, cudaSurfaceType3D>			volumeSurfaceOut;

texture<float, 3, cudaReadModeElementType>  channelVolumeTex;
surface<void, cudaSurfaceType3D>			channelVolumeSurface;



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
	cudaMalloc(&d_vertexColordVals, sizeof(float)*poly->vertexcount * 2);
};

PositionBasedDeformProcessor::PositionBasedDeformProcessor(std::shared_ptr<Particle> ori, std::shared_ptr<MatrixManager> _m, std::shared_ptr<Volume> ch)
{
	particle = ori;
	matrixMgr = _m;
	channelVolume = ch;
	spacing = channelVolume->spacing;

	sdkCreateTimer(&timer);
	sdkCreateTimer(&timerFrame);

	dataType = PARTICLE;

	d_vec_posOrig.assign(&(particle->pos[0]), &(particle->pos[0]) + particle->numParticles);
	d_vec_posTarget.assign(&(particle->pos[0]), &(particle->pos[0]) + particle->numParticles);
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
				float res2 = 1;
				surf3Dwrite(res2, channelVolumeSurface, x * sizeof(float), y, z);
			}
			else if (dis < deformationScale){
				float3 prjPoint = start + l*tunnelVec + l2*dir2nd;
				float3 dir = normalize(pos - prjPoint);
				float3 samplePos = prjPoint + dir* (dis - r) / (deformationScale - r)*deformationScale;
				
				samplePos /= spacing;
				float res2 = tex3D(channelVolumeTex, samplePos.x, samplePos.y, samplePos.z);
				surf3Dwrite(res2, channelVolumeSurface, x * sizeof(float), y, z);
			}
			else{
				float res2 = tex3D(channelVolumeTex, x, y, z);
				surf3Dwrite(res2, channelVolumeSurface, x * sizeof(float), y, z);
			}
		}
		else{
			float res2 = tex3D(channelVolumeTex, x, y, z);
			surf3Dwrite(res2, channelVolumeSurface, x * sizeof(float), y, z);
		}
	}
	else{
		float res2 = tex3D(channelVolumeTex, x, y, z);
		surf3Dwrite(res2, channelVolumeSurface, x * sizeof(float), y, z);
	}
	return;
}

__global__ void
d_posInDeformedChannelVolume(float3 pos, int3 dims, float3 spacing, bool* inChannel)
{
	float3 ind = pos / spacing;
	if (ind.x >= 0 && ind.x < dims.x && ind.y >= 0 && ind.y < dims.y && ind.z >= 0 && ind.z<dims.z) {
		float res = tex3D(channelVolumeTex, ind.x, ind.y, ind.z);
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
	float* vertexColordVals)
{
	int i = blockDim.x * blockIdx.x + threadIdx.x;
	if (i >= vertexcount)	return;
	vertexColordVals[i] = 0;

	float3 pos = make_float3(vertexCoords_init[3 * i], vertexCoords_init[3 * i + 1], vertexCoords_init[3 * i + 2]) * spacing;

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
				float3 newPos = prjPoint + newDis * dir;
				vertexCoords[3 * i] = newPos.x;
				vertexCoords[3 * i + 1] = newPos.y;
				vertexCoords[3 * i + 2] = newPos.z;

				vertexColordVals[i] = length(newPos - pos) / (deformationScale / 2); //value range [0,1]
			}
			else{
				vertexCoords[3 * i] = pos.x;
				vertexCoords[3 * i + 1] = pos.y;
				vertexCoords[3 * i + 2] = pos.z;
			}
		}
		else{
			vertexCoords[3 * i] = pos.x;
			vertexCoords[3 * i + 1] = pos.y;
			vertexCoords[3 * i + 2] = pos.z;
		}
	}
	else{
		vertexCoords[3 * i] = pos.x;
		vertexCoords[3 * i + 1] = pos.y;
		vertexCoords[3 * i + 2] = pos.z;
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
		tunnelStart, tunnelEnd, channelVolume->spacing, degree, deformationScale, deformationScaleVertical, rectVerticalDir, d_vertexColordVals);

	cudaMemcpy(poly->vertexCoords, d_vertexCoords, sizeof(float)*poly->vertexcount * 3, cudaMemcpyDeviceToHost);
	if (isColoringDeformedPart)
	{
		cudaMemcpy(poly->vertexColorVals, d_vertexColordVals, sizeof(float)*poly->vertexcount, cudaMemcpyDeviceToHost);
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
	//checkCudaErrors(cudaUnbindTexture(channelVolumeTex));
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
	d_updateVolumebyMatrixInfo_rect << <gridSize, blockSize >> >(size, tunnelStart, tunnelEnd, volume->spacing, degree, deformationScale, deformationScaleVertical, rectVerticalDir);
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


void PositionBasedDeformProcessor::computeTunnelInfo(float3 centerPoint)
{
	//when this funciton is called, suppose we already know that centerPoint is inWall

	//float3 tunnelAxis = normalize(matrixMgr->recentMove);
	float3 tunnelAxis = normalize(matrixMgr->getViewVecInLocal());

	////note!! currently start and end are interchangable
	//float3 recentMove = normalize(matrixMgr->recentMove);
	//if (dot(recentMove, tunnelAxis) < -0.9){
	//	tunnelAxis = -tunnelAxis;
	//}

	float step = 0.5;
	
	tunnelEnd = centerPoint + tunnelAxis*step;
	while (channelVolume->inRange(tunnelEnd / spacing) && channelVolume->getVoxel(tunnelEnd / spacing) < 0.5){
		tunnelEnd += tunnelAxis*step;
	}
	
	tunnelStart = centerPoint;
	while (channelVolume->inRange(tunnelStart / spacing) && channelVolume->getVoxel(tunnelStart / spacing) < 0.5){
		tunnelStart -= tunnelAxis*step;
	}

	//rectVerticalDir = targetUpVecInLocal;
	if (abs(dot(targetUpVecInLocal, tunnelAxis)) < 0.9){
		rectVerticalDir = normalize(cross(cross(tunnelAxis, targetUpVecInLocal), tunnelAxis));
	}
	else{
		rectVerticalDir = matrixMgr->getViewVecInLocal();
	}
	//std::cout << "rectVerticalDir: " << rectVerticalDir.x << " " << rectVerticalDir.y << " " << rectVerticalDir.z << std::endl;
}


bool PositionBasedDeformProcessor::inDeformedCell(float3 pos)
{
	bool* d_inchannel;
	cudaMalloc(&d_inchannel, sizeof(bool)* 1);
	cudaChannelFormatDesc cd2 = channelVolume->volumeCudaOri.channelDesc;
	checkCudaErrors(cudaBindTextureToArray(channelVolumeTex, channelVolume->volumeCuda.content, cd2));
	d_posInDeformedChannelVolume << <1, 1 >> >(pos, channelVolume->size, channelVolume->spacing, d_inchannel);
	bool inchannel;
	cudaMemcpy(&inchannel, d_inchannel, sizeof(bool)* 1, cudaMemcpyDeviceToHost);
	return inchannel;
}


__global__ void d_modifyMesh(float* vertexCoords, unsigned int* indices, int facecount, int vertexcount, float* norms, 	float3 start, float3 end, float3 spacing, float r, float deformationScale, float deformationScaleVertical, float3 dir2nd, int* numAddedFaces)
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
		indices[3 * curNumFaces + 1] = curNumVertex+1;  //order of vertex matters! use counter clockwise
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
	int threadsPerBlock = 64;
	int blocksPerGrid = (poly->facecount + threadsPerBlock - 1) / threadsPerBlock;

	cudaMemcpy(d_vertexCoords, poly->vertexCoords, sizeof(float)*poly->vertexcount * 3, cudaMemcpyHostToDevice);
	cudaMemcpy(d_indices, poly->indices, sizeof(unsigned int)*poly->facecount * 3, cudaMemcpyHostToDevice);
	cudaMemcpy(d_norms, poly->vertexNorms, sizeof(float)*poly->vertexcount * 3, cudaMemcpyHostToDevice);

	cudaMemset(d_vertexColordVals, 0, sizeof(float)*poly->vertexcount * 2);

	cudaMemset(d_numAddedFaces, 0, sizeof(int));

	d_modifyMesh << <blocksPerGrid, threadsPerBlock >> >(d_vertexCoords, d_indices, poly->facecountOri, poly->vertexcountOri, d_norms,
		tunnelStart, tunnelEnd, channelVolume->spacing, deformationScale, deformationScale, deformationScaleVertical, rectVerticalDir,
		d_numAddedFaces);
	
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
		if (inRange(eyeInLocal) && channelVolume->getVoxel(eyeInLocal / spacing) < 0.5){
			// in solid area
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
		if (inRange(eyeInLocal) && channelVolume->getVoxel(eyeInLocal / spacing) < 0.5){
			//in area which is solid in the original volume
			bool inchannel = inDeformedCell(eyeInLocal);
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
		//std::cout << "doing openning" << std::endl;

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

	volumeCudaIntermediate = std::make_shared<VolumeCUDA>();
	volumeCudaIntermediate->VolumeCUDA_deinit();
	volumeCudaIntermediate->VolumeCUDA_init(volume->size, volume->values, 1, 1); 
	//	volumeCudaIntermediate.VolumeCUDA_init(volume->size, 0, 1, 1);//??
}

