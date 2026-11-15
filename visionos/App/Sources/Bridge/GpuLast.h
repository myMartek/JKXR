// The GPU's working time for this process, and the shaders it had compiled, for the performance panel (Sources/Leistung/Leistungsanzeige.swift).
// See GpuLast.m.
#ifndef JKXR_GPU_LAST_H
#define JKXR_GPU_LAST_H

// Starts counting. Returns 1 when every command buffer committed from here on is counted, 0 where there is no Metal device or its
// command buffers cannot be extended. Once per process; later calls return what the first one did.
int jkxr_gpu_busy_install(void);
// The seconds the GPU worked on this process's command buffers since the last call, overlapping spans counted once, and how many
// buffers that was. Negative while nothing is installed.
double jkxr_gpu_busy_take(unsigned long *buffers);
// How many times the process asked Metal for a library from source or a render pipeline state since the last call, in two counts:
// the requests that took long enough to have been compiled, and the ones answered at once from what the system had compiled before.
void jkxr_gpu_compiles_take(unsigned long *compiled, unsigned long *cached);

#endif
