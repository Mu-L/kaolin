// Copyright (c) 2021 NVIDIA CORPORATION & AFFILIATES.
// All rights reserved.

// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at

//    http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#ifndef KAOLIN_SPC_UTILS_CUH_
#define KAOLIN_SPC_UTILS_CUH_

#include <cub/device/device_scan.cuh>
#include "spc_math.h"

namespace kaolin {
    
/////////////////////////////////////////////
/// Device Code
/////////////////////////////////////////////

static inline __device__ int32_t identify(
    const point_data k,
    const uint32_t       level,
    const int32_t*      prefix_sum,
    const uchar*     octree)
{
    int maxval = (0x1 << level) - 1; // seems you could do this better using Morton codes
    // Check if in bounds
    if (k.x < 0 || k.y < 0 || k.z < 0 || k.x > maxval || k.y > maxval || k.z > maxval) {
        return -1;
    }
    int ord = 0;
    for (uint l = 0; l < level; l++)
    {
        uint depth = level - l - 1;
        uint mask = (0x1 << depth);
        uint child_idx = ((mask & k.x) << 2 | (mask & k.y) << 1 | (mask & k.z)) >> depth;
        uchar bits = octree[ord];
        // if bit set, keep going
        if (bits & (0x1 << child_idx))
        {
            // count set bits up to child - inclusive sum
            uint cnt = __popc(bits & ((0x2 << child_idx) - 1));
            ord = prefix_sum[ord] + cnt;
            if (depth == 0) {
                return ord;
            }
        }
        else {
            return -1;
        }
    }
    return ord; // only if called with Level=0
}

static inline __device__ void identify_multiscale(
    const point_data k,
    const uint32_t       level,
    const int32_t*      prefix_sum,
    const uchar*     octree,
    int32_t*         pidx)
{
    // Check if in bounds
    int maxval = (0x1 << level) - 1; // seems you could do this better using Morton codes
    if (k.x < 0 || k.y < 0 || k.z < 0 || k.x > maxval || k.y > maxval || k.z > maxval) {
        for (int i=0; i <= level; ++i) {
            pidx[i] = -1; 
        }
        return;
    } 
    pidx[0] = 0;
        
    int ord = 0;
    for (uint l = 0; l < level; l++)
    {
        uint depth = level - l - 1;
        uint mask = (0x1 << depth);
        uint child_idx = ((mask & k.x) << 2 | (mask & k.y) << 1 | (mask & k.z)) >> depth;
        uchar bits = octree[ord];
        // if bit set, keep going
        if (bits & (0x1 << child_idx))
        {
            // count set bits up to child - inclusive sum
            uint cnt = __popc(bits & ((0x2 << child_idx) - 1));
            ord = prefix_sum[ord] + cnt;
            pidx[l+1] = ord;
        } else {
            // Miss, populate with -1
            for (int j=l; j < level; ++j) {
                pidx[j+1] = -1; 
            }
            return;
        }
    }
}


// version of 'identify' that understands empty space
static inline __device__ int32_t identify(
  const point_data 	k,
  const uint32_t    Level,
  const int32_t*    Exsum,
  const uchar* 	    Oroot,
  const uchar* 	    Eroot)
{
  int maxval = (0x1 << Level) - 1;
  if (k.x < 0 || k.y < 0 || k.z < 0 || k.x > maxval || k.y > maxval || k.z > maxval)
    return -1;

  int ord = 0;
  int prev = 0;
  for (uint32_t l = 0; l < Level; l++)
  {
    uint32_t depth = Level - l - 1;
    uint32_t mask = (0x1 << depth);
    uint32_t child_idx = ((mask&k.x) << 2 | (mask&k.y) << 1 | (mask&k.z)) >> depth;
    uint32_t bits = (uint32_t)Oroot[ord];
    uint32_t mpty = (uint32_t)Eroot[ord];

    // count set bits up to child - inclusive sum
    uint32_t cnt = __popc(bits&((0x2 << child_idx) - 1));
    ord = Exsum[prev];

    // if bit set, keep going
    if (bits&(0x1 << child_idx))
    {
      ord += cnt;

      if (depth == 0)
        return ord;
    }
    else
    {
      if (mpty&(0x1 << child_idx))
        return -2 - static_cast<int32_t>(depth);
      else
        return -1;
    }

    prev = ord;
  }

  return ord; // only if called with Level=0
}
//


/////////////////////////////////////////////
/// Kernels
/////////////////////////////////////////////

static __global__ void points_to_morton_cuda_kernel(
    const point_data* points,   
    morton_code* morton_codes,
    const int64_t num_points
){
    int64_t idx = blockIdx.x*blockDim.x + threadIdx.x;
    int64_t stride = blockDim.x*gridDim.x;
    if (idx > num_points) return;

    for (int64_t i=idx; i<num_points; i+=stride) {
        morton_codes[i] = to_morton(points[i]);
    }
}

static __global__ void morton_to_points_cuda_kernel(
    const morton_code* morton_codes,
    point_data* points,   
    const int64_t num_points
){
    int64_t idx = blockIdx.x*blockDim.x + threadIdx.x;
    int64_t stride = blockDim.x*gridDim.x;
    if (idx > num_points) return;

    for (int64_t i=idx; i<num_points; i+=stride) {
        points[i] = to_point(morton_codes[i]);
    }
}

static __global__ void nodes_to_morton_cuda_kernel(
    const uchar* octree,
    const uint* prefix_sum,
    const morton_code* morton_in,
    morton_code* morton_out,
    const uint num_points
) {
  uint tidx = blockDim.x * blockIdx.x + threadIdx.x;

  if (tidx < num_points) {
     uchar bits = octree[tidx];
     morton_code code = morton_in[tidx];
     int addr = prefix_sum[tidx];

#    pragma unroll
     for (int i = 7; i >= 0; i--) {
       if (bits&(0x1 << i))
         morton_out[addr--] = 8 * code + i;
     }
  }
}

/////////////////////////////////////////////
/// Other Utility
/////////////////////////////////////////////

// Gets storage bytes for CUB
static uint64_t get_cub_storage_bytes(
    void* temp_storage, 
    uint* info, 
    uint* prefix_sum,
    uint  max_total_points,
    cudaStream_t stream = 0) {
    
  uint64_t temp_storage_bytes = 0;
  CubDebugExit(cub::DeviceScan::InclusiveSum(
      temp_storage, temp_storage_bytes, info,
      prefix_sum, max_total_points, stream));
  return temp_storage_bytes;
}

} // namespace kaolin
#endif  // KAOLIN_SPC_UTILS_CUH_
