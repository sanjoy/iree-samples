// Instructions; TL;DR
// ===================
//
// This script shows an example of tiling for 2 levels with:
//   - padding with nofold to achieve shared memory mapping
//   - thread mapping of the copies to shared memory
//   - connecting to wmma operations.
//   - multi-buffering and creating pipelined async copies.
//
// At this time we are only missing a better mapping to SIMT / SIMD: in 
// particular the contraction op is not yet mapped to warps (step 5).
//
// This is dependent on landing:
//   https://github.com/nicolasvasilache/iree/commits/cuda-matmul-e2e
//
// ```
//   export IREE_DIR=${HOME}/github/iree; \
//   export IREE_SAMPLES_DIR=${HOME}/github/iree-samples; \
//   cat ${IREE_SAMPLES_DIR}/transform_dialect/examples/matmul.mlir |\
//   sed "s/\${M}/1024/g" | sed "s/\${K}/2048/g" | sed "s/\${N}/4096/g" | \
//   ${IREE_DIR}/build/tools/iree-opt \
//     --iree-hal-target-backends=cuda \
//     --iree-abi-transformation-pipeline \
//     --iree-flow-transformation-pipeline \
//     --iree-stream-transformation-pipeline \
//     --iree-hal-configuration-pipeline | \
//   ${IREE_DIR}/build/tools/iree-opt \
//      --pass-pipeline='builtin.module(hal.executable(hal.executable.variant(iree-llvmgpu-lower-executable-target)))' \
//      --iree-codegen-llvmgpu-use-transform-dialect=${IREE_SAMPLES_DIR}/transform_dialect/examples/cuda/matmul_codegen_spec_step_03_pad_shared_wmma_async_pipelined.mlir \
//      --iree-codegen-llvmgpu-enable-transform-dialect-jit=false | \
//   FileCheck transform_dialect/examples/cuda/matmul_codegen_spec_step_03_pad_shared_wmma_async_pipelined.mlir
// ```
//
// To produce PTX:
// ```
//    export IREE_DIR=${HOME}/github/iree; 
//    export IREE_SAMPLES_DIR=${HOME}/github/iree-samples; 
//    cat ${IREE_SAMPLES_DIR}/transform_dialect/examples/matmul.mlir | \
//    sed "s/\${M}/1024/g" | sed "s/\${K}/2048/g" | sed "s/\${N}/4096/g" | \
//    ${IREE_DIR}/build/tools/iree-compile - \
//      --iree-hal-target-backends=cuda --iree-hal-cuda-llvm-target-arch=sm_80 \
//      --iree-codegen-llvmgpu-use-transform-dialect=${IREE_SAMPLES_DIR}/transform_dialect/examples/cuda/matmul_codegen_spec_step_03_pad_shared_wmma_async_pipelined.mlir \
//      --iree-codegen-llvmgpu-enable-transform-dialect-jit=false 
// ```
//
// To run e2e on a remote machine (${A100_MACHINE}) with an A100 GPU:
// ```
//   # Do this only once:
//   # scp ${IREE_DIR}/build/tools/iree-run-module ${USER}@${A100_MACHINE}:~/;
//
//   export IREE_DIR=${HOME}/github/iree; 
//   export IREE_SAMPLES_DIR=${HOME}/github/iree-samples; 
//   cat ${IREE_SAMPLES_DIR}/transform_dialect/examples/matmul.mlir | \
//   sed "s/\${M}/1024/g" | sed "s/\${K}/2048/g" | sed "s/\${N}/4096/g" | \
//   ${IREE_DIR}/build/tools/iree-compile - \
//     --iree-hal-target-backends=cuda --iree-hal-cuda-llvm-target-arch=sm_80 \
//     --iree-codegen-llvmgpu-use-transform-dialect=${IREE_SAMPLES_DIR}/transform_dialect/examples/cuda/matmul_codegen_spec_step_03_pad_shared_wmma_async_pipelined.mlir \
//     --iree-codegen-llvmgpu-enable-transform-dialect-jit=false \
//     --iree-hal-benchmark-dispatch-repeat-count=5 \
//     -o /tmp/foo.vmfb; \
//   scp /tmp/foo.vmfb ${USER}@${A100_MACHINE}:~/ > /dev/null; \
//   ssh ${USER}@${A100_MACHINE} "nsys profile --stats=true ~/iree-run-module --function=matmul_static --device=cuda --module=foo.vmfb --input=1024x2048xf32=1 --input=2048x4096xf32=1 --input=1024x4096xf32=1 2>&1" | \
//   grep matmul_static_dispatch | awk '{print $6}'
//
//   # The above prints the min across the 5 invocations.
//   # Alternatively, grep a little more to see what happens in more detail.
//   grep -3 matmul_static_dispatch
// ```
//
// The above command simply prints `2419289` (i.e. 2.419 million nanoseconds).
//
// Alternatively, run with the profiler:
// ```
//   export IREE_DIR=${HOME}/github/iree; 
//   export IREE_SAMPLES_DIR=${HOME}/github/iree-samples; 
//   cat ${IREE_SAMPLES_DIR}/transform_dialect/examples/matmul.mlir | \
//   sed "s/\${M}/1024/g" | sed "s/\${K}/2048/g" | sed "s/\${N}/4096/g" | \
//   ${IREE_DIR}/build/tools/iree-compile - \
//     --iree-hal-target-backends=cuda --iree-hal-cuda-llvm-target-arch=sm_80 \
//     --iree-codegen-llvmgpu-use-transform-dialect=${IREE_SAMPLES_DIR}/transform_dialect/examples/cuda/matmul_codegen_spec_step_02_pad_shared_wmma_async_pipelined_mapped.mlir \
//     --iree-codegen-llvmgpu-enable-transform-dialect-jit=false \
//     -o /tmp/foo.vmfb; \
//   scp /tmp/foo.vmfb ${USER}@${A100_MACHINE}:~/ > /dev/null; \
//   ssh ${USER}@${A100_MACHINE} "sudo /usr/local/cuda/bin/ncu -f --set full -o profile ~/iree-run-module --function=matmul_static --device=cuda --module=foo.vmfb \
//     --input=1024x2048xf32=1 --input=2048x4096xf32=1 --input=1024x4096xf32=1"
// ```
//

