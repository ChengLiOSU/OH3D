#ifndef MODEL_GRID_RENDERABLE_H
#define MODEL_GRID_RENDERABLE_H
#include "Renderable.h"
#include <memory>
class LineSplitModelGrid;
class Lens;

class ModelGridRenderable : public Renderable{
	LineSplitModelGrid* modelGrid;
	std::shared_ptr<float3> gridPts;
	unsigned int vertex_handle = 0;
	unsigned int triangle_handle = 0;

	std::vector<Lens*> *lenses = 0;

public:
	ModelGridRenderable(LineSplitModelGrid* _modelGrid);// float dmin[3], float dmax[3], int nPart);
	void SetLenses(std::vector<Lens*> *_lenses){ lenses = _lenses; }

protected:
	void init() override;
	void draw(float modelview[16], float projection[16]) override;
	void mouseRelease(int x, int y, int modifier) override;

};
#endif