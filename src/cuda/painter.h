#pragma once

#include <memory>

#include "../brush_settings.h"
#include "../brush_type.h"

class Painter {
public:
	virtual ~Painter() {}

	void setBrush(const BrushSettings& settings) { this->brushSettings = settings; }
	int getWidth() { return w; }
	int getHeight() { return h; }

	void paint(int x, int y, uchar4 *pbo);

	virtual void setDimensions(int w, int h, uchar4 *pbo) = 0;
	virtual void setBrushType(BrushType type) = 0;

	static std::unique_ptr<Painter> make_painter(bool is_gpu);
private:
	virtual void doPainting(int x, int y, uchar4 *pbo) = 0;

protected:
	BrushSettings brushSettings;

	int w, h;
};