// CHECK: hal.interface.workgroup.id[1] : index
// CHECK: hal.interface.workgroup.id[0] : index
// CHECK: gpu.thread_id  x
// CHECK: gpu.thread_id  y
// CHECK: scf.for
// CHECK:   scf.for
// CHECK:     gpu.subgroup_mma_load_matrix {{.*}} -> !gpu.mma_matrix<16x16xf32, "COp">
// CHECK:     nvgpu.device_async_copy
// CHECK:     scf.for {{.*}} -> (!gpu.mma_matrix<16x16xf32, "COp">, !nvgpu.device.async.token, !nvgpu.device.async.token, !nvgpu.device.async.token, !nvgpu.device.async.token
// CHECK:       nvgpu.device_async_wait %{{.*}} {numGroups = 1 : i32}
// CHECK:       nvgpu.device_async_wait %{{.*}} {numGroups = 1 : i32}
// CHECK:       gpu.subgroup_mma_load_matrix %{{.*}} {leadDimension = 16 : index} : memref<16x16xf32, strided<[16, 1], offset: ?>, #gpu.address_space<workgroup>> -> !gpu.mma_matrix<16x8xf32, "AOp">
// CHECK:       gpu.subgroup_mma_load_matrix %{{.*}} {leadDimension = 16 : index} : memref<16x16xf32, strided<[16, 1], offset: ?>, #gpu.address_space<workgroup>> -> !gpu.mma_matrix<16x8xf32, "AOp">
// CHECK:       gpu.subgroup_mma_load_matrix %{{.*}} {leadDimension = 16 : index} : memref<16x16xf32, strided<[16, 1], offset: ?>, #gpu.address_space<workgroup>> -> !gpu.mma_matrix<8x16xf32, "BOp">
// CHECK:       gpu.subgroup_mma_load_matrix %{{.*}} {leadDimension = 16 : index} : memref<16x16xf32, strided<[16, 1], offset: ?>, #gpu.address_space<workgroup>> -> !gpu.mma_matrix<8x16xf32, "BOp">
// CHECK:       gpu.subgroup_mma_compute %{{.*}} : !gpu.mma_matrix<16x8xf32, "AOp">, !gpu.mma_matrix<8x16xf32, "BOp"> -> !gpu.mma_matrix<16x16xf32, "COp">
// CHECK:       gpu.subgroup_mma_compute %{{.*}} : !gpu.mma_matrix<16x8xf32, "AOp">, !gpu.mma_matrix<8x16xf32, "BOp"> -> !gpu.mma_matrix<16x16xf32, "COp">
// CHECK:       nvgpu.device_async_copy %{{.*}} : memref<1024x2048xf32> to memref<1x4xf32, strided<[16, 1], offset: ?>, #gpu.address_space<workgroup>>
// CHECK:       nvgpu.device_async_create_group %{{.*}} {__pipelining_first_stage__}
// CHECK:       gpu.barrier {__pipelining_first_stage__}
// CHECK:       nvgpu.device_async_copy %{{.*}} : memref<2048x4096xf32> to memref<1x4xf32, strided<[16, 1], offset: ?>, #gpu.address_space<workgroup>>
// CHECK:       nvgpu.device_async_create_group %{{.*}} {__pipelining_first_stage__}
// CHECK:     gpu.subgroup_mma_store_matrix %{{.*}} {leadDimension = 4096 : index} : !gpu.mma_matrix<16x16xf32, "COp">, memref<32x32xf32, strided<[4096, 1], offset: ?>>

