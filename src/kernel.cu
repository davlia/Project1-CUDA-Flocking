#define GLM_FORCE_CUDA
#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include <glm/glm.hpp>
#include "utilityCore.hpp"
#include "kernel.h"

#ifndef imax
#define imax( a, b ) ( ((a) > (b)) ? (a) : (b) )
#endif

#ifndef imin
#define imin( a, b ) ( ((a) < (b)) ? (a) : (b) )
#endif

#define checkCUDAErrorWithLine(msg) checkCUDAError(msg, __LINE__)

/**
* Check for CUDA errors; print and exit if there was a problem.
*/
void checkCUDAError(const char *msg, int line = -1) {
  cudaError_t err = cudaGetLastError();
  if (cudaSuccess != err) {
    if (line >= 0) {
      fprintf(stderr, "Line %d: ", line);
    }
    fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString(err));
    exit(EXIT_FAILURE);
  }
}
/***********************
* Performance Analysis *
************************/
#define perfAnal float elapsed = 0;\
cudaEventElapsedTime(&elapsed, cudaEventStart, cudaEventStop);\
totalEventTime += elapsed;\
eventCount++;\
if (!(skip++ % 1000)) {\
	printf("%f %f\n", totalEventTime / eventCount, elapsed);\
	totalEventTime = 0;\
	eventCount = 0;\
}\

/*****************
* Configuration *
*****************/

/*! Block size used for CUDA kernel launch. */
#define blockSize 128

#define rule1Distance 5.0f
#define rule2Distance 3.0f
#define rule3Distance 5.0f

#define rule1Scale 0.01f
#define rule2Scale 0.1f
#define rule3Scale 0.1f

#define maxSpeed 1.0f

/*! Size of the starting area in simulation space. */
#define scene_scale 100.0f

/***********************************************
* Kernel state (pointers are device pointers) *
***********************************************/

int numObjects;
dim3 threadsPerBlock(blockSize);


glm::vec3 *dev_pos;
glm::vec3 *dev_vel1;
glm::vec3 *dev_vel2;


int *dev_particleArrayIndices;
int *dev_particleGridIndices;
thrust::device_ptr<int> dev_thrust_particleArrayIndices;
thrust::device_ptr<int> dev_thrust_particleGridIndices;

int *dev_gridCellStartIndices;
int *dev_gridCellEndIndices;

glm::vec3 *dev_shuffledPos;

int gridCellCount;
int gridSideCount;
float gridCellWidth;
float gridInverseCellWidth;
glm::vec3 gridMinimum;

// Performance Analysis
cudaEvent_t cudaEventStart, cudaEventStop;
float totalEventTime = 0;
int eventCount = 0;
int skip = 0;

/******************
* initSimulation *
******************/

__host__ __device__ unsigned int hash(unsigned int a) {
  a = (a + 0x7ed55d16) + (a << 12);
  a = (a ^ 0xc761c23c) ^ (a >> 19);
  a = (a + 0x165667b1) + (a << 5);
  a = (a + 0xd3a2646c) ^ (a << 9);
  a = (a + 0xfd7046c5) + (a << 3);
  a = (a ^ 0xb55a4f09) ^ (a >> 16);
  return a;
}


__host__ __device__ glm::vec3 generateRandomVec3(float time, int index) {
  thrust::default_random_engine rng(hash((int)(index * time)));
  thrust::uniform_real_distribution<float> unitDistrib(-1, 1);

  return glm::vec3((float)unitDistrib(rng), (float)unitDistrib(rng), (float)unitDistrib(rng));
}

__global__ void kernGenerateRandomPosArray(int time, int N, glm::vec3 * arr, float scale) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    glm::vec3 rand = generateRandomVec3(time, index);
    arr[index].x = scale * rand.x;
    arr[index].y = scale * rand.y;
    arr[index].z = scale * rand.z;
  }
}

