#include <window.h>
#include <iostream>

#include "GLWidget.h"
#include "Volume.h"
#include "RawVolumeReader.h"
#include "DataMgr.h"
#include "VecReader.h"
#include "GLMatrixManager.h"
#include "ScreenMarker.h"
#include "LabelVolumeProcessor.h"
#include "VolumeRenderableCUDA.h"
#include "VolumeRenderableCUDAShader.h"
#include "VolumeRenderableImmerCUDA.h"
#include "mouse/RegularInteractor.h"
#include "mouse/ImmersiveInteractor.h"
#include "mouse/ScreenBrushInteractor.h"
#include "LabelVolumeProcessor.h"
#include "ViewpointEvaluator.h"
#include "GLWidgetQtDrawing.h"
#include "AnimationByMatrixProcessor.h"
#include "SphereRenderable.h"
#include "Particle.h"

#include "PositionBasedDeformProcessor.h"
#include "MatrixMgrRenderable.h"

#ifdef USE_OSVR
#include "VRWidget.h"
#include "VRVolumeRenderableCUDA.h"
#endif


//note!!! this function also happens in the ITKProcessing program. remember to change both if needed
void computeChannelVolume(std::shared_ptr<Volume> v, std::shared_ptr<Volume> channelV, std::shared_ptr<RayCastingParameters> rcp)
{
	std::cout << "computing channel volume..." << std::endl;

	int3 dataSizes = v->size;

	for (int k = 0; k < dataSizes.z; k++)
	{
		for (int j = 0; j < dataSizes.y; j++)
		{
			for (int i = 0; i < dataSizes.x; i++)
			{
				int ind = k*dataSizes.y * dataSizes.x + j*dataSizes.x + i;
				if (v->values[ind] < rcp->transFuncP2){
					channelV->values[ind] = 1;
				}
				else{
					channelV->values[ind] = 0;
				}
			}
		}
	}
	channelV->initVolumeCuda();
	std::cout << "finish computing channel volume..." << std::endl;
	return;
}

