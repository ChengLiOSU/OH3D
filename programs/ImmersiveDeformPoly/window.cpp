#include <window.h>
#include <iostream>

#include "myDefineRayCasting.h"
#include "GLWidget.h"
#include "DataMgr.h"
#include "GLMatrixManager.h"
#include "mouse/RegularInteractor.h"
#include "mouse/ImmersiveInteractor.h"
#include "AnimationByMatrixProcessor.h"
#include "Particle.h"

#include "MatrixMgrRenderable.h"
#include "DeformFrameRenderable.h"
#include "SphereRenderable.h"
#include "PolyRenderable.h"
#include "PolyMesh.h"

#include "PlyVTKReader.h"
#include "VTPReader.h"

#include "PositionBasedDeformProcessor.h"

#include <thrust/device_vector.h>

#ifdef USE_OSVR
#include "VRWidget.h"
#include "VRVolumeRenderableCUDA.h"
#endif

#ifdef USE_LEAP
#include <Leap.h>
#include "leap/LeapListener.h"
#include "leap/MatrixLeapInteractor.h"
#endif
#include "MarchingCube.h"
#include "VTIReader.h"
#include "MarchingCube2.h"

bool useMultiplePolyData = false;

Window::Window()
{
	setWindowTitle(tr("Egocentric Isosurface Visualization"));

	////////////////////////////////prepare data////////////////////////////////
	//////////////////Volume and RayCastingParameters
	std::shared_ptr<DataMgr> dataMgr;
	dataMgr = std::make_shared<DataMgr>();

	float disThr;
	std::string polyDataPath;

	if (useMultiplePolyData){
		const std::string polyDatasFolder = dataMgr->GetConfig("POLY_DATAS_FOLDER");
		std::string paths[2];
		paths[0] = polyDatasFolder + "sand60_067_xw2_iso0.0005_shiftedAndRespaced.vtp";
		paths[1] = polyDatasFolder + "sand60_067_xw2_iso0.0012_shiftedAndRespaced.vtp";

		PolyMesh::dataParameters(paths[0], disThr);

		for (int i = 0; i < 2; i++){
			std::shared_ptr<PolyMesh> curpolyMesh = std::make_shared<PolyMesh>();
			if (std::string(paths[i]).find(".ply") != std::string::npos){
				PlyVTKReader plyVTKReader;
				plyVTKReader.readPLYByVTK(paths[i].c_str(), curpolyMesh.get());
			}
			else{
				VTPReader reader;
				reader.readFile(paths[i].c_str(), curpolyMesh.get());
			}
			std::cout << "Read data from : " << paths[i] << std::endl;
			curpolyMesh->setVertexColorVals((i == 0) ? 0 : 1);

			polyMeshes.push_back(curpolyMesh);
		}

		polyMesh = std::make_shared<PolyMesh>();
		polyMesh->createByCombiningPolyMeshes(polyMeshes);

		for (int i = 0; i < 2; i++){
			polyMeshes[i].reset();
		}

		polyMesh->setVertexCoordsOri();
		polyMesh->setVertexDeviateVals();

	}
	else{
		polyDataPath = dataMgr->GetConfig("POLY_DATA_PATH");

		PolyMesh::dataParameters(polyDataPath, disThr);

		polyMesh = std::make_shared<PolyMesh>();
		if (std::string(polyDataPath).find("testDummy") != std::string::npos){
			polyMesh->createTestDummy();
			polyMesh->setVertexCoordsOri();
			polyMesh->setVertexDeviateVals();
			polyMesh->setVertexColorVals(0);
		
		}
		else if (std::string(polyDataPath).find(".vti") != std::string::npos){

			std::shared_ptr<Volume> inputVolume = std::make_shared<Volume>(true);
			VTIReader vtiReader(polyDataPath.c_str(), inputVolume);
					
			//std::shared_ptr<MarchingCube> mc = std::make_shared<MarchingCube>(inputVolume, polyMesh);
			mc = std::make_shared<MarchingCube2>(polyDataPath.c_str(), polyMesh, 0.0007);
			useIsoAdjust = true;


			polyMesh->setVertexCoordsOri();
			polyMesh->setVertexDeviateVals();
			//polyMesh->setVertexColorVals(0);  //VertexColorVals is set by MarchingCube2
		}
		else if(std::string(polyDataPath).find(".ply") != std::string::npos){
			PlyVTKReader plyVTKReader;
			plyVTKReader.readPLYByVTK(polyDataPath.c_str(), polyMesh.get());


			polyMesh->setVertexCoordsOri();
			polyMesh->setVertexDeviateVals();
			polyMesh->setVertexColorVals(0);
		}
		else{
			VTPReader reader;
			reader.readFile(polyDataPath.c_str(), polyMesh.get());

			polyMesh->setVertexCoordsOri();
			polyMesh->setVertexDeviateVals();
			polyMesh->setVertexColorVals(0);
		}
		   


		std::cout << "Read data from : " << polyDataPath << std::endl;

	}
	//polyMesh->checkShortestEdge();

	////////////////matrix manager
	float3 posMin, posMax;
	polyMesh->GetPosRange(posMin, posMax);
	std::cout << "posMin: " << posMin.x << " " << posMin.y << " " << posMin.z << std::endl;
	std::cout << "posMax: " << posMax.x << " " << posMax.y << " " << posMax.z << std::endl;
	matrixMgr = std::make_shared<GLMatrixManager>(posMin, posMax);
	matrixMgr->setDefaultForImmersiveMode();
	matrixMgrExocentric = std::make_shared<GLMatrixManager>(posMin, posMax);

	matrixMgr->moveEyeInLocalByModeMat(make_float3(matrixMgr->getEyeInLocal().x - 10, -20, matrixMgr->getEyeInLocal().z));

	////for test with testDummy
	if (std::string(polyDataPath).find("testDummy") != std::string::npos){
		matrixMgr->moveEyeInLocalByModeMat(make_float3(5, -10, 5));
	}
	else if (std::string(polyDataPath).find("moortgat") != std::string::npos){
		matrixMgr->moveEyeInLocalByModeMat(make_float3(matrixMgr->getEyeInLocal().x - 10, -20, matrixMgr->getEyeInLocal().z));
	}

	/********GL widget******/
	openGL = std::make_shared<GLWidget>(matrixMgr);
	QSurfaceFormat format;
	format.setDepthBufferSize(24);
	format.setStencilBufferSize(8);
	format.setVersion(2, 0);
	format.setProfile(QSurfaceFormat::CoreProfile);
	openGL->setFormat(format); // must be called before the widget or its parent window gets shown


	//////////////////////////////// Processor ////////////////////////////////
	positionBasedDeformProcessor = std::make_shared<PositionBasedDeformProcessor>(polyMesh, matrixMgr);

	positionBasedDeformProcessor->disThr = disThr;
	positionBasedDeformProcessor->minPos = posMin - make_float3(disThr + 1, disThr + 1, disThr + 1);
	positionBasedDeformProcessor->maxPos = posMax + make_float3(disThr + 1, disThr + 1, disThr + 1);

	openGL->AddProcessor("1positionBasedDeformProcessor", positionBasedDeformProcessor.get());
	positionBasedDeformProcessor->setDeformationScale(2);
	positionBasedDeformProcessor->setDeformationScaleVertical(2.5);
	
	
	if (std::string(polyDataPath).find("testDummy") != std::string::npos){
		positionBasedDeformProcessor->radius = 25;
	}

	//positionBasedDeformProcessor->setShapeModel(SHAPE_MODEL::CIRCLE);
	//////////////////////////////// Renderable ////////////////////////////////	

	//deformFrameRenderable = std::make_shared<DeformFrameRenderable>(matrixMgr, positionBasedDeformProcessor);
	//openGL->AddRenderable("0deform", deformFrameRenderable.get());
	//matrixMgrRenderable = std::make_shared<MatrixMgrRenderable>(matrixMgr);
	//openGL->AddRenderable("3matrix", matrixMgrRenderable.get());

	polyRenderable = std::make_shared<PolyRenderable>(polyMesh);
	polyRenderable->immersiveMode = true;
	openGL->AddRenderable("1poly", polyRenderable.get());


	//////////////////////////////// Interactor ////////////////////////////////
	immersiveInteractor = std::make_shared<ImmersiveInteractor>();
	immersiveInteractor->setMatrixMgr(matrixMgr);
	regularInteractor = std::make_shared<RegularInteractor>();
	regularInteractor->setMatrixMgr(matrixMgrExocentric);
	regularInteractor->isActive = false;
	immersiveInteractor->isActive = true;


	openGL->AddInteractor("1modelImmer", immersiveInteractor.get());
	openGL->AddInteractor("2modelReg", regularInteractor.get());



#ifdef USE_LEAP
	listener = new LeapListener();
	controller = new Leap::Controller();
	controller->setPolicyFlags(Leap::Controller::PolicyFlag::POLICY_OPTIMIZE_HMD);
	controller->addListener(*listener);

	matrixMgrLeapInteractor = std::make_shared<MatrixLeapInteractor>(matrixMgr);
	matrixMgrLeapInteractor->SetActor(openGL.get());
	listener->AddLeapInteractor("matrixMgr", (LeapInteractor*)(matrixMgrLeapInteractor.get()));
#endif


	///********controls******/
	QHBoxLayout *mainLayout = new QHBoxLayout;

	QVBoxLayout *controlLayout = new QVBoxLayout;
	bool fullVersion = true;

	saveStateBtn = std::make_shared<QPushButton>("Save State");
	loadStateBtn = std::make_shared<QPushButton>("Load State");
	if (fullVersion){
		controlLayout->addWidget(saveStateBtn.get());
		controlLayout->addWidget(loadStateBtn.get());
	}

	QCheckBox* isDeformEnabled = new QCheckBox("Enable Deform", this);
	isDeformEnabled->setChecked(positionBasedDeformProcessor->isActive);
	if (fullVersion){
		controlLayout->addWidget(isDeformEnabled);
	}
	connect(isDeformEnabled, SIGNAL(clicked(bool)), this, SLOT(isDeformEnabledClicked(bool)));

	QCheckBox* isForceDeformEnabled = new QCheckBox("Force Deform", this);
	isForceDeformEnabled->setChecked(positionBasedDeformProcessor->isForceDeform);
	if (fullVersion){
		controlLayout->addWidget(isForceDeformEnabled);
	}
	connect(isForceDeformEnabled, SIGNAL(clicked(bool)), this, SLOT(isForceDeformEnabledClicked(bool)));

	QCheckBox* isDeformColoringEnabled = new QCheckBox("Color Deformed Part", this);
	isDeformColoringEnabled->setChecked(positionBasedDeformProcessor->isColoringDeformedPart);
	if (fullVersion){
		controlLayout->addWidget(isDeformColoringEnabled);
	}
	connect(isDeformColoringEnabled, SIGNAL(clicked(bool)), this, SLOT(isDeformColoringEnabledClicked(bool)));



	QGroupBox *eyePosGroup = new QGroupBox(tr("eye position"));
	QHBoxLayout *eyePosLayout = new QHBoxLayout;
	QVBoxLayout *eyePosLayout2 = new QVBoxLayout;
	QLabel *eyePosxLabel = new QLabel("x");
	QLabel *eyePosyLabel = new QLabel("y");
	QLabel *eyePoszLabel = new QLabel("z");
	eyePosLineEdit = new QLineEdit;
	QPushButton *eyePosBtn = new QPushButton("Apply");
	eyePosLayout->addWidget(eyePosxLabel);
	eyePosLayout->addWidget(eyePosyLabel);
	eyePosLayout->addWidget(eyePoszLabel);
	eyePosLayout->addWidget(eyePosLineEdit);
	eyePosLayout2->addLayout(eyePosLayout);
	eyePosLayout2->addWidget(eyePosBtn);
	eyePosGroup->setLayout(eyePosLayout2);
	if (fullVersion){
		controlLayout->addWidget(eyePosGroup);
	}

	QGroupBox *groupBoxORModes = new QGroupBox(tr("occlusion removal modes"));
	QHBoxLayout *orModeLayout = new QHBoxLayout;
	originalRb = std::make_shared<QRadioButton>(tr("&original"));
	deformRb = std::make_shared<QRadioButton>(tr("&deform"));
	clipRb = std::make_shared<QRadioButton>(tr("&clip"));
	transpRb = std::make_shared<QRadioButton>(tr("&transparent"));

	deformRb->setChecked(true);
	orModeLayout->addWidget(originalRb.get());
	orModeLayout->addWidget(deformRb.get());
	orModeLayout->addWidget(clipRb.get());
	orModeLayout->addWidget(transpRb.get());
	groupBoxORModes->setLayout(orModeLayout);
	controlLayout->addWidget(groupBoxORModes);
	connect(originalRb.get(), SIGNAL(clicked(bool)), this, SLOT(SlotOriginalRb(bool)));
	connect(deformRb.get(), SIGNAL(clicked(bool)), this, SLOT(SlotDeformRb(bool)));
	connect(clipRb.get(), SIGNAL(clicked(bool)), this, SLOT(SlotClipRb(bool)));
	connect(transpRb.get(), SIGNAL(clicked(bool)), this, SLOT(SlotTranspRb(bool)));

	QGroupBox *groupBox2 = new QGroupBox(tr("volume selection"));
	QHBoxLayout *deformModeLayout2 = new QHBoxLayout;
	immerRb = std::make_shared<QRadioButton>(tr("&immersive mode"));
	nonImmerRb = std::make_shared<QRadioButton>(tr("&non immer"));
	immerRb->setChecked(true);
	deformModeLayout2->addWidget(immerRb.get());
	deformModeLayout2->addWidget(nonImmerRb.get());
	groupBox2->setLayout(deformModeLayout2);
	if (fullVersion){
		controlLayout->addWidget(groupBox2);
	}
	connect(immerRb.get(), SIGNAL(clicked(bool)), this, SLOT(SlotImmerRb(bool)));
	connect(nonImmerRb.get(), SIGNAL(clicked(bool)), this, SLOT(SlotNonImmerRb(bool)));

	QPushButton *saveScreenBtn = new QPushButton("Save the current screen");
	if (fullVersion){
		controlLayout->addWidget(saveScreenBtn);
	}
	connect(saveScreenBtn, SIGNAL(clicked()), this, SLOT(saveScreenBtnClicked()));


	if (useIsoAdjust){

		QLabel *isoValueSliderLabelLit = new QLabel("Iso Value 1:");
		isoValueSlider = new QSlider(Qt::Horizontal);
		isoValueSlider->setRange(0, 38); //0-0.0038
		isoValueSlider->setValue(round(mc->isoValue0 / 0.0001));
		connect(isoValueSlider, SIGNAL(valueChanged(int)), this, SLOT(isoValueSliderValueChanged(int)));
		isoValueLabel = new QLabel(QString::number(mc->isoValue0));
		QHBoxLayout *isoValueSliderLayout = new QHBoxLayout;
		isoValueSliderLayout->addWidget(isoValueSliderLabelLit);
		isoValueSliderLayout->addWidget(isoValueSlider);
		isoValueSliderLayout->addWidget(isoValueLabel);
		controlLayout->addLayout(isoValueSliderLayout);


		QLabel *isoValueSliderLabelLit1 = new QLabel("Iso Value 2:");
		isoValueSlider1 = new QSlider(Qt::Horizontal);
		isoValueSlider1->setRange(0, 38); //0-0.0038
		isoValueSlider1->setValue(round(mc->isoValue1 / 0.0001));
		connect(isoValueSlider1, SIGNAL(valueChanged(int)), this, SLOT(isoValueSliderValueChanged1(int)));
		isoValueLabel1 = new QLabel(QString::number(mc->isoValue1));
		QHBoxLayout *isoValueSliderLayout1 = new QHBoxLayout;
		isoValueSliderLayout1->addWidget(isoValueSliderLabelLit1);
		isoValueSliderLayout1->addWidget(isoValueSlider1);
		isoValueSliderLayout1->addWidget(isoValueLabel1);
		controlLayout->addLayout(isoValueSliderLayout1);
	}


	QCheckBox* toggleWireframe = new QCheckBox("Toggle Wireframe", this);
	toggleWireframe->setChecked(polyRenderable->useWireFrame);
	if (fullVersion){
		controlLayout->addWidget(toggleWireframe);
	}
	connect(toggleWireframe, SIGNAL(clicked(bool)), this, SLOT(toggleWireframeClicked(bool)));


	controlLayout->addStretch();

	connect(saveStateBtn.get(), SIGNAL(clicked()), this, SLOT(SlotSaveState()));
	connect(loadStateBtn.get(), SIGNAL(clicked()), this, SLOT(SlotLoadState()));
	connect(eyePosBtn, SIGNAL(clicked()), this, SLOT(applyEyePos()));


	mainLayout->addWidget(openGL.get(), 5);
	mainLayout->addLayout(controlLayout, 1);
	setLayout(mainLayout);

	openGL->setFixedSize(600, 600);


#ifdef USE_OSVR
	vrWidget = std::make_shared<VRWidget>(matrixMgr);
	vrWidget->setWindowFlags(Qt::Window);
	vrVolumeRenderable = std::make_shared<VRVolumeRenderableCUDA>(inputVolume);

	vrWidget->AddRenderable("1volume", vrVolumeRenderable.get());

	openGL->SetVRWidget(vrWidget.get());
	vrVolumeRenderable->rcp = rcp;
#endif

}






