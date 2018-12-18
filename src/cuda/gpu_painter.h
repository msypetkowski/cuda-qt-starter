#pragma once

#include <string>

#include "painter.h"

#include "cuda_runtime.h"

void setupCuda();

class GPUPainter : public Painter {
public:
	~GPUPainter() override {}

	void setDimensions(int w, int h, uchar4 *pbo) override;
	void setBrushType(BrushType type) override;
	int getBufferIndex(int x, int y) override;
	void setTexture(const std::string& type, const unsigned char *data);

private:
	void doPainting(int x, int y, uchar4 *pbo) override;

	int w, h;
};