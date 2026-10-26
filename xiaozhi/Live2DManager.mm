#import <Foundation/Foundation.h>
#import <MetalKit/MetalKit.h>
#import <ImageIO/ImageIO.h>

// --------------------------------------------------------------------------------
// MARK: - Live2D SDK Headers
// --------------------------------------------------------------------------------
#define CSM_TARGET_METAL
#import <CubismFramework.hpp>
#import <Id/CubismIdManager.hpp> // 使用 GetIdManager
#import <Model/CubismMoc.hpp>
#import <Model/CubismModel.hpp>
#import <ICubismModelSetting.hpp>
#import <CubismModelSettingJson.hpp>
#import <Motion/CubismMotion.hpp>
#import <Motion/CubismMotionQueueManager.hpp>
#import <Physics/CubismPhysics.hpp>
#import <Rendering/Metal/CubismRenderer_Metal.hpp>
#import <Effect/CubismEyeBlink.hpp>
#import <Effect/CubismPose.hpp>
#import <Rendering/Metal/CubismRenderingInstanceSingleton_Metal.h>

using namespace Live2D::Cubism::Framework;
using namespace Live2D::Cubism::Framework::Rendering;

// --------------------------------------------------------------------------------
// MARK: - Global Allocator (防止崩溃)
// --------------------------------------------------------------------------------
class CsmAllocator : public ICubismAllocator {
public:
    void* Allocate(const csmSizeType size) override { return malloc(size); }
    void Deallocate(void* memory) override { free(memory); }
    void* AllocateAligned(const csmSizeType size, const csmUint32 alignment) override {
        void *p = nullptr;
        posix_memalign(&p, alignment, size);
        return p;
    }
    void DeallocateAligned(void* memory) override { free(memory); }
};

static CsmAllocator g_allocator;
static CubismFramework::Option g_option;
static bool g_isLive2DInitialized = false;

// --------------------------------------------------------------------------------
// MARK: - C++ Implementation
// --------------------------------------------------------------------------------
class Live2DManagerImpl : public CubismMotionQueueManager {
public:
    Live2DManagerImpl();
    ~Live2DManagerImpl();
    
    void updateViewMatrix(float width, float height);
    void loadModel(const std::string& modelDirectory, const std::string& modelFileName);
    void onUpdate(float deltaTime);
    void onDraw(float width, float height);
    void onTouchesBegan();
    
    void setMouthOpen(float level);
    void setModelScale(float scale);
    void setLook(float x, float y);
    void playSpecial();

private:
    void releaseModel();
    void startMotion(const char* groupName, int32_t index);
    
    CubismMoc* _moc = nullptr;
    CubismModel* _model = nullptr;
    CubismRenderer_Metal* _renderer = nullptr;
    ICubismModelSetting* _modelSetting = nullptr;
    CubismMatrix44* _viewMatrix = nullptr;
    CubismEyeBlink* _eyeBlink = nullptr;
    CubismPhysics* _physics = nullptr;
    CubismPose* _pose = nullptr;
    std::string _modelDirectory;
    
    float _lipSyncVolume = 0.0f; //存储当前音量 (0.0 ~ 1.0)
    float _modelScale = 1.0f; //单模型缩放 (画布单位大的模型调小)
    float _lookTargetX = 0.0f; //视线目标 (-1 ~ 1)
    float _lookTargetY = 0.0f;
    float _lookX = 0.0f; //当前视线 (每帧向目标平滑靠近)
    float _lookY = 0.0f;
};

void Live2DManagerImpl::setMouthOpen(float level) {
    _lipSyncVolume = level;
}

void Live2DManagerImpl::setModelScale(float scale) {
    _modelScale = scale;
}

void Live2DManagerImpl::setLook(float x, float y) {
    if (x < -1.0f) x = -1.0f;
    if (x > 1.0f) x = 1.0f;
    if (y < -1.0f) y = -1.0f;
    if (y > 1.0f) y = 1.0f;
    _lookTargetX = x;
    _lookTargetY = y;
}

void Live2DManagerImpl::playSpecial() {
    if (!_modelSetting) return;
    int32_t tapCount = _modelSetting->GetMotionCount("TapBody");
    if (tapCount > 1) {
        startMotion("TapBody", tapCount - 1);
    } else {
        int32_t idleCount = _modelSetting->GetMotionCount("Idle");
        if (idleCount > 1) {
            startMotion("Idle", arc4random() % idleCount);
        } else if (tapCount == 1) {
            startMotion("TapBody", 0);
        }
    }
}

