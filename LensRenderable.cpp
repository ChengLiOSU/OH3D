#include "LensRenderable.h"
#include "GlyphRenderable.h"
#include "Lens.h"
#include "glwidget.h"

void LensRenderable::init()
{

}

void LensRenderable::UpdateData() {

}

void LensRenderable::draw(float modelview[16], float projection[16])
{
	RecordMatrix(modelview, projection);

	int2 winSize = actor->GetWindowSize();
	glMatrixMode(GL_PROJECTION);
	glPushMatrix();
	glLoadIdentity();
	glOrtho(0.0, winSize.x - 1, 0.0, winSize.y - 1, -1, 1);

	glMatrixMode(GL_MODELVIEW);
	glPushMatrix();
	glLoadIdentity();

	glPushAttrib(GL_LINE_BIT | GL_CURRENT_BIT);
	glLineWidth(4);
	glColor3f(1.0f, 0.2f, 0.2f);
	for (int i = 0; i < lenses.size(); i++) {
		Lens* l = lenses[i];
		

		if (l->type == LENS_TYPE::TYPE_POLYLINE) {
			glColor3f(0.2f, 1.0f, 0.2f);

			std::vector<float2> lensExtraRendering = ((PolyLineLens*)l)->GetExtraLensRendering();
			glBegin(GL_LINE_STRIP);
			for (auto v : lensExtraRendering)
				glVertex2f(v.x, v.y);
			glEnd();

			glColor3f(1.0f, 0.2f, 0.2f);

		}
		else if (l->type == LENS_TYPE::TYPE_CURVE) {
			glColor3f(0.2f, 1.0f, 0.2f);

			std::vector<float2> lensExtraRendering = ((CurveLens*)l)->GetExtraLensRendering();
			glBegin(GL_LINE_STRIP);
			for (auto v : lensExtraRendering)
				glVertex2f(v.x, v.y);
			glEnd();
		}
		else if (l->type == LENS_TYPE::TYPE_CIRCLE){
			std::vector<float2> lensContour = l->GetContour();
			glBegin(GL_LINE_LOOP);
			for (auto v : lensContour)
				glVertex2f(v.x, v.y);
			glEnd();

			glColor3f(0.2f, 0.8f, 0.8f);
			for (int i = 0; i < lenses.size(); i++) {
				Lens* l = lenses[i];
				std::vector<float2> lensContour = l->GetOuterContour();
				glBegin(GL_LINE_LOOP);
				for (auto v : lensContour)
					glVertex2f(v.x, v.y);
				glEnd();
			}
		}
	}



	
	glPopAttrib();

	//restore the original 3D coordinate system
	glMatrixMode(GL_PROJECTION);
	glPopMatrix();
	glMatrixMode(GL_MODELVIEW);
	glPopMatrix();
}
//
//void Displace::AddSphereLens(int x, int y, int radius, float3 center)
//{
//	Lens* l = new CircleLens(x, y, radius, center);
//	lenses.push_back(l);
//}


void LensRenderable::AddCircleLens()
{
	int2 winSize = actor->GetWindowSize();
	Lens* l = new CircleLens(winSize.x * 0.5, winSize.y * 0.5, winSize.y * 0.2, actor->DataCenter());
	lenses.push_back(l);
	((GlyphRenderable*)actor->GetRenderable("glyph"))->RecomputeTarget();
	actor->UpdateGL();
}

void LensRenderable::AddLineLens()
{

	int2 winSize = actor->GetWindowSize();
	Lens* l = new LineLens(winSize.x * 0.5, winSize.y * 0.5, winSize.y * 0.2, actor->DataCenter());
	lenses.push_back(l);
	((GlyphRenderable*)actor->GetRenderable("glyph"))->RecomputeTarget();
	actor->UpdateGL();
}

void LensRenderable::AddPolyLineLens()
{
	int2 winSize = actor->GetWindowSize();
	Lens* l = new PolyLineLens(winSize.x * 0.5, winSize.y * 0.5, winSize.y * 0.05, actor->DataCenter());
	lenses.push_back(l);
	((GlyphRenderable*)actor->GetRenderable("glyph"))->RecomputeTarget();
	actor->UpdateGL();
	actor->SetInteractMode(INTERACT_MODE::MODIFYING_LENS);
}

void LensRenderable::AddCurveLens()
{
	int2 winSize = actor->GetWindowSize();
	Lens* l = new CurveLens(winSize.x * 0.5, winSize.y * 0.5, winSize.y * 0.05, actor->DataCenter());
	lenses.push_back(l);
	((GlyphRenderable*)actor->GetRenderable("glyph"))->RecomputeTarget();
	actor->UpdateGL();
	actor->SetInteractMode(INTERACT_MODE::MODIFYING_LENS);
}


