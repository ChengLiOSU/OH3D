#ifndef LENS_H
#define LENS_H
#include <vector_types.h>
#include <helper_math.h>
#include <vector>


enum LENS_TYPE{
	TYPE_CIRCLE,
	TYPE_LINE,
	TYPE_POLYLINE
};
struct Lens
{
	LENS_TYPE type;
	float3 c; //center
	int x, y; //screen location
	float4 GetCenter();// { return make_float4(c.x, c.y, c.z, 1.0f); }
	void SetCenter(float3 _c){ c = _c; }
	float GetClipDepth(float* mv, float* pj);
	Lens(int _x, int _y, float3 _c) { x = _x; y = _y; c = _c; }
	virtual bool PointInsideLens(int x, int y) = 0;
	virtual std::vector<float2> GetContour() = 0;
	void ChangeClipDepth(int v, float* mv, float* pj);
	LENS_TYPE GetType(){ return type; }
};

struct CircleLens :public Lens
{
	float radius;
	CircleLens(int _x, int _y, int _r, float3 _c) : Lens(_x, _y, _c){ radius = _r; type = LENS_TYPE::TYPE_CIRCLE; };
	bool PointInsideLens(int _x, int _y) {
		float dis = length(make_float2(_x, _y) - make_float2(x, y));
		return dis < radius;
	}

	std::vector<float2> GetContour() {
		std::vector<float2> ret;
		const int num_segments = 32;
		for (int ii = 0; ii < num_segments; ii++)
		{
			float theta = 2.0f * 3.1415926f * float(ii) / float(num_segments);//get the current angle 

			float ax = radius * cosf(theta);//calculate the x component 
			float ay = radius * sinf(theta);//calculate the y component 

			ret.push_back(make_float2(x + ax, y + ay));//output vertex 
		}
		return ret;
	}


};


struct LineLens :public Lens
{
	float lSemiMajorAxis, lSemiMinorAxis;
	float2 direction; //suppose normalized
	float ratio; //the ratio of lSemiMajorAxis and lSemiMinorAxis

	LineLens(int _x, int _y, int _r, float3 _c) : Lens(_x, _y, _c){ 
		lSemiMajorAxis = _r;
		ratio = 3.0f;
		lSemiMinorAxis = lSemiMajorAxis / ratio;

		direction = make_float2(1.0, 0.0);
		type = LENS_TYPE::TYPE_LINE;
	};

	bool PointInsideLens(int _x, int _y) {
		//sigmoid function: y=2*(1/(1+e^(-20*(x+1)))-0.5), x in [-1,0]
		//sigmoid function: y=2*(1/(1+e^(20*(x-1)))-0.5), x in [0,1]

		//dot product of (_x-x, _y-y) and direction

		float2 toPoint = make_float2(_x - x, _y - y);
		float disMajor = toPoint.x*direction.x + toPoint.y*direction.y;

		if (abs(disMajor) < lSemiMajorAxis) {
			float2 minorDirection = make_float2(-direction.y, direction.x);
			//dot product of (_x-x, _y-y) and minorDirection
			float disMinor = (_x - x)*minorDirection.x + (_y - y)*minorDirection.y;
			
			float disMajorRatio = disMajor / lSemiMajorAxis;
			float disSigmoid;
			if (disMajorRatio < 0){
				disSigmoid = 1 / (1 + exp(-40 * (disMajorRatio + 0.8))) ;
			}
			else {
				disSigmoid = 1 / (1 + exp(40 * (disMajorRatio - 0.8))) ;
			}

			if (abs(disMinor) < disSigmoid*lSemiMinorAxis)
				return true;
		}
		return false;
	}

	std::vector<float2> GetContour() {
		//sigmoid function: y=2*(1/(1+e^(-20*(x+1)))-0.5), x in [-1,0]
		//sigmoid function: y=2*(1/(1+e^(20*(x-1)))-0.5), x in [0,1]
		float sigmoidCutOff = 0.4f; // assuming the sigmoid function value is constant when input is larger than sigmoidCutOff

		float2 minorDirection = make_float2(-direction.y, direction.x);

		std::vector<float2> ret;

		const int num_segments = 20;
		for (int ii = 0; ii < num_segments; ii++)
		{
			float tt = -1.0f + sigmoidCutOff*ii / num_segments;

			ret.push_back(make_float2(x, y) + tt*lSemiMajorAxis*direction
				+ (1 / (1 + exp(-40 * (tt + 0.8)))) *lSemiMinorAxis *minorDirection);//output vertex 
		}

		for (int ii = 0; ii < num_segments; ii++)
		{
			float tt = 1.0f - sigmoidCutOff + sigmoidCutOff*ii / num_segments;

			ret.push_back(make_float2(x, y) + tt*lSemiMajorAxis*direction
				+ (1 / (1 + exp(40 * (tt - 0.8)))) *lSemiMinorAxis *minorDirection);//output vertex 
		}

		
		for (int ii = 0; ii < num_segments; ii++)
		{
			float tt = 1.0f - sigmoidCutOff*ii / num_segments;

			ret.push_back(make_float2(x, y) + tt*lSemiMajorAxis*direction
				- (1 / (1 + exp(40 * (tt - 0.8)))) *lSemiMinorAxis *minorDirection);//output vertex 
		}

		for (int ii = 0; ii < num_segments; ii++)
		{
			float tt = -1.0f + sigmoidCutOff - sigmoidCutOff*ii / num_segments;

			ret.push_back(make_float2(x, y) + tt*lSemiMajorAxis*direction
				- (1 / (1 + exp(-40 * (tt + 0.8)))) *lSemiMinorAxis *minorDirection);//output vertex 
		}
		
		return ret;
	}
};

