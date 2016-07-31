#ifndef GLYPH_RENDERABLE_H
#define GLYPH_RENDERABLE_H

#include "Renderable.h"
#include <memory>
class DeformInterface;
class ShaderProgram;
class QOpenGLContext;
class ModelGrid;
class StopWatchInterface;
enum COLOR_MAP;

class GlyphRenderable: public Renderable
{
	Q_OBJECT
	bool frameBufferObjectInitialized = false;

	/****timing****/
	StopWatchInterface *deformTimer = 0;
	int fpsCount = 0;        // FPS count for averaging
	int fpsLimit = 128;        // FPS limit for sampling
	void StartDeformTimer();
	void StopDeformTimer();
	bool displaceEnabled = true;
public:
	//used for feature freezing rendering
	bool isFreezingFeature = false;
	std::vector<char> feature;
	std::vector<float3> featureCenter;
	void SetFeature(std::vector<char> & _feature, std::vector<float3> & _featureCenter);

	//used for feature snapping
	bool isPickingFeature = false;
	int GetSnappedFeatureId(){ return snappedFeatureId; }
	void SetSnappedFeatureId(int s){ snappedFeatureId = s; }
	bool findClosetFeature(float3 aim, float3 & result, int & resid);

	//used for picking and snapping
	bool isPickingGlyph = false;
	int GetSnappedGlyphId(){ return snappedGlyphId; }
	void SetSnappedGlyphId(int s){ snappedGlyphId = s; }
	float3 findClosetGlyph(float3 aim);
	void SetModelGrid(ModelGrid* _modelGrid){ modelGrid = _modelGrid; }

	void EnableDisplace(bool v){ displaceEnabled = v; }

	virtual void resetColorMap(COLOR_MAP cm) = 0;

protected:
	std::vector<float4> pos; 
	std::vector<float4> posOrig;
	std::shared_ptr<DeformInterface> deformInterface;
	ModelGrid* modelGrid;
	std::vector<float> glyphSizeScale;
	std::vector<float> glyphBright;
	float glyphSizeAdjust = 1.0f;
	ShaderProgram* glProg = nullptr;
	//bool displaceOn = true;
	void ComputeDisplace(float _mv[16], float pj[16]);
	void mouseMove(int x, int y, int modifier) override;
	void resize(int width, int height) override;
	void init() override;
	GlyphRenderable(std::vector<float4>& _pos);

	//used for picking and snapping
	unsigned int vbo_vert_picking, vbo_indices_picking;
	ShaderProgram *glPickingProg;
	unsigned int framebuffer, renderbuffer[2];
	void mousePress(int x, int y, int modifier) override;
	virtual void initPickingDrawingObjects() = 0;
	virtual void drawPicking(float modelview[16], float projection[16], bool isForGlyph) = 0; //if isForGlyph=false, then it is for feature
	int snappedGlyphId = -1;
	int snappedFeatureId = -1;

public:
	~GlyphRenderable();
	void RecomputeTarget();
	void DisplacePoints(std::vector<float2>& pts);
	virtual void LoadShaders(ShaderProgram*& shaderProg) = 0;
	virtual void DrawWithoutProgram(float modelview[16], float projection[16], ShaderProgram* sp) = 0;
	//void SetDispalceOn(bool b) { displaceOn = b; }
	void SetGlyphSizeAdjust(float v){ glyphSizeAdjust = v; }

	int GetNumOfGlyphs(){ return pos.size(); }

public slots:
	void SlotGlyphSizeAdjustChanged(int v);

signals:
	void glyphPickingFinished();
	void featurePickingFinished();
};
#endif