transform.sequence failures(propagate) {
^bb1(%variant_op: !pdl.operation):
  %matmul = transform.structured.match ops{["linalg.matmul"]} in %variant_op
    : (!pdl.operation) -> !pdl.operation

  // Step 1. Tile to forall and sequential scf.for.
  // ======================================================
  %forall_l1, %matmul_l1 =
    transform.iree.tile_to_forall_and_workgroup_count_region %matmul tile_sizes [32, 32]
      ( mapping = [#gpu.block<y>, #gpu.block<x>] )
  %matmul_l2, %loops:3 = transform.structured.tile_to_scf_for %matmul_l1 [16, 16, 16]
  // Post-tiling canonicalizations and cleanups.
  transform.iree.apply_patterns %variant_op 
    {canonicalization, cse, licm, tiling_canonicalization}

  // Step 2. Pad the matmul and force packing to create the buffer in shared memory
  // Note: hoisting here may be dangerous memory-consumption-wise and we may be
  // better off with pipelining only.
  // ==============================================================================
  %matmul_padded_l2 = transform.structured.pad %matmul_l2 {
    padding_values = [0.0 : f32, 0.0 : f32, 0.0 : f32], 
    padding_dimensions = [0, 1, 2], 
    pack_paddings=[1, 1, 0]
  }
  // Post-padding canonicalizations and cleanups (required to make 0 low/hig-pad appear)
  transform.iree.apply_patterns %variant_op 
    {canonicalization, cse, licm, tiling_canonicalization}

  // Step 3. Rewrite tensor.pad in DPS. 
  // TODO: This must introduce unfoldable copies that disable the 
  // tensor::InsertSliceOp::fold very aggressive blanket behavior
  // ==============================================================
  %pad = transform.structured.match ops{["tensor.pad"]} in %variant_op 
    : (!pdl.operation) -> !pdl.operation
  %padded = transform.structured.rewrite_in_destination_passing_style %pad 
    : (!pdl.operation) -> !pdl.operation
  
  // Step 4. Map to threads, **SIMT** programming model.
  // Ensure we lower to 1-D vectors otherwise cp.async will not kick in.
  // ===================================================================
  %fill = transform.structured.match ops{["linalg.fill"]} in %variant_op
    : (!pdl.operation) -> !pdl.operation
  transform.structured.tile_to_forall_op %fill num_threads [16, 4]
      ( mapping = [#gpu.thread<y>, #gpu.thread<x>] )
  %copy = transform.structured.match ops{["linalg.copy"]} in %variant_op
    : (!pdl.operation) -> !pdl.operation
  transform.structured.tile_to_forall_op %copy num_threads [16, 4]
      ( mapping = [#gpu.thread<y>, #gpu.thread<x>] )

  // // TODO: this mapping step currently messes up bufferization. As a consequence
  // // we only run on 1 warp for now.
  // // Contraction part mapped to threads with a **SIMD** programming model.
  // // =============================================================================
  // // %forall_l3, %matmul_padded_l3 = 
  // //   transform.structured.tile_to_forall_op %matmul_padded_l2 num_threads [1, 0]
  // //     ( mapping = [#gpu.warp<x>] )

  // Step 5. Rank-reduce and vectorize.
  // ===================================================================================
  %func_v = transform.structured.match ops{["func.func"]} in %variant_op : (!pdl.operation) -> !pdl.operation
  %func_v_2 = transform.iree.apply_patterns %func_v { rank_reducing_linalg, rank_reducing_vector }
  %func_v_3 = transform.structured.vectorize %func_v_2 { vectorize_padding }
  %func_v_4 = transform.iree.apply_patterns %func_v_3 { unroll_vectors_gpu_wmma }
  // Post-vectorization canonicalizations and hoistings to avoid roundtripping 
  // vectors in memory and prepare for bufferization.
  transform.iree.apply_patterns %variant_op {canonicalization, cse, licm }
  %func_v_5 = transform.structured.hoist_redundant_tensor_subsets %func_v_4
    : (!pdl.operation) -> !pdl.operation

  // Step 6. Bufferize and drop HAL descriptor from memref ops.
  // ==========================================================
  %variant_op_2 = transform.iree.eliminate_empty_tensors %variant_op
  %variant_op_3 = transform.iree.bufferize { target_gpu } %variant_op_2
  %func_m = transform.structured.match ops{["func.func"]} in %variant_op_3 
    : (!pdl.operation) -> !pdl.operation
  %func_m_2 = transform.iree.erase_hal_descriptor_type_from_memref %func_m

  // // Step 7. Post-bufferization mapping blocks/workgroup and threads/subgroup.
  // =========================================================================
  %func_m_4 = transform.iree.forall_to_workgroup %func_m_2
  %func_m_5 = transform.iree.map_nested_forall_to_gpu_threads %func_m_4
      { workgroup_size = [4, 16, 1] }
  %func_m_6 = transform.iree.apply_buffer_optimizations %func_m_5
  // Post-buferization and mapping canonicalizations and cleanups.
  transform.iree.apply_patterns %variant_op_3
    {canonicalization, cse, licm, tiling_canonicalization}

  // Step 9. Multi-buffering.
  // =========================================================================
  %func_m_7 = transform.iree.hoist_static_alloc %func_m_6
    : (!pdl.operation) -> !pdl.operation
  %allocs = transform.structured.match ops{["memref.alloc"]} in %func_m_7
    : (!pdl.operation) -> !transform.op<"memref.alloc">
  %mb_allocs = transform.memref.multibuffer %allocs {factor = 2 : i64, skip_analysis } 
    : (!transform.op<"memref.alloc">) -> !pdl.operation

  // Step 10. Cp-async.
  // Warning: this is brittle atm and needs vectors to be mapped to 1-D xfers.
  // Alternatively we could now automatically unroll to 1-D innermost vectors.
  // ===========================================================================
  // This must occur after bufferization because of the fancy CUDA types.
  %func_m_8 = transform.iree.vector.vector_to_mma_conversion %func_m_7 { use_wmma }
  // Pre cp-async cleanups.
  transform.iree.apply_patterns %variant_op_3 {canonicalization, cse}
  %func_m_9 = transform.iree.create_async_groups %func_m_8 {use_mma_sync = true} 
    : (!pdl.operation) -> (!pdl.operation)


  // Step 11. Pipeline shared memory copies.
  // ===========================================================================
  %for = transform.structured.match ops{["scf.for"]} 
    filter_result_type = !gpu.mma_matrix<16x16xf32, "COp"> in %variant_op_3
    : (!pdl.operation) -> !transform.op<"scf.for">
  %pipelined_for = transform.iree.pipeline_shared_memory_copies %for { depth = 2 } 
    : (!transform.op<"scf.for">) -> !transform.op<"scf.for">

  // Late canonicalizations and cleanups.
  transform.iree.apply_patterns %variant_op_3 
    {canonicalization, cse, licm, tiling_canonicalization}
}
