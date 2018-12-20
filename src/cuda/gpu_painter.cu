#include "gpu_painter.h"

#include <iostream>

#include "helper_cuda.h"
#include "helper_math.h"


void setupCuda() {
    checkCudaErrors(cudaSetDevice(0));
}

bool __device__ in_bounds(int x, int y, int w, int h) {
    return x >= 0 && x < w && y >= 0 && y < h;
}

float3 __device__ d_interpolate_color(float3 oldColor, float strength, const float3 &newColor) {
    float3 ret;
    ret = lerp(oldColor, newColor, strength);
    ret = clamp(ret, make_float3(0, 0, 0), make_float3(255, 255, 255));
    return ret;
}

float __device__ d_cosine_fallof(float val, float falloff) {
    val = powf(val, falloff);
    return (cosf(val * M_PI) + 1.0f) * 0.5f;
}

float __device__ d_normal_from_delta(float dx) {
    return dx / sqrtf(dx * dx + 1);
}

int __device__ d_getBufferIndex(int x, int y, int w) { return (w - 1 - x + (y * w)); };

float __device__ d_sampleHeight(int x, int y, int w, int h, float *buffer_height) {
    x = clamp(x, 0, w - 1);
    y = clamp(y, 0, h - 1);
    return buffer_height[d_getBufferIndex(x, y, w)];
}

float3 __device__ d_getNormal(int x, int y, int w, int h, float *buffer_height) {
    float dx = 0.0f, dy = 0.0f;

    auto mid = d_sampleHeight(x, y, w, h, buffer_height);
    auto left = d_sampleHeight(x - 1, y, w, h, buffer_height);
    auto right = d_sampleHeight(x + 1, y, w, h, buffer_height);
    auto top = d_sampleHeight(x, y + 1, w, h, buffer_height);
    auto bottom = d_sampleHeight(x, y - 1, w, h, buffer_height);

    dx += d_normal_from_delta(mid - right) / 2;
    dx -= d_normal_from_delta(mid - left) / 2;

    dy += d_normal_from_delta(mid - top) / 2;
    dy -= d_normal_from_delta(mid - bottom) / 2;

    // TODO: make parameter or constant
    dx *= 100;
    dy *= 100;

    dx = dx / sqrtf(dx * dx + dy * dy + 1);
    dy = dy / sqrtf(dx * dx + dy * dy + 1);

    auto ret = make_float3(dx, dy, sqrtf(clamp(1.0f - dx * dx - dy * dy, 0.0f, 1.0f)));
    return normalize(ret);
}


void __device__ brushBasicPixel(int x, int y, int mx, int my, int w, int h,
                                float *buffer_height, float3 *buffer_color, BrushSettings bs) {

    float radius = sqrtf((x - mx) * (x - mx) + (y - my) * (y - my));
    float brush_radius = bs.size / 2.0f;
    if (radius > brush_radius) {
        return;
    }
    int i = d_getBufferIndex(x, y, w);

    // paint color
    float strength = bs.pressure * d_cosine_fallof(radius / brush_radius, bs.falloff);
    float3 color = d_interpolate_color(buffer_color[i], strength, bs.color);
    buffer_color[i] = color;

    // paint height
    strength = bs.heightPressure * d_cosine_fallof(radius / brush_radius, bs.falloff);
    buffer_height[i] = clamp(buffer_height[i] + strength, -1.0f, 1.0f);
}

__device__
void updateDisplayPixel(int x, int y, int w, int h, uchar4 *buffer_pbo, float *buffer_height, float3 *buffer_color) {
    int i = d_getBufferIndex(x, y, w);

    auto normal = d_getNormal(x, y, w, h, buffer_height);

    float3 lighting = normalize(make_float3(0.07f, 0.07f, 1.0f));

    // TODO: use lighting vector here
    float shadow =
            normal.z * 0.80f - normal.x * 0.1f - normal.y * 0.1f + (d_sampleHeight(x, y, w, h, buffer_height)) / 4.0f;
    shadow = clamp(shadow, 0.0f, 1.0f);

    float specular = 1.0f - length(normal - lighting);
    specular = powf(specular, 8.0f);
    specular = clamp(specular, 0.0f, 1.0f);

    float3 color = lerp(buffer_color[i] * shadow, make_float3(255.0f), specular);

    // view normals (TODO: remove or make normals visualization feature)
    /*color.x = normal.x * 255.0 / 2 + 255.0 / 2;
    color.y = normal.y * 255.0 / 2 + 255.0 / 2;
    color.z = normal.z * 255;*/
    //color = clamp(color, make_float3(0.0f), make_float3(255.0f));
    buffer_pbo[i] = make_uchar4(color.x, color.y, color.z, 0);
}