/**
* Initialize memory, update some globals
*/
void Boids::initSimulation(int N) {
  numObjects = N;
  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);


  cudaMalloc((void**)&dev_pos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_pos failed!");

  cudaMalloc((void**)&dev_vel1, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel1 failed!");

  cudaMalloc((void**)&dev_vel2, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel2 failed!");

  cudaMalloc((void**)&dev_shuffledPos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_shuffledPos failed!");

  kernGenerateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(1, numObjects,
    dev_pos, scene_scale);
  checkCUDAErrorWithLine("kernGenerateRandomPosArray failed!");

  gridCellWidth = 1.0f * std::max(std::max(rule1Distance, rule2Distance), rule3Distance);
  int halfSideCount = (int)(scene_scale / gridCellWidth) + 1;
  gridSideCount = 2 * halfSideCount;

  gridCellCount = gridSideCount * gridSideCount * gridSideCount;
  gridInverseCellWidth = 1.0f / gridCellWidth;
  float halfGridWidth = gridCellWidth * halfSideCount;
  gridMinimum.x -= halfGridWidth;
  gridMinimum.y -= halfGridWidth;
  gridMinimum.z -= halfGridWidth;

  cudaMalloc((void**)&dev_particleArrayIndices, sizeof(int) * numObjects);
  checkCUDAErrorWithLine("cudaMalloc failed!");
  cudaMalloc((void**)&dev_particleGridIndices, sizeof(int) * numObjects);
  checkCUDAErrorWithLine("cudaMalloc failed!");
  cudaMalloc((void**)&dev_gridCellStartIndices, sizeof(int) * gridCellCount);
  checkCUDAErrorWithLine("cudaMalloc failed!");
  cudaMalloc((void**)&dev_gridCellEndIndices, sizeof(int) * gridCellCount);
  checkCUDAErrorWithLine("cudaMalloc failed!");
  
  dev_thrust_particleArrayIndices = thrust::device_ptr<int>(dev_particleArrayIndices);
  dev_thrust_particleGridIndices = thrust::device_ptr<int>(dev_particleGridIndices);

  cudaEventCreate(&cudaEventStart);
  cudaEventCreate(&cudaEventStop);

  cudaThreadSynchronize();
}


/******************
* copyBoidsToVBO *
******************/

/**
* Copy the boid positions into the VBO so that they can be drawn by OpenGL.
*/
__global__ void kernCopyPositionsToVBO(int N, glm::vec3 *pos, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  float c_scale = -1.0f / s_scale;

  if (index < N) {
    vbo[4 * index + 0] = pos[index].x * c_scale;
    vbo[4 * index + 1] = pos[index].y * c_scale;
    vbo[4 * index + 2] = pos[index].z * c_scale;
    vbo[4 * index + 3] = 1.0f;
  }
}

__global__ void kernCopyVelocitiesToVBO(int N, glm::vec3 *vel, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  if (index < N) {
    vbo[4 * index + 0] = vel[index].x + 0.3f;
    vbo[4 * index + 1] = vel[index].y + 0.3f;
    vbo[4 * index + 2] = vel[index].z + 0.3f;
    vbo[4 * index + 3] = 1.0f;
  }
}

/**
* Wrapper for call to the kernCopyboidsToVBO CUDA kernel.
*/
void Boids::copyBoidsToVBO(float *vbodptr_positions, float *vbodptr_velocities) {
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  kernCopyPositionsToVBO << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_pos, vbodptr_positions, scene_scale);
  kernCopyVelocitiesToVBO << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_vel1, vbodptr_velocities, scene_scale);

  checkCUDAErrorWithLine("copyBoidsToVBO failed!");

  cudaThreadSynchronize();
}


/******************
* stepSimulation *
******************/

__device__ glm::vec3 computeVelocityChange(int N, int iSelf, const glm::vec3 *pos, const glm::vec3 *vel) {

	glm::vec3 thisPos = pos[iSelf];
	glm::vec3 newVel = vel[iSelf];
	glm::vec3 center, separate, cohesion;
	int neighborCount = 0;
	for (int i = 0; i < N; i++) {
		if (i == iSelf) {
			continue;
		}

		float distance = glm::distance(thisPos, pos[i]);
		if (distance < rule1Distance) {
			center += pos[i];
			neighborCount++;
		}
		if (distance < rule2Distance) {
			separate -= pos[i] - thisPos;
		}
		if (distance < rule3Distance) {
			cohesion += vel[i];
		}
	}
	if (neighborCount > 0) {
		center /= neighborCount;
		newVel += (center - thisPos) * rule1Scale;
		newVel += cohesion * rule3Scale;
	}
	newVel += separate * rule2Scale;
	if (glm::length(newVel) > maxSpeed) {
		newVel = glm::normalize(newVel) * maxSpeed;
	}
	return newVel;
}

__global__ void kernUpdateVelocityBruteForce(int N, glm::vec3 *pos,
  glm::vec3 *vel1, glm::vec3 *vel2) {
	int index = threadIdx.x + (blockIdx.x * blockDim.x);
	if (index >= N) {
		return;
	}
	vel2[index] = computeVelocityChange(N, index, pos, vel1);
}


__global__ void kernUpdatePos(int N, float dt, glm::vec3 *pos, glm::vec3 *vel) {
  // Update position by velocity
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }
glm::vec3 thisPos = pos[index];
thisPos += vel[index] * dt;

// Wrap the boids around so we don't lose them
thisPos.x = thisPos.x < -scene_scale ? scene_scale : thisPos.x;
thisPos.y = thisPos.y < -scene_scale ? scene_scale : thisPos.y;
thisPos.z = thisPos.z < -scene_scale ? scene_scale : thisPos.z;

thisPos.x = thisPos.x > scene_scale ? -scene_scale : thisPos.x;
thisPos.y = thisPos.y > scene_scale ? -scene_scale : thisPos.y;
thisPos.z = thisPos.z > scene_scale ? -scene_scale : thisPos.z;

pos[index] = thisPos;
}

