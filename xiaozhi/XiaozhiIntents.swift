// 文件: XiaozhiIntents.swift（Build 1 过渡占位）
//
// CallKit 已整段移除（后台语音通话新方向），旧的 StartXiaozhiCallIntent /
// XiaoZhiShortcuts 随之删除。三个新 intent（StartCallIntent / EndCallIntent /
// CallStatusIntent）+ 新的 XiaoZhiShortcuts 在 Build 2 写入。
// Build 1 期间 Siri / 快捷指令入口暂时缺失，属预期行为。

import AppIntents