void LensRenderable::mousePress(int x, int y, int modifier)
{
	if (INTERACT_MODE::MODIFYING_LENS == actor->GetInteractMode()) {
		for (int i = 0; i < lenses.size(); i++) {
			Lens* l = lenses[i];
			if (l->type == LENS_TYPE::TYPE_POLYLINE) {
				if (modifier == Qt::ControlModifier) {
					((PolyLineLens *)l)->AddCtrlPoint(x, y);
				}
				else{
					((PolyLineLens *)l)->FinishConstructing();
					actor->SetInteractMode(INTERACT_MODE::TRANSFORMATION);
				}
			}
			else if (l->type == LENS_TYPE::TYPE_CURVE) {
				if (modifier == Qt::ControlModifier) {
					((CurveLens *)l)->AddCtrlPoint(x, y);
				}
			}
		}
	}
	else {
		for (int i = 0; i < lenses.size(); i++) {
			Lens* l = lenses[i];
			if (l->PointInsideLens(x, y)) {
				//workingOnLens = true;
				actor->SetInteractMode(INTERACT_MODE::LENS);
				pickedLens = i;
				lastPt = make_int2(x, y);
			}
		}
	}
	//return insideAnyLens;
}

void LensRenderable::mouseRelease(int x, int y, int modifier)
{
	if (INTERACT_MODE::MODIFYING_LENS == actor->GetInteractMode()) {
		Lens* l = lenses[lenses.size() - 1];
		if (l->type == LENS_TYPE::TYPE_CURVE) {
			((CurveLens *)l)->FinishConstructing();
			actor->SetInteractMode(INTERACT_MODE::TRANSFORMATION);
		}
		else{
			//polyline lens
		}
	}
	else {
		actor->SetInteractMode(INTERACT_MODE::TRANSFORMATION);
	}

	((GlyphRenderable*)actor->GetRenderable("glyph"))->RecomputeTarget();
	//actor->SetInteractMode(INTERACT_MODE::TRANSFORMATION);
	//workingOnLens = false;
}

void LensRenderable::mouseMove(int x, int y, int modifier)
{
	if (INTERACT_MODE::MODIFYING_LENS == actor->GetInteractMode()) {
		Lens* l = lenses[lenses.size() - 1];
		if (l->type == LENS_TYPE::TYPE_CURVE){
			((CurveLens *)l)->AddCtrlPoint(x, y);
		}
	}
	else if (INTERACT_MODE::LENS == actor->GetInteractMode()) {
		lenses[pickedLens]->x += (x - lastPt.x);
		lenses[pickedLens]->y += (y - lastPt.y);
	}
	((GlyphRenderable*)actor->GetRenderable("glyph"))->RecomputeTarget();
	lastPt = make_int2(x, y);
}

bool LensRenderable::MouseWheel(int x, int y, int delta)
{
	bool insideAnyLens = false;
	for (int i = 0; i < lenses.size(); i++) {
		Lens* l = lenses[i];
		if (l->PointInsideLens(x, y)) {
			insideAnyLens = true;
			//std::cout << delta << std::endl;
			l->ChangeClipDepth(delta*0.1, &matrix_mv.v[0].x, &matrix_pj.v[0].x);
		}
	}
	((GlyphRenderable*)actor->GetRenderable("glyph"))->RecomputeTarget();
	return insideAnyLens;
}
//
//void LensRenderable::DisplacePoints(std::vector<float2>& pts)
//{
//	displace
//}
void LensRenderable::SlotFocusSizeChanged(int v)
{
	//displace->SetFocusRatio((10 - v) * 0.1 * 0.8 + 0.2);
	if (lenses.size() > 0){
		lenses.back()->SetFocusRatio((10 - v) * 0.1 * 0.8 + 0.2);
	}
	((GlyphRenderable*)actor->GetRenderable("glyph"))->RecomputeTarget();
//	displace->RecomputeTarget();
	actor->UpdateGL();
}


void LensRenderable::SlotSideSizeChanged(int v)// { displace - (10 - v) * 0.1; }
{
	//displace->SetSideSize(v * 0.1);
	if (lenses.size() > 0){
		lenses.back()->SetSideSize(v * 0.1);
	}
	((GlyphRenderable*)actor->GetRenderable("glyph"))->RecomputeTarget();
	//displace->RecomputeTarget();
	actor->UpdateGL();
}