__device__ int gridIndex3Dto1D(int x, int y, int z, int gridResolution) {
	return x + y * gridResolution + z * gridResolution * gridResolution;
}

__global__ void kernComputeIndices(int N, int gridResolution,
	glm::vec3 gridMin, float inverseCellWidth,
	glm::vec3 *pos, int *indices, int *gridIndices) {
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index >= N) {
		return;
	}
	glm::vec3 grid = (pos[index] - gridMin) * inverseCellWidth;
	indices[index] = index;
	gridIndices[index] = gridIndex3Dto1D(grid.x, grid.y, grid.z, gridResolution);
	
}

__global__ void kernResetIntBuffer(int N, int *intBuffer, int value) {
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index < N) {
		intBuffer[index] = value;
	}
}

__global__ void kernIdentifyCellStartEnd(int N, int *particleGridIndices,
	int *gridCellStartIndices, int *gridCellEndIndices) {
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index >= N) {
		return;
	}
	int curr = particleGridIndices[index];
	if (index == 0) { // first cell
		gridCellStartIndices[curr] = index;
		return;
	}
	int prev = particleGridIndices[index - 1];
	if (curr != prev) { // cell change
		gridCellStartIndices[curr] = index;
		gridCellEndIndices[prev] = index - 1;
	}
	if (index == N - 1) { // final cell
		gridCellEndIndices[curr] = index;
	}
}

__global__ void kernUpdateVelNeighborSearchScattered(
	int N, int gridResolution, glm::vec3 gridMin,
	float inverseCellWidth, float cellWidth,
	int *gridCellStartIndices, int *gridCellEndIndices,
	int *particleArrayIndices,
	glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
	int index = threadIdx.x + (blockIdx.x * blockDim.x);
	int boidIndex, start, end, neighborCount = 0;
	glm::vec3 center, separate, cohesion;
	if (index >= N) {
		return;
	}
	glm::vec3 thisPos = pos[index];
	glm::ivec3 gridPos = (pos[index] - gridMin) * inverseCellWidth;
	glm::vec3 newVel = vel1[index];
	//glm::ivec3 neighbor(
	//	(thisPos.x > (gridPos.x + 0.5f) * cellWidth) ? -1 : 0, 
	//	(thisPos.y > (gridPos.y + 0.5f) * cellWidth) ? -1 : 0,
	//	(thisPos.z > (gridPos.z + 0.5f) * cellWidth) ? -1 : 0);

	glm::ivec3 neighbor;

	for (int z = -1; z <= 1; z++) {
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				glm::ivec3 offset(x, y, z);
				neighbor = gridPos + offset;
				if (neighbor.x < 0 || neighbor.y < 0 || neighbor.z < 0
					|| neighbor.x >= gridResolution || neighbor.y >= gridResolution || neighbor.z >= gridResolution) {
					continue;
				}
				int neighborNumber = gridIndex3Dto1D(neighbor.x, neighbor.y, neighbor.z, gridResolution);
				start = gridCellStartIndices[neighborNumber];
				end = gridCellEndIndices[neighborNumber];
				for (int i = start; i <= end; i++) {
					boidIndex = particleArrayIndices[i];

					float distance = glm::distance(thisPos, pos[boidIndex]);
					if (distance < rule1Distance) {
						center += pos[boidIndex];
						neighborCount++;
					}
					if (distance < rule2Distance) {
						separate -= pos[boidIndex] - thisPos;
					}
					if (distance < rule3Distance) {
						cohesion += vel1[boidIndex];
					}
				}
			}
		}
	}
	if (neighborCount > 0) {
		center /= neighborCount;
		newVel += (center - thisPos) * rule1Scale;
		newVel += cohesion * rule3Scale;
	}
	newVel += separate * rule2Scale;
	if (glm::length(newVel) > maxSpeed) {
		newVel = glm::normalize(newVel) * maxSpeed;
	}
	//newVel = glm::vec3(1, 1, 1);
	vel2[index] = newVel;

}