Live2DManagerImpl::Live2DManagerImpl() {
    if (!g_isLive2DInitialized) {
        g_option.LogFunction = [](const csmChar* message){ NSLog(@"[Live2D] %s", message); };
        g_option.LoggingLevel = CubismFramework::Option::LogLevel_Verbose;
        CubismFramework::StartUp(&g_allocator, &g_option);
        CubismFramework::Initialize();
        g_isLive2DInitialized = true;
    }
    _viewMatrix = new CubismMatrix44();
}

Live2DManagerImpl::~Live2DManagerImpl() {
    releaseModel();
    delete _viewMatrix;
}

// ✅ 视图矩阵计算 (包含变胖、放大、位置修正)
void Live2DManagerImpl::updateViewMatrix(float screenWidth, float screenHeight) {
    if (screenWidth <= 0 || screenHeight <= 0) return;

    CubismMatrix44 projection;
    projection.LoadIdentity();
    
    // --------------------------------------------------------
    // 🔧 参数配置区域
    // --------------------------------------------------------
    
    // 1. 胖瘦系数
    float fatFactor = 1.0f; // 稍微变胖一点

    // 2. 全局大小
    float globalZoom = 2.3f; // 放大以填满屏幕

    // 3. 上下位置
    float yOffset = -0.1f; // 稍微往下移一点，保证居中

    // --------------------------------------------------------
    
    float screenRatio = screenWidth / screenHeight;
    float scaleX = 1.0f;
    float scaleY = 1.0f;
    
    if (screenWidth < screenHeight) {
        scaleX = 1.0f * fatFactor;
        scaleY = screenRatio;
    } else {
        scaleX = (screenHeight / screenWidth) * fatFactor;
        scaleY = 1.0f;
    }
    
    projection.Scale(scaleX * globalZoom * _modelScale, scaleY * globalZoom * _modelScale);
    projection.Translate(0.0f, yOffset);
    
    _viewMatrix->SetMatrix(projection.GetArray());
}

void Live2DManagerImpl::loadModel(const std::string& modelDirectoryName, const std::string& modelFileName) {
    releaseModel();
    _modelScale = 1.0f; // 默认缩放,Swift 侧随后按模型设置
    _modelDirectory = modelDirectoryName;

    std::string settingPath = _modelDirectory + "/" + modelFileName;
    NSData* settingData = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:settingPath.c_str()]];
    if (!settingData) return;
    
    _modelSetting = new CubismModelSettingJson(reinterpret_cast<const csmByte*>([settingData bytes]), static_cast<csmSizeInt>([settingData length]));
    
    std::string mocFileName = _modelSetting->GetModelFileName();
    NSData* mocData = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:(_modelDirectory + "/" + mocFileName).c_str()]];
    if (!mocData) return;
    
    _moc = CubismMoc::Create(reinterpret_cast<const csmByte*>([mocData bytes]), static_cast<csmSizeInt>([mocData length]));
    _model = _moc->CreateModel();
    
    _renderer = static_cast<CubismRenderer_Metal*>(CubismRenderer::Create());
    _renderer->Initialize(_model);
    
    MTKTextureLoader* loader = [[MTKTextureLoader alloc] initWithDevice:MTLCreateSystemDefaultDevice()];
    for (int i = 0; i < _modelSetting->GetTextureCount(); ++i) {
        std::string texturePath = _modelDirectory + "/" + _modelSetting->GetTextureFileName(i);
        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:texturePath.c_str()]];
        id<MTLTexture> texture = [loader newTextureWithContentsOfURL:url options:nil error:nil];
        if (texture) _renderer->BindTexture(i, texture);
    }
    
    _eyeBlink = CubismEyeBlink::Create(_modelSetting);
    
    const char* physicsFileName = _modelSetting->GetPhysicsFileName();
    if (physicsFileName && strlen(physicsFileName) > 0) {
        std::string path = _modelDirectory + "/" + physicsFileName;
        NSData* data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path.c_str()]];
        if (data) _physics = CubismPhysics::Create(reinterpret_cast<const csmByte*>([data bytes]), static_cast<csmSizeInt>([data length]));
    }
    
    const char* poseFileName = _modelSetting->GetPoseFileName();
    if (poseFileName && strlen(poseFileName) > 0) {
        std::string path = _modelDirectory + "/" + poseFileName;
        NSData* data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path.c_str()]];
        if (data) _pose = CubismPose::Create(reinterpret_cast<const csmByte*>([data bytes]), static_cast<csmSizeInt>([data length]));
    }
    
    _model->SaveParameters();
    startMotion("Idle", 0);
}