Window::Window()
{
	setWindowTitle(tr("Interactive Glyph Visualization"));

	////////////////data
	std::shared_ptr<DataMgr> dataMgr;
	dataMgr = std::make_shared<DataMgr>();
	const std::string dataPath = dataMgr->GetConfig("VOLUME_DATA_PATH");

	std::shared_ptr<RayCastingParameters> rcp = std::make_shared<RayCastingParameters>();

	if (std::string(dataPath).find("MGHT2") != std::string::npos){
		dims = make_int3(320, 320, 256);
		spacing = make_float3(0.7, 0.7, 0.7);
	}
	else if (std::string(dataPath).find("MGHT1") != std::string::npos){
		dims = make_int3(256, 256, 176);
		spacing = make_float3(1.0, 1.0, 1.0);
		rcp = std::make_shared<RayCastingParameters>(1.0, 0.2, 0.7, 0.44, 0.29, 1.25, 512, 0.25f, 1.3, false);
	}
	else if (std::string(dataPath).find("nek128") != std::string::npos){
		dims = make_int3(128, 128, 128);
		spacing = make_float3(2, 2, 2); //to fit the streamline of nek256
	}
	else if (std::string(dataPath).find("nek256") != std::string::npos){
		dims = make_int3(256, 256, 256);
		spacing = make_float3(1, 1, 1);
	}
	else if (std::string(dataPath).find("cthead") != std::string::npos){
		dims = make_int3(208, 256, 225);
		spacing = make_float3(1, 1, 1);
	}
	else if (std::string(dataPath).find("brat") != std::string::npos){
		dims = make_int3(160, 216, 176);
		spacing = make_float3(1, 1, 1);
		rcp = std::make_shared<RayCastingParameters>(1.0, 0.2, 0.7, 0.44, 0.25, 1.25, 512, 0.25f, 1.3, false); //for brat
	}
	else if (std::string(dataPath).find("engine") != std::string::npos){
		dims = make_int3(149, 208, 110);
		spacing = make_float3(1, 1, 1);
		rcp = std::make_shared<RayCastingParameters>(0.8, 0.4, 1.2, 1.0, 0.05, 1.25, 512, 0.25f, 1.0, false);
	}
	else if (std::string(dataPath).find("knee") != std::string::npos){
		dims = make_int3(379, 229, 305);
		spacing = make_float3(1, 1, 1);
	}
	else if (std::string(dataPath).find("181") != std::string::npos){
		dims = make_int3(181, 217, 181);
		spacing = make_float3(1, 1, 1);
		rcp = std::make_shared<RayCastingParameters>(1.8, 1.0, 1.5, 1.0, 0.3, 2.6, 512, 0.25f, 1.0, false); //for 181
	}
	else{
		std::cout << "volume data name not recognized" << std::endl;
		exit(0);
	}

	inputVolume = std::make_shared<Volume>(true);
	if (std::string(dataPath).find(".vec") != std::string::npos){
		std::shared_ptr<VecReader> reader;
		reader = std::make_shared<VecReader>(dataPath.c_str());
		reader->OutputToVolumeByNormalizedVecMag(inputVolume);
		//reader->OutputToVolumeByNormalizedVecDownSample(inputVolume,2);
		//reader->OutputToVolumeByNormalizedVecUpSample(inputVolume, 2);
		//reader->OutputToVolumeByNormalizedVecMagWithPadding(inputVolume,10);
		reader.reset();
	}
	else{
		std::shared_ptr<RawVolumeReader> reader;
		if (std::string(dataPath).find("engine") != std::string::npos || std::string(dataPath).find("knee") != std::string::npos || std::string(dataPath).find("181") != std::string::npos){
			reader = std::make_shared<RawVolumeReader>(dataPath.c_str(), dims, RawVolumeReader::dtUint8);
		}
		else{
			reader = std::make_shared<RawVolumeReader>(dataPath.c_str(), dims);
		}
		reader->OutputToVolumeByNormalizedValue(inputVolume);
		reader.reset();
	}
	inputVolume->spacing = spacing;
	inputVolume->initVolumeCuda();

	bool useChannelAndSkel = true;
	if (useChannelAndSkel){
		channelVolume = std::make_shared<Volume>();
		channelVolume->setSize(inputVolume->size);
		channelVolume->dataOrigin = inputVolume->dataOrigin;
		channelVolume->spacing = inputVolume->spacing;
		computeChannelVolume(inputVolume, channelVolume, rcp);
		
		skelVolume = std::make_shared<Volume>();
		std::shared_ptr<RawVolumeReader> reader;
		reader = std::make_shared<RawVolumeReader>("skel.raw", dims, RawVolumeReader::dtFloat32);
		reader->OutputToVolumeByNormalizedValue(skelVolume);
		skelVolume->initVolumeCuda();
		reader.reset();
	}


	////////////////matrix
	matrixMgr = std::make_shared<GLMatrixManager>();
	matrixMgrMini = std::make_shared<GLMatrixManager>();

	float3 posMin, posMax;
	inputVolume->GetPosRange(posMin, posMax);
	matrixMgr->SetVol(posMin, posMax);
	matrixMgr->setDefaultForImmersiveMode();
	
	matrixMgrMini->SetVol(posMin, posMax);
	
	////////////////processor
	positionBasedDeformProcessor = std::make_shared<PositionBasedDeformProcessor>(inputVolume, matrixMgr, channelVolume);
	
	animationByMatrixProcessor = std::make_shared<AnimationByMatrixProcessor>(matrixMgr);
	animationByMatrixProcessor->isActive = false;
	animationByMatrixProcessor->setViews(views);

	std::shared_ptr<ScreenMarker> sm = std::make_shared<ScreenMarker>();

	ve = std::make_shared<ViewpointEvaluator>(rcp, inputVolume);
	ve->initDownSampledResultVolume(make_int3(40, 40, 40));

	useLabel = true;
	labelVolCUDA = 0;
	if (useLabel){
		//std::shared_ptr<RawVolumeReader> reader;
		//const std::string labelDataPath = dataMgr->GetConfig("FEATURE_PATH");
		//reader = std::make_shared<RawVolumeReader>(labelDataPath.c_str(), dims);
		//labelVolCUDA = std::make_shared<VolumeCUDA>();
		//reader->OutputToVolumeCUDAUnsignedShort(labelVolCUDA);
		//reader.reset();

		labelVolCUDA = std::make_shared<VolumeCUDA>();
		labelVolCUDA->VolumeCUDA_init(dims, (unsigned short *)0, 1, 1);

		lvProcessor = std::make_shared<LabelVolumeProcessor>(labelVolCUDA);
		lvProcessor->setScreenMarker(sm);
		lvProcessor->rcp = rcp;

		ve->setLabel(labelVolCUDA);

		labelVolLocal = new unsigned short[dims.x*dims.y*dims.z];
		memset(labelVolLocal, 0, sizeof(unsigned short)*dims.x*dims.y*dims.z);
	}



	/********GL widget******/
	openGL = std::make_shared<GLWidget>(matrixMgr);
	QSurfaceFormat format;
	format.setDepthBufferSize(24);
	format.setStencilBufferSize(8);
	format.setVersion(2, 0);
	format.setProfile(QSurfaceFormat::CoreProfile);
	openGL->setFormat(format); // must be called before the widget or its parent window gets shown

	
	volumeRenderable = std::make_shared<VolumeRenderableImmerCUDA>(inputVolume, labelVolCUDA);
	volumeRenderable->rcp = rcp;
	openGL->AddRenderable("1volume", volumeRenderable.get());
	volumeRenderable->setScreenMarker(sm);

	matrixMgrRenderable = std::make_shared<MatrixMgrRenderable>(matrixMgr);
	openGL->AddRenderable("2volume", matrixMgrRenderable.get()); 



	immersiveInteractor = std::make_shared<ImmersiveInteractor>();
	immersiveInteractor->setMatrixMgr(matrixMgr);
	regularInteractor = std::make_shared<RegularInteractor>();
	regularInteractor->setMatrixMgr(matrixMgrMini);
	regularInteractor->isActive = false;
	immersiveInteractor->isActive = true;
	openGL->AddInteractor("1modelImmer", immersiveInteractor.get());
	openGL->AddInteractor("2modelReg", regularInteractor.get());


	sbInteractor = std::make_shared<ScreenBrushInteractor>();
	sbInteractor->setScreenMarker(sm);
	openGL->AddInteractor("screenMarker", sbInteractor.get());

	//openGL->AddProcessor("animationByMatrixProcessor", animationByMatrixProcessor.get());
	if (useLabel){
		//openGL->AddProcessor("screenMarkerVolumeProcessor", lvProcessor.get());
	}

	openGL->AddProcessor("1positionBasedDeformProcessor", positionBasedDeformProcessor.get());

	///********controls******/
	QHBoxLayout *mainLayout = new QHBoxLayout;
	
	QVBoxLayout *controlLayout = new QVBoxLayout;
	
	saveStateBtn = std::make_shared<QPushButton>("Save State");
	loadStateBtn = std::make_shared<QPushButton>("Load State");
	std::cout << posMin.x << " " << posMin.y << " " << posMin.z << std::endl;
	std::cout << posMax.x << " " << posMax.y << " " << posMax.z << std::endl;
	controlLayout->addWidget(saveStateBtn.get());
	controlLayout->addWidget(loadStateBtn.get());

	QCheckBox* isBrushingCb = new QCheckBox("Brush", this);
	isBrushingCb->setChecked(sbInteractor->isActive);
	controlLayout->addWidget(isBrushingCb);
	connect(isBrushingCb, SIGNAL(clicked()), this, SLOT(isBrushingClicked()));

	QPushButton *moveToOptimalBtn = new QPushButton("Move to the Optimal Viewpoint");
	controlLayout->addWidget(moveToOptimalBtn);
	connect(moveToOptimalBtn, SIGNAL(clicked()), this, SLOT(moveToOptimalBtnClicked()));

	QPushButton *doTourBtn = new QPushButton("Do the Animation Tour");
	controlLayout->addWidget(doTourBtn);
	connect(doTourBtn, SIGNAL(clicked()), this, SLOT(doTourBtnClicked()));

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
	controlLayout->addWidget(eyePosGroup);

	QGroupBox *groupBox = new QGroupBox(tr("volume selection"));
	QVBoxLayout *deformModeLayout = new QVBoxLayout;
	oriVolumeRb = std::make_shared<QRadioButton>(tr("&original volume"));
	channelVolumeRb = std::make_shared<QRadioButton>(tr("&channel volume"));
	skelVolumeRb = std::make_shared<QRadioButton>(tr("&skeleton volume"));
	oriVolumeRb->setChecked(true);
	deformModeLayout->addWidget(oriVolumeRb.get());
	deformModeLayout->addWidget(channelVolumeRb.get());
	deformModeLayout->addWidget(skelVolumeRb.get());
	groupBox->setLayout(deformModeLayout);
	controlLayout->addWidget(groupBox);
	connect(oriVolumeRb.get(), SIGNAL(clicked(bool)), this, SLOT(SlotOriVolumeRb(bool)));
	connect(channelVolumeRb.get(), SIGNAL(clicked(bool)), this, SLOT(SlotChannelVolumeRb(bool)));
	connect(skelVolumeRb.get(), SIGNAL(clicked(bool)), this, SLOT(SlotSkelVolumeRb(bool)));

	QGroupBox *groupBox2 = new QGroupBox(tr("volume selection"));
	QHBoxLayout *deformModeLayout2 = new QHBoxLayout;
	immerRb = std::make_shared<QRadioButton>(tr("&immersive mode"));
	nonImmerRb = std::make_shared<QRadioButton>(tr("&non immer"));
	immerRb->setChecked(true);
	deformModeLayout2->addWidget(immerRb.get());
	deformModeLayout2->addWidget(nonImmerRb.get());
	groupBox2->setLayout(deformModeLayout2);
	controlLayout->addWidget(groupBox2);
	connect(immerRb.get(), SIGNAL(clicked(bool)), this, SLOT(SlotImmerRb(bool)));
	connect(nonImmerRb.get(), SIGNAL(clicked(bool)), this, SLOT(SlotNonImmerRb(bool)));

	QLabel *transFuncP1SliderLabelLit = new QLabel("Transfer Function Higher Cut Off");
	//controlLayout->addWidget(transFuncP1SliderLabelLit);
	QSlider *transFuncP1LabelSlider = new QSlider(Qt::Horizontal);
	transFuncP1LabelSlider->setRange(0, 100);
	transFuncP1LabelSlider->setValue(volumeRenderable->rcp->transFuncP1 * 100);
	connect(transFuncP1LabelSlider, SIGNAL(valueChanged(int)), this, SLOT(transFuncP1LabelSliderValueChanged(int)));
	transFuncP1Label = new QLabel(QString::number(volumeRenderable->rcp->transFuncP1));
	QHBoxLayout *transFuncP1Layout = new QHBoxLayout;
	transFuncP1Layout->addWidget(transFuncP1LabelSlider);
	transFuncP1Layout->addWidget(transFuncP1Label);
	//controlLayout->addLayout(transFuncP1Layout);

	QLabel *transFuncP2SliderLabelLit = new QLabel("Transfer Function Lower Cut Off");
	//controlLayout->addWidget(transFuncP2SliderLabelLit);
	QSlider *transFuncP2LabelSlider = new QSlider(Qt::Horizontal);
	transFuncP2LabelSlider->setRange(0, 100);
	transFuncP2LabelSlider->setValue(volumeRenderable->rcp->transFuncP2 * 100);
	connect(transFuncP2LabelSlider, SIGNAL(valueChanged(int)), this, SLOT(transFuncP2LabelSliderValueChanged(int)));
	transFuncP2Label = new QLabel(QString::number(volumeRenderable->rcp->transFuncP2));
	QHBoxLayout *transFuncP2Layout = new QHBoxLayout;
	transFuncP2Layout->addWidget(transFuncP2LabelSlider);
	transFuncP2Layout->addWidget(transFuncP2Label);
	//controlLayout->addLayout(transFuncP2Layout);

	QLabel *brLabelLit = new QLabel("Brightness of the volume: ");
	//controlLayout->addWidget(brLabelLit);
	QSlider* brSlider = new QSlider(Qt::Horizontal);
	brSlider->setRange(0, 40);
	brSlider->setValue(volumeRenderable->rcp->brightness * 20);
	connect(brSlider, SIGNAL(valueChanged(int)), this, SLOT(brSliderValueChanged(int)));
	brLabel = new QLabel(QString::number(volumeRenderable->rcp->brightness));
	QHBoxLayout *brLayout = new QHBoxLayout;
	brLayout->addWidget(brSlider);
	brLayout->addWidget(brLabel);
	//controlLayout->addLayout(brLayout);

	QLabel *dsLabelLit = new QLabel("Density of the volume: ");
	//controlLayout->addWidget(dsLabelLit);
	QSlider* dsSlider = new QSlider(Qt::Horizontal);
	dsSlider->setRange(0, 100);
	dsSlider->setValue(volumeRenderable->rcp->density * 20);
	connect(dsSlider, SIGNAL(valueChanged(int)), this, SLOT(dsSliderValueChanged(int)));
	dsLabel = new QLabel(QString::number(volumeRenderable->rcp->density));
	QHBoxLayout *dsLayout = new QHBoxLayout;
	dsLayout->addWidget(dsSlider);
	dsLayout->addWidget(dsLabel);
	//controlLayout->addLayout(dsLayout);

	QLabel *laSliderLabelLit = new QLabel("Coefficient for Ambient Lighting: ");
	//controlLayout->addWidget(laSliderLabelLit);
	QSlider* laSlider = new QSlider(Qt::Horizontal);
	laSlider->setRange(0, 50);
	laSlider->setValue(volumeRenderable->rcp->la * 10);
	connect(laSlider, SIGNAL(valueChanged(int)), this, SLOT(laSliderValueChanged(int)));
	laLabel = new QLabel(QString::number(volumeRenderable->rcp->la));
	QHBoxLayout *laLayout = new QHBoxLayout;
	laLayout->addWidget(laSlider);
	laLayout->addWidget(laLabel);
	//controlLayout->addLayout(laLayout);

	QLabel *ldSliderLabelLit = new QLabel("Coefficient for Diffusial Lighting: ");
	//controlLayout->addWidget(ldSliderLabelLit);
	QSlider* ldSlider = new QSlider(Qt::Horizontal);
	ldSlider->setRange(0, 50);
	ldSlider->setValue(volumeRenderable->rcp->ld * 10);
	connect(ldSlider, SIGNAL(valueChanged(int)), this, SLOT(ldSliderValueChanged(int)));
	ldLabel = new QLabel(QString::number(volumeRenderable->rcp->ld));
	QHBoxLayout *ldLayout = new QHBoxLayout;
	ldLayout->addWidget(ldSlider);
	ldLayout->addWidget(ldLabel);
	//controlLayout->addLayout(ldLayout);

	QLabel *lsSliderLabelLit = new QLabel("Coefficient for Specular Lighting: ");
	//controlLayout->addWidget(lsSliderLabelLit);
	QSlider* lsSlider = new QSlider(Qt::Horizontal);
	lsSlider->setRange(0, 50);
	lsSlider->setValue(volumeRenderable->rcp->ls * 10);
	connect(lsSlider, SIGNAL(valueChanged(int)), this, SLOT(lsSliderValueChanged(int)));
	lsLabel = new QLabel(QString::number(volumeRenderable->rcp->ls));
	QHBoxLayout *lsLayout = new QHBoxLayout;
	lsLayout->addWidget(lsSlider);
	lsLayout->addWidget(lsLabel);
	//controlLayout->addLayout(lsLayout);

	QGroupBox *rcGroupBox = new QGroupBox(tr("Ray Casting setting"));
	QVBoxLayout *rcLayout = new QVBoxLayout;
	rcLayout->addWidget(transFuncP1SliderLabelLit);
	rcLayout->addLayout(transFuncP1Layout);
	rcLayout->addWidget(transFuncP2SliderLabelLit);
	rcLayout->addLayout(transFuncP2Layout);
	rcLayout->addWidget(brLabelLit);
	rcLayout->addLayout(brLayout);
	rcLayout->addWidget(dsLabelLit);
	rcLayout->addLayout(dsLayout);
	rcLayout->addWidget(laSliderLabelLit);
	rcLayout->addLayout(laLayout);
	rcLayout->addWidget(ldSliderLabelLit);
	rcLayout->addLayout(ldLayout);
	rcLayout->addWidget(lsSliderLabelLit);
	rcLayout->addLayout(lsLayout);
	rcGroupBox->setLayout(rcLayout);

	//controlLayout->addWidget(rcGroupBox);

	controlLayout->addStretch();

	connect(saveStateBtn.get(), SIGNAL(clicked()), this, SLOT(SlotSaveState()));
	connect(loadStateBtn.get(), SIGNAL(clicked()), this, SLOT(SlotLoadState()));
	connect(eyePosBtn, SIGNAL(clicked()), this, SLOT(applyEyePos()));



	//////////////////////////miniature
	QVBoxLayout *assistLayout = new QVBoxLayout;
	QLabel *miniatureLabel = new QLabel("miniature");
	//assistLayout->addWidget(miniatureLabel);

	openGLMini = std::make_shared<GLWidget>(matrixMgrMini);

	QSurfaceFormat format2;
	format2.setDepthBufferSize(24);
	format2.setStencilBufferSize(8);
	format2.setVersion(2, 0);
	format2.setProfile(QSurfaceFormat::CoreProfile);
	openGLMini->setFormat(format2);

	std::vector<float4> pos;
	pos.push_back(make_float4(matrixMgr->getEyeInLocal(), 1.0));
	std::vector<float> val;
	val.push_back(1.0);
	std::shared_ptr<Particle> particle = std::make_shared<Particle>(pos, val);
	particle->initForRendering(200, 1);
	sphereRenderableMini = std::make_shared<SphereRenderable>(particle);
	openGLMini->AddRenderable("1center", sphereRenderableMini.get());


	volumeRenderableMini = std::make_shared<VolumeRenderableCUDA>(inputVolume);
	volumeRenderableMini->rcp = std::make_shared<RayCastingParameters>(0.8, 2.0, 2.0, 0.9, 0.1, 0.05, 512, 0.25f, 0.6, false);
	volumeRenderableMini->setBlending(true, 50);
	openGLMini->AddRenderable("2volume", volumeRenderableMini.get());
	regularInteractorMini = std::make_shared<RegularInteractor>();
	regularInteractorMini->setMatrixMgr(matrixMgrMini);
	openGLMini->AddInteractor("regular", regularInteractorMini.get());

	assistLayout->addWidget(openGLMini.get(), 3);

	helper.setData(inputVolume, labelVolLocal);
	GLWidgetQtDrawing *openGL2D = new GLWidgetQtDrawing(&helper, this);
	assistLayout->addWidget(openGL2D, 0);
	QTimer *timer = new QTimer(this);
	connect(timer, &QTimer::timeout, openGL2D, &GLWidgetQtDrawing::animate);
	timer->start(5);

	QSlider *zSlider = new QSlider(Qt::Horizontal);
	zSlider->setRange(0, inputVolume->size.z);
	zSlider->setValue(helper.z);
	connect(zSlider, SIGNAL(valueChanged(int)), this, SLOT(zSliderValueChanged(int)));
	assistLayout->addWidget(zSlider, 0);

	QPushButton *redrawBtn = new QPushButton("Redraw the Label");
	assistLayout->addWidget(redrawBtn);
	connect(redrawBtn, SIGNAL(clicked()), this, SLOT(redrawBtnClicked()));

	QPushButton *updateLabelVolBtn = new QPushButton("Update Label Volume");
	assistLayout->addWidget(updateLabelVolBtn);
	connect(updateLabelVolBtn, SIGNAL(clicked()), this, SLOT(updateLabelVolBtnClicked()));

	mainLayout->addLayout(assistLayout, 1);
	//openGL->setFixedSize(600, 600);
	mainLayout->addWidget(openGL.get(), 5);
	mainLayout->addLayout(controlLayout, 1);
	setLayout(mainLayout);


#ifdef USE_OSVR
	vrWidget = std::make_shared<VRWidget>(matrixMgr);
	vrWidget->setWindowFlags(Qt::Window);
	vrVolumeRenderable = std::make_shared<VRVolumeRenderableCUDA>(inputVolume);
	vrWidget->AddRenderable("volume", vrVolumeRenderable.get());
	openGL->SetVRWidget(vrWidget.get());
	vrVolumeRenderable->rcp = volumeRenderable->rcp;
#endif

}