struct PolyLineLens :public Lens
{
	float width;
	int numCtrlPoints;
	//!note!  positions relative to the center
	float2 *ctrlPoints; //need to delete when release

	float2 direction;
	float lSemiMajor, lSemiMinor;

	PolyLineLens(int _x, int _y, int _w, float3 _c) : Lens(_x, _y, _c){
		width = _w;

		numCtrlPoints = 5;
		ctrlPoints = new float2[numCtrlPoints];

		ctrlPoints[0].x = 100;
		ctrlPoints[0].y = 90;

		ctrlPoints[1].x = 30;
		ctrlPoints[1].y = 40;

		ctrlPoints[2].x = 0;
		ctrlPoints[2].y = 0;

		ctrlPoints[3].x = -33;
		ctrlPoints[3].y = -20;

		ctrlPoints[4].x = -70;
		ctrlPoints[4].y = -110;

		type = LENS_TYPE::TYPE_POLYLINE;


		//compute PCA
		//X is matrix formed by row vectors of points, i.e., X=[ctrlPoints[0].x, ctrlPoints[0].y;ctrlPoints[1].x, ctrlPoints[1].y;...]
		//get the eignevector of A = X'X
		float A11 = 0, A12 = 0, A21 = 0, A22 = 0;
		for (int ii = 0; ii < numCtrlPoints; ii++) {
			A11 += ctrlPoints[ii].x * ctrlPoints[ii].x;
			A22 += ctrlPoints[ii].y * ctrlPoints[ii].y;
			A12 += ctrlPoints[ii].x * ctrlPoints[ii].y;
			A21 += ctrlPoints[ii].y * ctrlPoints[ii].x;
		}
		//Av=lv -> (A-lI)v=0 -> f(l) = |A-lI| = 0 -> (A11-l)*(A22-l)-A12*A21 = 0
		//-> l^2 - (A11+A22)*l + A11*A22-A12*A21 = 0;
		float equa = 1, equb = -(A11 + A22), equc = A11*A22 - A12*A21;
		float lembda1 = (-equb + sqrt(equb*equb - 4 * equa * equc)) / 2.0 / equa;
		//Av=lv -> (A-lI)v=0 -> (A11-l, A12) .* (v1, v2) = 0
		direction = normalize( make_float2(-A12, A11 - lembda1));

		float2 minorDirection = make_float2(-direction.y, direction.x);

		float maxMajor = -9999, maxMinor = -9999, minMajor = 9999, minMinor = 9999;
		for (int ii = 0; ii < numCtrlPoints; ii++) {
			//(ctrlPoints[ii].x - x, ctrlPoints[ii].y - y) dot product direction (and minorDirection)
			float disMajorii = (ctrlPoints[ii].x)*direction.x + (ctrlPoints[ii].y)*direction.y;
			float disMinorii = (ctrlPoints[ii].x)*minorDirection.x + (ctrlPoints[ii].y)*minorDirection.y;
			if (disMajorii > maxMajor)
				maxMajor = disMajorii;
			if (disMajorii < minMajor)
				minMajor = disMajorii;
			if (disMinorii > maxMinor)
				maxMinor = disMinorii;
			if (disMinorii < minMinor)
				minMinor = disMinorii;
		}

		lSemiMajor = max(abs(maxMajor), abs(minMajor)) * 1.1;
		lSemiMinor = max(abs(maxMinor), abs(minMinor)) * 1.1;

	};

	bool PointInsideLens(int _x, int _y)
	{
		

		return true;
	}

	std::vector<float2> GetContour(){
		std::vector<float2> ret;

		/*
		for (int ii = 0; ii < numCtrlPoints; ii++) {
			ret.push_back(make_float2(ctrlPoints[ii].x, ctrlPoints[ii].y + 40));
		}

		for (int ii = numCtrlPoints-1; ii >=0; ii--) {
			ret.push_back(make_float2(ctrlPoints[ii].x, ctrlPoints[ii].y - 40));
		}
		*/

		float2 minorDirection = make_float2(-direction.y, direction.x);

		ret.push_back(make_float2(x + direction.x * lSemiMajor + minorDirection.x * lSemiMinor, y + direction.y * lSemiMajor + minorDirection.y * lSemiMinor));
		ret.push_back(make_float2(x - direction.x * lSemiMajor + minorDirection.x * lSemiMinor, y - direction.y * lSemiMajor + minorDirection.y * lSemiMinor));
		ret.push_back(make_float2(x - direction.x * lSemiMajor - minorDirection.x * lSemiMinor, y - direction.y * lSemiMajor - minorDirection.y * lSemiMinor));
		ret.push_back(make_float2(x + direction.x * lSemiMajor - minorDirection.x * lSemiMinor, y + direction.y * lSemiMajor - minorDirection.y * lSemiMinor));

		return ret;
	}

	std::vector<float2> GetExtraLensRendering(){
		std::vector<float2> ret;

		for (int ii = 0; ii < numCtrlPoints; ii++) {
			ret.push_back(make_float2(ctrlPoints[ii].x+x, ctrlPoints[ii].y+y));
		}

		return ret;
	}

};
#endif