__global__ void kernUpdateVelNeighborSearchCoherent(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
	int index = threadIdx.x + (blockIdx.x * blockDim.x);
	int start, end, neighborCount = 0;
	glm::vec3 center, separate, cohesion;
	if (index >= N) {
		return;
	}
	glm::vec3 thisPos = pos[index];
	glm::ivec3 gridPos = (pos[index] - gridMin) * inverseCellWidth;
	glm::vec3 newVel = vel1[index];
	glm::ivec3 neighbor;


	for (int z = -1; z <= 1; z++) {
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				glm::ivec3 offset(x, y, z);
				neighbor = gridPos + offset;
				if (neighbor.x < 0 || neighbor.y < 0 || neighbor.z < 0
					|| neighbor.x >= gridResolution || neighbor.y >= gridResolution || neighbor.z >= gridResolution) {
					continue;
				}
				int neighborNumber = gridIndex3Dto1D(neighbor.x, neighbor.y, neighbor.z, gridResolution);
				start = gridCellStartIndices[neighborNumber];
				end = gridCellEndIndices[neighborNumber];
				for (int i = start; i <= end; i++) {
					float distance = glm::distance(thisPos, pos[i]);
					if (distance < rule1Distance) {
						center += pos[i];
						neighborCount++;
					}
					if (distance < rule2Distance) {
						separate -= pos[i] - thisPos;
					}
					if (distance < rule3Distance) {
						cohesion += vel1[i];
					}
				}
			}
		}
	}
	if (neighborCount > 0) {
		center /= neighborCount;
		newVel += (center - thisPos) * rule1Scale;
		newVel += cohesion * rule3Scale;
	}
	newVel += separate * rule2Scale;
	if (glm::length(newVel) > maxSpeed) {
		newVel = glm::normalize(newVel) * maxSpeed;
	}
	//newVel = glm::vec3(1, 1, 1);
	vel2[index] = newVel;
}

/**
* Step the entire N-body simulation by `dt` seconds.
*/
void Boids::stepSimulationNaive(float dt) {
	dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
	//cudaEventRecord(cudaEventStart);
	kernUpdateVelocityBruteForce<<<fullBlocksPerGrid, blockSize>>>(numObjects, dev_pos, dev_vel1, dev_vel2);
	//cudaEventRecord(cudaEventStop);
	//cudaEventSynchronize(cudaEventStop);

	kernUpdatePos<<<fullBlocksPerGrid, blockSize>>>(numObjects, dt, dev_pos, dev_vel2);

	glm::vec3 *tmp = dev_vel1;
	dev_vel1 = dev_vel2;
	dev_vel2 = tmp;
	
	//perfAnal
	
}

void Boids::stepSimulationScatteredGrid(float dt) {

	dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
	kernComputeIndices << <fullBlocksPerGrid, blockSize >> >(numObjects, gridSideCount, gridMinimum, gridInverseCellWidth, 
		dev_pos, dev_particleArrayIndices, dev_particleGridIndices);

	thrust::sort_by_key(dev_thrust_particleGridIndices, dev_thrust_particleGridIndices + numObjects, dev_thrust_particleArrayIndices);
	
	kernIdentifyCellStartEnd << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_particleGridIndices, dev_gridCellStartIndices, dev_gridCellEndIndices);
	cudaEventRecord(cudaEventStart);
	kernUpdateVelNeighborSearchScattered << <fullBlocksPerGrid, blockSize >> >(numObjects, gridSideCount, gridMinimum, gridInverseCellWidth,
		gridCellWidth, dev_gridCellStartIndices, dev_gridCellEndIndices, dev_particleArrayIndices, dev_pos, dev_vel1, dev_vel2);
	cudaEventRecord(cudaEventStop);
	cudaEventSynchronize(cudaEventStop);
	kernUpdatePos << <fullBlocksPerGrid, blockSize >> >(numObjects, dt, dev_pos, dev_vel2);

	glm::vec3 *tmp = dev_vel1;
	dev_vel1 = dev_vel2;
	dev_vel2 = tmp;

	//perfAnal
}