Window::~Window()
{
	if (labelVolLocal)
		delete[]labelVolLocal;
}

void Window::init()
{
#ifdef USE_OSVR
	vrWidget->show();
#endif
}

void Window::SlotSaveState()
{
}

void Window::SlotLoadState()
{
}

void Window::applyEyePos()
{
	QString s = eyePosLineEdit->text();
	QStringList sl = s.split(QRegExp("[\\s,]+"));
	matrixMgr->moveEyeInLocalTo(make_float3(sl[0].toFloat(), sl[1].toFloat(), sl[2].toFloat()));
}

void Window::transFuncP1LabelSliderValueChanged(int v)
{
	volumeRenderable->rcp->transFuncP1 = 1.0*v / 100;
	transFuncP1Label->setText(QString::number(1.0*v / 100));
}
void Window::transFuncP2LabelSliderValueChanged(int v)
{
	volumeRenderable->rcp->transFuncP2 = 1.0*v / 100;
	transFuncP2Label->setText(QString::number(1.0*v / 100));
}

void Window::brSliderValueChanged(int v)
{
	volumeRenderable->rcp->brightness = v*1.0 / 20.0;
	brLabel->setText(QString::number(volumeRenderable->rcp->brightness));
}
void Window::dsSliderValueChanged(int v)
{
	volumeRenderable->rcp->density = v*1.0 / 20.0;
	dsLabel->setText(QString::number(volumeRenderable->rcp->density));
}