void Live2DManagerImpl::onUpdate(float deltaTime) {
    if (!_model) return;
    
    _model->LoadParameters();
    _userTimeSeconds += deltaTime;
    
    DoUpdateMotion(_model, _userTimeSeconds);
    _model->SaveParameters();
    
    if (_eyeBlink) _eyeBlink->UpdateParameters(_model, deltaTime);
    if (_physics) _physics->Evaluate(_model, deltaTime);
    if (_pose) _pose->UpdateParameters(_model, deltaTime);
    
    // ✅ 获取参数ID (现在有了 <Id/CubismIdManager.hpp> 就不会报错了)
    const CubismId* mouthOpenId = CubismFramework::GetIdManager()->GetId("ParamMouthOpenY");
    
    // ✅ 应用口型同步
    _model->AddParameterValue(mouthOpenId, _lipSyncVolume, 0.8f);
    
    // ✅ 视线跟随:向目标平滑靠近,叠加到动作的头/眼参数上 (静止时不影响待机动作)
    float lookSpeed = deltaTime * 10.0f;
    if (lookSpeed > 1.0f) lookSpeed = 1.0f;
    _lookX += (_lookTargetX - _lookX) * lookSpeed;
    _lookY += (_lookTargetY - _lookY) * lookSpeed;
    const CubismId* angleXId = CubismFramework::GetIdManager()->GetId("ParamAngleX");
    const CubismId* angleYId = CubismFramework::GetIdManager()->GetId("ParamAngleY");
    const CubismId* eyeBallXId = CubismFramework::GetIdManager()->GetId("ParamEyeBallX");
    const CubismId* eyeBallYId = CubismFramework::GetIdManager()->GetId("ParamEyeBallY");
    _model->AddParameterValue(angleXId, _lookX * 30.0f, 1.0f);
    _model->AddParameterValue(angleYId, _lookY * 30.0f, 1.0f);
    _model->AddParameterValue(eyeBallXId, _lookX, 1.0f);
    _model->AddParameterValue(eyeBallYId, _lookY, 1.0f);
    
    _model->Update();
    
    if (IsFinished()) {
        startMotion("Idle", 0);
    }
}

void Live2DManagerImpl::onDraw(float screenWidth, float screenHeight) {
    if (!_model || !_renderer) return;
    updateViewMatrix(screenWidth, screenHeight);
    _renderer->SetMvpMatrix(_viewMatrix);
    _renderer->DrawModel();
}

void Live2DManagerImpl::onTouchesBegan() {
    if (_modelSetting->GetMotionCount("TapBody") > 0) {
        startMotion("TapBody", arc4random() % _modelSetting->GetMotionCount("TapBody"));
    }
}

void Live2DManagerImpl::startMotion(const char* groupName, int32_t index) {
    if (_modelSetting->GetMotionCount(groupName) <= index) return;
    const csmChar* fileName = _modelSetting->GetMotionFileName(groupName, index);
    std::string path = _modelDirectory + "/" + fileName;
    NSData* data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path.c_str()]];
    if (data) {
        ACubismMotion* motion = CubismMotion::Create(reinterpret_cast<const csmByte*>([data bytes]), static_cast<csmSizeInt>([data length]));
        StartMotion(motion, true);
    }
}

void Live2DManagerImpl::releaseModel() {
    StopAllMotions();
    CubismEyeBlink::Delete(_eyeBlink); _eyeBlink = nullptr;
    CubismPhysics::Delete(_physics); _physics = nullptr;
    CubismPose::Delete(_pose); _pose = nullptr;
    CubismRenderer::Delete(_renderer); _renderer = nullptr;
    if (_moc) { _moc->DeleteModel(_model); _model = nullptr; }
    CubismMoc::Delete(_moc); _moc = nullptr;
    delete _modelSetting; _modelSetting = nullptr;
}

