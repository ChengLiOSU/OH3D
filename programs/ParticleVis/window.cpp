#include "window.h"
#include "glwidget.h"
#include "BoxRenderable.h"
#include "LensRenderable.h"
#include "GridRenderable.h"
#include "Displace.h"

#include "SphereRenderable.h"
#include "ParticleReader.h"
#include "DataMgr.h"
#include "ModelGridRenderable.h"
#include <ModelGrid.h>
#include "GLMatrixManager.h"
#include "PolyRenderable.h"
#include "MeshReader.h"

#ifdef USE_LEAP
#include <LeapListener.h>
#include <Leap.h>
#endif

#ifdef USE_OSVR
#include "VRWidget.h"
#include "VRGlyphRenderable.h"
#endif

QSlider* CreateSlider()
{
	QSlider* slider = new QSlider(Qt::Horizontal);
	slider->setRange(0, 10);
	slider->setValue(5);
	return slider;
}

class GLTextureCube;
Window::Window()
{
    setWindowTitle(tr("Interactive Glyph Visualization"));
	QHBoxLayout *mainLayout = new QHBoxLayout;

	dataMgr = std::make_unique<DataMgr>();
	
	std::unique_ptr<Reader> reader;

	const std::string dataPath = dataMgr->GetConfig("DATA_PATH");
	reader = std::make_unique<ParticleReader>(dataPath.c_str());
	glyphRenderable = std::make_unique<SphereRenderable>(
		((ParticleReader*)reader.get())->GetPos(),
		((ParticleReader*)reader.get())->GetVal());
	std::cout << "number of rendered glyphs: " << (((ParticleReader*)reader.get())->GetVal()).size() << std::endl;
	std::cout << "number of rendered glyphs: " << glyphRenderable->GetNumOfGlyphs() << std::endl;

	/********GL widget******/
#ifdef USE_OSVR
	matrixMgr = std::make_shared<GLMatrixManager>(true);
#else
	matrixMgr = std::make_shared<GLMatrixManager>(false);
#endif
	openGL = std::make_unique<GLWidget>(matrixMgr);
	lensRenderable = std::make_unique<LensRenderable>();
	//lensRenderable->SetDrawScreenSpace(false);
#ifdef USE_OSVR
		vrWidget = std::make_unique<VRWidget>(matrixMgr, openGL.get());
		vrWidget->setWindowFlags(Qt::Window);
		vrGlyphRenderable = std::make_unique<VRGlyphRenderable>(glyphRenderable.get());
		vrWidget->AddRenderable("glyph", vrGlyphRenderable.get());
		vrWidget->AddRenderable("lens", lensRenderable.get());
		openGL->SetVRWidget(vrWidget.get());
#endif
	QSurfaceFormat format;
	format.setDepthBufferSize(24);
	format.setStencilBufferSize(8);
	format.setVersion(2, 0);
	format.setProfile(QSurfaceFormat::CoreProfile);
	openGL->setFormat(format); // must be called before the widget or its parent window gets shown


	float3 posMin, posMax;
	reader->GetPosRange(posMin, posMax);
	gridRenderable = std::make_unique<GridRenderable>(64);
	matrixMgr->SetVol(posMin, posMax);// cubemap->GetInnerDim());
	modelGrid = std::make_shared<ModelGrid>(&posMin.x, &posMax.x, 22);
	modelGridRenderable = std::make_unique<ModelGridRenderable>(modelGrid.get());
	glyphRenderable->SetModelGrid(modelGrid.get());
	//openGL->AddRenderable("bbox", bbox);
	openGL->AddRenderable("glyph", glyphRenderable.get());
	openGL->AddRenderable("lenses", lensRenderable.get());
	openGL->AddRenderable("grid", gridRenderable.get());
	openGL->AddRenderable("model", modelGridRenderable.get());
	///********controls******/
	addLensBtn = new QPushButton("Add circle lens");
	addLineLensBtn = new QPushButton("Add straight band lens");
	delLensBtn = std::make_unique<QPushButton>("Delete a lens");
	addCurveBLensBtn = new QPushButton("Add curved band lens");
	saveStateBtn = std::make_unique<QPushButton>("Save State");
	loadStateBtn = std::make_unique<QPushButton>("Load State");

	QCheckBox* gridCheck = new QCheckBox("Grid", this);
	QLabel* transSizeLabel = new QLabel("Transition region size:", this);
	QSlider* transSizeSlider = CreateSlider();
#ifdef USE_LEAP
	listener = new LeapListener();
	controller = new Leap::Controller();
	controller->setPolicyFlags(Leap::Controller::PolicyFlag::POLICY_OPTIMIZE_HMD);
	controller->addListener(*listener);
#endif

	QGroupBox *groupBox = new QGroupBox(tr("Deformation Mode"));
	QHBoxLayout *deformModeLayout = new QHBoxLayout;
	radioDeformScreen = std::make_unique<QRadioButton>(tr("&screen space"));
	radioDeformObject = std::make_unique<QRadioButton>(tr("&object space"));
	radioDeformScreen->setChecked(true);
	deformModeLayout->addWidget(radioDeformScreen.get());
	deformModeLayout->addWidget(radioDeformObject.get());
	groupBox->setLayout(deformModeLayout);

	usingGlyphSnappingCheck = new QCheckBox("Snapping Glyph", this);
	usingGlyphPickingCheck = new QCheckBox("Picking Glyph", this);

	connect(glyphRenderable.get(), SIGNAL(glyphPickingFinished()), this, SLOT(SlotToggleGlyphPickingFinished()));


	QVBoxLayout *controlLayout = new QVBoxLayout;
	controlLayout->addWidget(addLensBtn);
	controlLayout->addWidget(addLineLensBtn);

	controlLayout->addWidget(addCurveBLensBtn);
	controlLayout->addWidget(delLensBtn.get());
	controlLayout->addWidget(saveStateBtn.get());
	controlLayout->addWidget(loadStateBtn.get());
	controlLayout->addWidget(groupBox);
	controlLayout->addWidget(transSizeLabel);
	controlLayout->addWidget(transSizeSlider);
	controlLayout->addWidget(usingGlyphSnappingCheck);
	controlLayout->addWidget(usingGlyphPickingCheck);
	controlLayout->addWidget(gridCheck);
	controlLayout->addStretch();

	connect(addLensBtn, SIGNAL(clicked()), this, SLOT(AddLens()));
	connect(addLineLensBtn, SIGNAL(clicked()), this, SLOT(AddLineLens()));
	connect(addCurveBLensBtn, SIGNAL(clicked()), this, SLOT(AddCurveBLens()));
	connect(delLensBtn.get(), SIGNAL(clicked()), lensRenderable.get(), SLOT(SlotDelLens()));
	connect(saveStateBtn.get(), SIGNAL(clicked()), this, SLOT(SlotSaveState()));
	connect(loadStateBtn.get(), SIGNAL(clicked()), this, SLOT(SlotLoadState()));


	connect(gridCheck, SIGNAL(clicked(bool)), this, SLOT(SlotToggleGrid(bool)));
	connect(transSizeSlider, SIGNAL(valueChanged(int)), lensRenderable.get(), SLOT(SlotFocusSizeChanged(int)));
#ifdef USE_LEAP
	connect(listener, SIGNAL(UpdateHands(QVector3D, QVector3D, int)),
		this, SLOT(SlotUpdateHands(QVector3D, QVector3D, int)));
#endif
	connect(usingGlyphSnappingCheck, SIGNAL(clicked(bool)), this, SLOT(SlotToggleUsingGlyphSnapping(bool)));
	connect(usingGlyphPickingCheck, SIGNAL(clicked(bool)), this, SLOT(SlotTogglePickingGlyph(bool)));
	connect(radioDeformObject.get(), SIGNAL(clicked(bool)), this, SLOT(SlotDeformModeChanged(bool)));
	connect(radioDeformScreen.get(), SIGNAL(clicked(bool)), this, SLOT(SlotDeformModeChanged(bool)));
	
	mainLayout->addWidget(openGL.get(), 3);
	mainLayout->addLayout(controlLayout,1);
	setLayout(mainLayout);
}