// kernels
// Kernel that paints brush basic
__global__
void brushBasicKernel(uchar4 *pbo, float *buffer_height, float3 *buffer_color,
                      int width, int height, int mx, int my, const BrushSettings bs) {

    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (in_bounds(x, y, width, height)) {

        // use brush
        brushBasicPixel(x, y, mx, my, width, height, buffer_height, buffer_color, bs);

        // shading pixels
        updateDisplayPixel(x, y, width, height, pbo, buffer_height, buffer_color);
    }
}


void GPUPainter::setDimensions(int w1, int h1, uchar4 *pbo) {
    w = w1;
    h = h1;

    buffer_pbo = pbo;

    int buf_size = w * h;

    printf("init/resize gpu buffers (%d, %d)\n", w, h);

    checkCudaErrors(cudaFree(buffer_color));
    checkCudaErrors(cudaFree(buffer_height));

    checkCudaErrors(cudaMalloc((void **) &buffer_height, buf_size * sizeof(float)));
    checkCudaErrors(cudaMemset(buffer_height, 0, buf_size * sizeof(float)));

    checkCudaErrors(cudaMalloc((void **) &buffer_color, buf_size * sizeof(float3)));
    // @ TODO init buffer with correct color
    checkCudaErrors(cudaMemset(buffer_color, 0, buf_size * sizeof(float3)));

}

void GPUPainter::setBrushType(BrushType type) {
    using namespace std::placeholders;
    switch (type) {
        case BrushType::Default:
            paint_function = std::bind(&GPUPainter::brushBasic, this, _1, _2);
            break;
        case BrushType::Textured:
            paint_function = std::bind(&GPUPainter::brushTextured, this, _1, _2);
            break;
        case BrushType::Third:
            std::clog << "Warning: chose unused brush\n";
            break;
        default:
            throw std::runtime_error("Invalid brush type: "
                                     + std::to_string(static_cast<int>(type)));
    }
}

void GPUPainter::setTexture(const std::string &type, const unsigned char *data, int width, int height) {
    image_height = height;
    image_width = width;

    if (type == "colorFilename") {
        checkCudaErrors(cudaMalloc((void **) &d_color_texture, sizeof(data)));
        checkCudaErrors(cudaMemcpy(d_color_texture, data, sizeof(data), cudaMemcpyHostToDevice));
    } else {
        checkCudaErrors(cudaMalloc((void **) &d_height_texture, sizeof(data)));
        checkCudaErrors(cudaMemcpy(d_height_texture, data, sizeof(data), cudaMemcpyHostToDevice));
    }
}

void GPUPainter::doPainting(int x, int y, uchar4 *pbo) {
    paint_function(x, y);
    //std::clog << "[GPU] Painting: " << painting_duration / 1e6f << "ms\n";
}

// brush functions
void GPUPainter::brushBasic(int mx, int my) {
    const int blockSideLength = 32;
    const dim3 blockSize(blockSideLength, blockSideLength);
    const dim3 blocksPerGrid(
            (w + blockSize.x - 1) / blockSize.x,
            (h + blockSize.y - 1) / blockSize.y);
    // @ TODO compute cuda time
    brushBasicKernel << < blocksPerGrid, blockSize >> >
                                         (buffer_pbo, buffer_height, buffer_color, w, h, mx, my, brushSettings);
    checkCudaErrors(cudaDeviceSynchronize());
}

void GPUPainter::brushTextured(int mx, int my) {
    // @TODO
}