__global__ void kernShuffleBuffer(int N, int *ref, glm::vec3 *orig, glm::vec3 *dest) {
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index >= N) {
		return;
	}
	dest[index] = orig[ref[index]]; 
}

void Boids::stepSimulationCoherentGrid(float dt) {

	dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
	kernComputeIndices << <fullBlocksPerGrid, blockSize >> >(numObjects, gridSideCount, gridMinimum, gridInverseCellWidth,
		dev_pos, dev_particleArrayIndices, dev_particleGridIndices);

	thrust::sort_by_key(dev_thrust_particleGridIndices, dev_thrust_particleGridIndices + numObjects, dev_thrust_particleArrayIndices);

	kernIdentifyCellStartEnd << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_particleGridIndices, dev_gridCellStartIndices, dev_gridCellEndIndices);
	
	kernShuffleBuffer << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_particleArrayIndices, dev_pos, dev_shuffledPos);
	kernShuffleBuffer << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_particleArrayIndices, dev_vel1, dev_vel2);
	cudaEventRecord(cudaEventStart);
	kernUpdateVelNeighborSearchCoherent << <fullBlocksPerGrid, blockSize >> >(numObjects, gridSideCount, gridMinimum, gridInverseCellWidth,
		gridCellWidth, dev_gridCellStartIndices, dev_gridCellEndIndices, dev_shuffledPos, dev_vel2, dev_vel1);
	cudaEventRecord(cudaEventStop);
	cudaEventSynchronize(cudaEventStop);
	kernUpdatePos << <fullBlocksPerGrid, blockSize >> >(numObjects, dt, dev_shuffledPos, dev_vel1);

	glm::vec3 *tmp = dev_pos;
	dev_pos = dev_shuffledPos;
	dev_shuffledPos = tmp;

	perfAnal
}

void Boids::endSimulation() {
  cudaFree(dev_vel1);
  cudaFree(dev_vel2);
  cudaFree(dev_pos);

  cudaFree(dev_particleArrayIndices);
  cudaFree(dev_particleGridIndices);
  cudaFree(dev_gridCellStartIndices);
  cudaFree(dev_gridCellEndIndices);

  cudaFree(dev_shuffledPos);
}

void Boids::unitTest() {
  // test unstable sort
  int *dev_intKeys;
  int *dev_intValues;
  int N = 10;

  int *intKeys = new int[N];
  int *intValues = new int[N];

  intKeys[0] = 0; intValues[0] = 0;
  intKeys[1] = 1; intValues[1] = 1;
  intKeys[2] = 0; intValues[2] = 2;
  intKeys[3] = 3; intValues[3] = 3;
  intKeys[4] = 0; intValues[4] = 4;
  intKeys[5] = 2; intValues[5] = 5;
  intKeys[6] = 2; intValues[6] = 6;
  intKeys[7] = 0; intValues[7] = 7;
  intKeys[8] = 5; intValues[8] = 8;
  intKeys[9] = 6; intValues[9] = 9;

  cudaMalloc((void**)&dev_intKeys, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intKeys failed!");

  cudaMalloc((void**)&dev_intValues, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intValues failed!");

  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  std::cout << "before unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // How to copy data to the GPU
  cudaMemcpy(dev_intKeys, intKeys, sizeof(int) * N, cudaMemcpyHostToDevice);
  cudaMemcpy(dev_intValues, intValues, sizeof(int) * N, cudaMemcpyHostToDevice);

  // Wrap device vectors in thrust iterators for use with thrust.
  thrust::device_ptr<int> dev_thrust_keys(dev_intKeys);
  thrust::device_ptr<int> dev_thrust_values(dev_intValues);
  // LOOK-2.1 Example for using thrust::sort_by_key
  thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + N, dev_thrust_values);

  // How to copy data back to the CPU side from the GPU
  cudaMemcpy(intKeys, dev_intKeys, sizeof(int) * N, cudaMemcpyDeviceToHost);
  cudaMemcpy(intValues, dev_intValues, sizeof(int) * N, cudaMemcpyDeviceToHost);
  checkCUDAErrorWithLine("memcpy back failed!");

  std::cout << "after unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // cleanup
  delete[] intKeys;
  delete[] intValues;
  cudaFree(dev_intKeys);
  cudaFree(dev_intValues);
  checkCUDAErrorWithLine("cudaFree failed!");
  return;
}
