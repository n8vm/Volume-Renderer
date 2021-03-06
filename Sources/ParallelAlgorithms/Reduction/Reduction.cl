__kernel
	void reduce(__global cl_int* buffer,
		__local cl_int* scratch,
		__const int length,
		__global cl_int* result)
{
	//InitReduce
	int global_index = get_global_id(0);
	cl_int accumulator = 0;

	// Loop sequentially over chunks of input vector
	// improves Big O by Brent's Theorem.
	while (global_index < length) {
		accumulator += buffer[global_index];
		global_index += get_global_size(0);
	}

	// Perform parallel reduction
	int local_index = get_local_id(0);
	scratch[local_index] = accumulator;
	barrier(CLK_LOCAL_MEM_FENCE);
	for (int offset = get_local_size(0) / 2; offset > 0; offset = offset / 2) {
		if (local_index < offset)
			scratch[local_index] = scratch[local_index] + scratch[local_index + offset];
		barrier(CLK_LOCAL_MEM_FENCE);
	}
	if (local_index == 0) {
		result[get_group_id(0)] = scratch[0];
	}
}

#define T int
#define blockSize 32
#define blockSize5 32
#define blockSize6 1024
#define nIsPow2 1
/* Avoid using this kernel at all costs. This kernel is mainly for unit testing. Instead, use Reduce_s. */
__kernel void oneThreadReduce(__global T *g_idata, __global T *g_odata, cl_int n) {
	if (get_global_id(0) == 0) {
		cl_int sum = 0;
		for (int i = 0; i < n; ++i) {
			sum += g_idata[i];
		}
		g_odata[0] = sum;
	}
}

/*
This version uses n/2 threads --
it performs the first level of reduction when reading from global memory
*/
__kernel void reduce3(__global T *g_idata, __global T *g_odata, cl_int n, __local T* sdata)
{
	// perform first level of reduction,
	// reading from global memory, writing to shared memory
	cl_int tid = get_local_id(0);
	cl_int i = get_group_id(0)*(get_local_size(0) * 2) + get_local_id(0);

	sdata[tid] = (i < n) ? g_idata[i] : 0;
	if (i + get_local_size(0) < n)
		sdata[tid] += g_idata[i + get_local_size(0)];

	barrier(CLK_LOCAL_MEM_FENCE);

	// do reduction in shared mem
	for (cl_int s = get_local_size(0) / 2; s > 0; s >>= 1)
	{
		if (tid < s)
		{
			sdata[tid] += sdata[tid + s];
		}
		barrier(CLK_LOCAL_MEM_FENCE);
	}

	// write result for this block to global mem 
	if (tid == 0) g_odata[get_group_id(0)] = sdata[0];
}
/*
This version is completely unrolled.  It uses a template parameter to achieve
optimal code for any (power of 2) number of threads.  This requires a switch
statement in the host code to handle all the different thread block sizes at
compile time.
*/
__kernel void reduce5(__global T *g_idata, __global T *g_odata, cl_int n, __local volatile T* sdata)
{
	// perform first level of reduction,
	// reading from global memory, writing to shared memory
	cl_int tid = get_local_id(0);
	cl_int i = get_group_id(0)*(get_local_size(0) * 2) + get_local_id(0);

	sdata[tid] = (i < n) ? g_idata[i] : 0;
	if (i + blockSize5 < n)
		sdata[tid] += g_idata[i + blockSize5];

	barrier(CLK_LOCAL_MEM_FENCE);

	// do reduction in shared mem
	if (blockSize5 >= 1024) { if (tid < 512) { sdata[tid] += sdata[tid + 512]; } barrier(CLK_LOCAL_MEM_FENCE); }
	if (blockSize5 >= 512) { if (tid < 256) { sdata[tid] += sdata[tid + 256]; } barrier(CLK_LOCAL_MEM_FENCE); }
	if (blockSize5 >= 256) { if (tid < 128) { sdata[tid] += sdata[tid + 128]; } barrier(CLK_LOCAL_MEM_FENCE); }
	if (blockSize5 >= 128) { if (tid < 64) { sdata[tid] += sdata[tid + 64]; } barrier(CLK_LOCAL_MEM_FENCE); }

	if (tid < 32)
	{
		if (blockSize5 >= 64) { sdata[tid] += sdata[tid + 32]; }
		if (blockSize5 >= 32) { sdata[tid] += sdata[tid + 16]; }
		if (blockSize5 >= 16) { sdata[tid] += sdata[tid + 8]; }
		if (blockSize5 >= 8) { sdata[tid] += sdata[tid + 4]; }
		if (blockSize5 >= 4) { sdata[tid] += sdata[tid + 2]; }
		if (blockSize5 >= 2) { sdata[tid] += sdata[tid + 1]; }
	}

	// write result for this block to global mem 
	if (tid == 0) g_odata[get_group_id(0)] = sdata[0];
}

/*
This version adds multiple elements per thread sequentially.  This reduces the overall
cost of the algorithm while keeping the work complexity O(n) and the step complexity O(log n).
(Brent's Theorem optimization)
*/
__kernel void reduce6(__global T *g_idata, __global T *g_odata, cl_int n, __local volatile T* sdata)
{
	// perform first level of reduction,
	// reading from global memory, writing to shared memory
	cl_int tid = get_local_id(0);
	cl_int i = get_group_id(0)*(get_local_size(0) * 2) + get_local_id(0);
	cl_int gridSize = blockSize6 * 2 * get_num_groups(0);
	sdata[tid] = 0;

	// we reduce multiple elements per thread.  The number is determined by the 
	// number of active thread blocks (via gridDim).  More blocks will result
	// in a larger gridSize and therefore fewer elements per thread
	while (i < n)
	{
		sdata[tid] += g_idata[i];
		// ensure we don't read out of bounds -- this is optimized away for powerOf2 sized arrays
		if (nIsPow2 || i + blockSize6 < n)
			sdata[tid] += g_idata[i + blockSize6];
		i += gridSize;
	}

	barrier(CLK_LOCAL_MEM_FENCE);

	// do reduction in shared mem
	if (blockSize6 >= 1024) { if (tid < 512) { sdata[tid] += sdata[tid + 512]; } barrier(CLK_LOCAL_MEM_FENCE); }
	if (blockSize6 >= 512) { if (tid < 256) { sdata[tid] += sdata[tid + 256]; } barrier(CLK_LOCAL_MEM_FENCE); }
	if (blockSize6 >= 256) { if (tid < 128) { sdata[tid] += sdata[tid + 128]; } barrier(CLK_LOCAL_MEM_FENCE); }
	if (blockSize6 >= 128) { if (tid < 64) { sdata[tid] += sdata[tid + 64]; } barrier(CLK_LOCAL_MEM_FENCE); }

	if (tid < 32)
	{
		if (blockSize6 >= 64) { sdata[tid] += sdata[tid + 32]; }
		if (blockSize6 >= 32) { sdata[tid] += sdata[tid + 16]; }
		if (blockSize6 >= 16) { sdata[tid] += sdata[tid + 8]; }
		if (blockSize6 >= 8) { sdata[tid] += sdata[tid + 4]; }
		if (blockSize6 >= 4) { sdata[tid] += sdata[tid + 2]; }
		if (blockSize6 >= 2) { sdata[tid] += sdata[tid + 1]; }
	}

	// write result for this block to global mem 
	if (tid == 0) g_odata[get_group_id(0)] = sdata[0];
}
