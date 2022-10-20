#include <ATen/cuda/CUDAContext.h>
#include <cuda.h>
#include <cuda_runtime.h>
#include <torch/extension.h>

#include <vector>

template <typename scalar_t>
__global__ void hpwl_cuda_kernel(
    const torch::PackedTensorAccessor32<scalar_t, 2, torch::RestrictPtrTraits> pin_pos,
    const torch::PackedTensorAccessor32<int64_t, 1, torch::RestrictPtrTraits> hyperedge_list,
    const torch::PackedTensorAccessor32<int64_t, 1, torch::RestrictPtrTraits> hyperedge_list_end,
    torch::PackedTensorAccessor32<scalar_t, 2, torch::RestrictPtrTraits> partial_hpwl,
    int num_nets) {
    const int index = blockIdx.x * blockDim.x + threadIdx.x;
    const int i = index >> 1;  // pin index
    if (i < num_nets) {
        const int c = index & 1;  // channel index
        int64_t start_idx = 0;
        if (i != 0) {
            start_idx = hyperedge_list_end[i - 1];
        }
        int64_t end_idx = hyperedge_list_end[i];
        partial_hpwl[i][c] = 0;
        if (end_idx != start_idx) {
            int64_t pin_id = hyperedge_list[start_idx];
            scalar_t x_min = pin_pos[pin_id][c];
            scalar_t x_max = pin_pos[pin_id][c];
            for (int64_t idx = start_idx + 1; idx < end_idx; idx++) {
                scalar_t xx = pin_pos[hyperedge_list[idx]][c];
                x_min = min(xx, x_min);
                x_max = max(xx, x_max);
            }
            partial_hpwl[i][c] = abs(x_max - x_min);
        }
    }
}

torch::Tensor hpwl_cuda(torch::Tensor pos, torch::Tensor hyperedge_list, torch::Tensor hyperedge_list_end) {
    cudaSetDevice(pos.get_device());
    auto stream = at::cuda::getCurrentCUDAStream();

    const auto num_nets = hyperedge_list_end.size(0);
    const int num_channels = 2;
    auto partial_hpwl = torch::zeros({num_nets, num_channels}, torch::dtype(pos.dtype()).device(pos.device()));

    const int threads = 64;
    const int blocks = (num_nets * 2 + threads - 1) / threads;

    AT_DISPATCH_ALL_TYPES(pos.scalar_type(), "hpwl_cuda", ([&] {
                              hpwl_cuda_kernel<scalar_t><<<blocks, threads, 0, stream>>>(
                                  pos.packed_accessor32<scalar_t, 2, torch::RestrictPtrTraits>(),
                                  hyperedge_list.packed_accessor32<int64_t, 1, torch::RestrictPtrTraits>(),
                                  hyperedge_list_end.packed_accessor32<int64_t, 1, torch::RestrictPtrTraits>(),
                                  partial_hpwl.packed_accessor32<scalar_t, 2, torch::RestrictPtrTraits>(),
                                  num_nets);
                          }));

    return partial_hpwl;
}