// --------------------------------------------------------------------------------
// MARK: - ObjC Wrapper
// --------------------------------------------------------------------------------
@interface Live2DManagerObjC : NSObject <MTKViewDelegate>
{
    Live2DManagerImpl* _impl;
    MTKView* _view;
    id<MTLCommandQueue> _commandQueue;
    CFTimeInterval _lastFrameTime;
}
@end

@implementation Live2DManagerObjC

- (instancetype)initWithView:(MTKView *)view {
    self = [super init];
    if (self) {
        _view = view;
        _view.delegate = self;
        _view.device = MTLCreateSystemDefaultDevice();
        if (!_view.device) return nil;

        _view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        _view.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
        _view.sampleCount = 1;
        
        CubismRenderingInstanceSingleton_Metal* singleton = [CubismRenderingInstanceSingleton_Metal sharedManager];
        [singleton setMTLDevice:_view.device];
        [singleton setMetalLayer:(CAMetalLayer*)_view.layer];
        
        _impl = new Live2DManagerImpl();
        _commandQueue = [_view.device newCommandQueue];
        _lastFrameTime = CACurrentMediaTime();
    }
    return self;
}

- (void)dealloc { delete _impl; }
- (void)loadModel:(NSString*)dir modelFileName:(NSString*)file { _impl->loadModel([dir UTF8String], [file UTF8String]); }
- (void)setModelScale:(float)scale { _impl->setModelScale(scale); }
- (void)setLook:(float)x y:(float)y { _impl->setLook(x, y); }
- (void)playSpecial { _impl->playSpecial(); }
- (void)touchesBegan { _impl->onTouchesBegan(); }
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

- (void)drawInMTKView:(MTKView *)view {
    @autoreleasepool {
        if (!view.currentDrawable) return;
    }
    
    CFTimeInterval currentTime = CACurrentMediaTime();
    float deltaTime = (float)(currentTime - _lastFrameTime);
    _lastFrameTime = currentTime;
    
    // 限制最大帧间隔，防止卡顿瞬移，同时保持流畅度
    if (deltaTime > 0.1f) deltaTime = 0.033f;
    
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    if (!commandBuffer) return;
    
    MTLRenderPassDescriptor* renderPassDescriptor = view.currentRenderPassDescriptor;
    if (renderPassDescriptor) {
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        view.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
    } else { return; }
    
    CubismRenderer_Metal::StartFrame(view.device, commandBuffer, renderPassDescriptor);

    _impl->onUpdate(deltaTime);
    
    CGSize size = view.drawableSize;
    _impl->onDraw(size.width, size.height);
    
    [commandBuffer presentDrawable:view.currentDrawable];
    [commandBuffer commit];
}

- (void)setMouthOpen:(float)level {
    if (_impl) {
        _impl->setMouthOpen(level);
    }
}
@end

// --------------------------------------------------------------------------------
// MARK: - Swift Exports
// --------------------------------------------------------------------------------
typedef void* Live2DManagerHandle;
extern "C" {
    Live2DManagerHandle createLive2DManager(void* mtkView) { return (__bridge_retained void*)[[Live2DManagerObjC alloc] initWithView:(__bridge MTKView*)mtkView]; }
    void loadLive2DModel(Live2DManagerHandle handle, const char* d, const char* f) {
        NSString* bp = [[NSBundle mainBundle] bundlePath];
        NSString* fp = [bp stringByAppendingPathComponent:[NSString stringWithUTF8String:d]];
        [(__bridge Live2DManagerObjC*)handle loadModel:fp modelFileName:[NSString stringWithUTF8String:f]];
    }
    void live2DManagerTouchesBegan(Live2DManagerHandle handle) { [(__bridge Live2DManagerObjC*)handle touchesBegan]; }
    void destroyLive2DManager(Live2DManagerHandle handle) { (void)(__bridge_transfer Live2DManagerObjC*)handle; }

    void live2DSetMouthOpen(Live2DManagerHandle handle, float level) {
        [(__bridge Live2DManagerObjC*)handle setMouthOpen:level];
    }
    void live2DSetModelScale(Live2DManagerHandle handle, float scale) {
        [(__bridge Live2DManagerObjC*)handle setModelScale:scale];
    }
    void live2DSetLook(Live2DManagerHandle handle, float x, float y) {
        [(__bridge Live2DManagerObjC*)handle setLook:x y:y];
    }
    void live2DPlaySpecial(Live2DManagerHandle handle) {
        [(__bridge Live2DManagerObjC*)handle playSpecial];
    }
}