void Window::laSliderValueChanged(int v)
{
	volumeRenderable->rcp->la = 1.0*v / 10;
	laLabel->setText(QString::number(1.0*v / 10));

}
void Window::ldSliderValueChanged(int v)
{
	volumeRenderable->rcp->ld = 1.0*v / 10;
	ldLabel->setText(QString::number(1.0*v / 10));
}
void Window::lsSliderValueChanged(int v)
{
	volumeRenderable->rcp->ls = 1.0*v / 10;
	lsLabel->setText(QString::number(1.0*v / 10));
}

void Window::isBrushingClicked()
{
	sbInteractor->isActive = !sbInteractor->isActive;
}

void Window::moveToOptimalBtnClicked()
{
	ve->compute(VPMethod::JS06Sphere);

	matrixMgr->moveEyeInLocalTo(make_float3(ve->optimalEyeInLocal.x, ve->optimalEyeInLocal.y, ve->optimalEyeInLocal.z));

	ve->saveResultVol("labelEntro.raw");
}

void Window::SlotOriVolumeRb(bool b)
{
	if (b)
		volumeRenderable->setVolume(inputVolume);
}

void Window::SlotChannelVolumeRb(bool b)
{
	if (b)
	{
		if (channelVolume){
			volumeRenderable->setVolume(channelVolume);
		}
		else{
			std::cout << "channelVolume not set!!" << std::endl;
			oriVolumeRb->setChecked(true);
			SlotOriVolumeRb(true);
		}
	}
}

void Window::SlotSkelVolumeRb(bool b)
{
	if (b)
	{
		if (skelVolume){
			volumeRenderable->setVolume(skelVolume);
		}
		else{
			std::cout << "skelVolume not set!!" << std::endl;
			oriVolumeRb->setChecked(true);
			SlotOriVolumeRb(true);
		}
	}
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
		openGL->matrixMgr = matrixMgrMini;
	}
}

void Window::zSliderValueChanged(int v)
{
	helper.z = v;
}

void Window::updateLabelVolBtnClicked()
{
	labelVolCUDA->VolumeCUDA_contentUpdate(labelVolLocal, 1, 1);
	std::cout << std::endl << "The lable volume has been updated" << std::endl << std::endl;
}

void Window::redrawBtnClicked()
{
	if (labelVolLocal){
		memset(labelVolLocal, 0, sizeof(unsigned short)*dims.x*dims.y*dims.z);
		labelVolCUDA->VolumeCUDA_contentUpdate(labelVolLocal, 1, 1);
	}
	helper.valSet = false;
}

void Window::doTourBtnClicked()
{
	animationByMatrixProcessor->startAnimation();
}