Window::~Window()
{

}

void Window::init()
{
#ifdef USE_OSVR
	vrWidget->show();
#endif
}

void Window::SlotSaveState()
{
	matrixMgr->SaveState("state.txt");
}

void Window::SlotLoadState()
{
	matrixMgr->LoadState("state.txt");
}

void Window::applyEyePos()
{
	QString s = eyePosLineEdit->text();
	QStringList sl = s.split(QRegExp("[\\s,]+"));
	matrixMgr->moveEyeInLocalByModeMat(make_float3(sl[0].toFloat(), sl[1].toFloat(), sl[2].toFloat()));
}

void Window::isDeformEnabledClicked(bool b)
{
	if (b){
		positionBasedDeformProcessor->isActive = true;
		positionBasedDeformProcessor->reset();
	}
	else{
		positionBasedDeformProcessor->isActive = false;
	}
}

void Window::isForceDeformEnabledClicked(bool b)
{
	if (b){
		positionBasedDeformProcessor->isForceDeform = true;
	}
	else{
		positionBasedDeformProcessor->isForceDeform = false;
	}
}

void Window::isDeformColoringEnabledClicked(bool b)
{
	if (b){
		positionBasedDeformProcessor->isColoringDeformedPart = true;
	}
	else{
		positionBasedDeformProcessor->isColoringDeformedPart = false;
		polyMesh->setVertexDeviateVals();
	}
}