void Window::AddLens()
{
	lensRenderable->AddCircleLens();
}

void Window::AddLineLens()
{
	lensRenderable->AddLineBLens();
}


void Window::AddCurveBLens()
{
	lensRenderable->AddCurveBLens();
}


void Window::SlotTogglePickingGlyph(bool b)
{
	glyphRenderable->isPickingGlyph = b;
}


void Window::SlotToggleUsingGlyphSnapping(bool b)
{
	lensRenderable->isSnapToGlyph = b;
	if (!b){
		glyphRenderable->SetSnappedGlyphId(-1);
	}
}

void Window::SlotToggleGrid(bool b)
{
	modelGridRenderable->SetVisibility(b);
}

Window::~Window() {
}

void Window::init()
{
#ifdef USE_OSVR
		vrWidget->show();
#endif
}

#ifdef USE_LEAP
void Window::SlotUpdateHands(QVector3D leftIndexTip, QVector3D rightIndexTip, int numHands)
{
	if (1 == numHands){
		lensRenderable->SlotOneHandChanged(make_float3(rightIndexTip.x(), rightIndexTip.y(), rightIndexTip.z()));
	}
	else if(2 == numHands){
		//
		lensRenderable->SlotTwoHandChanged(
			make_float3(leftIndexTip.x(), leftIndexTip.y(), leftIndexTip.z()),
			make_float3(rightIndexTip.x(), rightIndexTip.y(), rightIndexTip.z()));
		
	}
}
#endif

void Window::SlotSaveState()
{
	matrixMgr->SaveState("current.state");
}

void Window::SlotLoadState()
{
	matrixMgr->LoadState("current.state");
}


void Window::SlotToggleGlyphPickingFinished()
{
	usingGlyphPickingCheck->setChecked(false);
}

void Window::SlotDeformModeChanged(bool clicked)
{
	if (radioDeformScreen->isChecked()){
		openGL->SetDeformModel(DEFORM_MODEL::SCREEN_SPACE);
	}
	else if (radioDeformObject->isChecked()){
		openGL->SetDeformModel(DEFORM_MODEL::OBJECT_SPACE);
	}
}
