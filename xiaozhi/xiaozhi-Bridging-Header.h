// 文件: xiaozhi-Bridging-Header.h

#ifndef xiaozhi_Bridging_Header_h
#define xiaozhi_Bridging_Header_h

// 这个头文件是为了让 Swift 能够调用 Objective-C/C++ 代码

// 定义一个不透明指针类型，让 Swift 知道 Live2DManagerHandle 是什么
typedef void* Live2DManagerHandle;

// 声明我们将要从 Swift 调用的 C 函数
// 这些函数的实现在 Live2DManager.mm 的 extern "C" 块中
Live2DManagerHandle createLive2DManager(void* mtkView);
void loadLive2DModel(Live2DManagerHandle handle, const char* modelDir, const char* modelFile);
void live2DManagerTouchesBegan(Live2DManagerHandle handle);
void destroyLive2DManager(Live2DManagerHandle handle);
void live2DSetMouthOpen(Live2DManagerHandle handle, float level);
void live2DSetModelScale(Live2DManagerHandle handle, float scale);

#endif /* xiaozhi_Bridging_Header_h */