void Window::toggleWireframeClicked(bool b)
{
	polyRenderable->useWireFrame = b;	
}


void Window::SlotOriginalRb()
{
	positionBasedDeformProcessor->deformData = false;
}
void Window::SlotDeformRb()
{
	positionBasedDeformProcessor->deformData = true;
}
void Window::SlotClipRb()
{
}
void Window::SlotTranspRb()
{
}


void Window::SlotImmerRb(bool b)
{
	if (b){
		regularInteractor->isActive = false;
		immersiveInteractor->isActive = true;
		openGL->matrixMgr = matrixMgr;
		//matrixMgr->setDefaultForImmersiveMode();
	}
}

void Window::SlotNonImmerRb(bool b)
{
	if (b)
	{
		regularInteractor->isActive = true;
		immersiveInteractor->isActive = false;
		openGL->matrixMgr = matrixMgrExocentric;
	}
}

void Window::doTourBtnClicked()
{
	//animationByMatrixProcessor->startAnimation();
}

void Window::saveScreenBtnClicked()
{
	openGL->saveCurrentImage();
}


void Window::isoValueSliderValueChanged(int v)
{
	//isoValueSlider->setRange(0, 38); //0-0.0038
	//isoValueSlider->setValue(mc->isoValue / 0.0001);

	float newvalue = v*0.0001;
	if (newvalue < mc->isoValue1){
		mc->isoValue0 = newvalue;
		isoValueLabel->setText(QString::number(mc->isoValue0));
		mc->newIsoValue(v*0.0001, 0);

		polyMesh->setVertexCoordsOri();
		polyMesh->setVertexDeviateVals();

		positionBasedDeformProcessor->polyMeshDataUpdated();
		
	}
	else{
		isoValueSlider->setValue(round(mc->isoValue0 / 0.0001));
	}
}

void Window::isoValueSliderValueChanged1(int v)
{
	//isoValueSlider->setRange(0, 38); //0-0.0038
	//isoValueSlider->setValue(mc->isoValue / 0.0001);

	float newvalue = v*0.0001;
	if (newvalue > mc->isoValue0){
		mc->isoValue1 = newvalue;
		isoValueLabel1->setText(QString::number(mc->isoValue1));
		mc->newIsoValue(v*0.0001, 1);

		polyMesh->setVertexCoordsOri();
		polyMesh->setVertexDeviateVals();

		positionBasedDeformProcessor->polyMeshDataUpdated();
		
	}
	else{
		isoValueSlider1->setValue(round(mc->isoValue1 / 0.0001));
	}
}