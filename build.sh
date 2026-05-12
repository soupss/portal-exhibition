#!/bin/sh

naga --shader-stage compute --input-kind glsl shaders/compute.glsl shaders/compute.wgsl
naga --shader-stage vertex --input-kind glsl shaders/vertex.glsl shaders/vertex.wgsl
naga --shader-stage fragment --input-kind glsl shaders/fragment.glsl shaders/fragment.wgsl
emcc -s USE_WEBGPU=1 -s WASM_BIGINT=1 -s ASYNCIFY -s EXPORTED_RUNTIME_METHODS="['ccall']" --embed-file shaders/ main.c -o main.js
