# MacQ

[English](README.md) | [简体中文](README.zh-CN.md)

macOS 小工具集——把常用工具装进一个菜单栏常驻的 App。

## 功能

- **魔法鼠标** — 物理滚轮平滑滚动、速度调节、方向翻转（不影响触摸板）。
- **魔法剪贴板** — 剪贴板历史、搜索、类型筛选，Spotlight 式浮层选中即粘贴。
- **魔法右键** — 访达右键菜单：复制路径、进入终端、新建文件（自动进入重命名）。
- **截图** — 区域/窗口截图、标注（矩形/箭头/画笔/文字/马赛克）、离线 OCR、滚动长截图。
- **开发者工具箱** — JSON 美化、Base64、URL 编解码、时间戳、UUID、Hash、二维码（生成+解析）、取色器、随机密码。
- 菜单栏图标、深浅色主题、中英文界面、开机自启动。

## 环境要求

- macOS 14.0+
- Xcode + [xcodegen](https://github.com/yonaskolb/XcodeGen)（源码构建需要）

部分工具需要系统权限（辅助功能、输入监控、屏幕录制），首次使用时 MacQ 会引导授权。

## 构建运行

```bash
# 构建（Debug）并启动 —— 日常开发用这个
./Scripts/run.sh
```

## 打包

```bash
# 构建 Release 并产出 dist/MacQ-<版本>.dmg
./Scripts/package.sh          # 不传版本则读工程版本
./Scripts/package.sh 0.3.0    # 或显式指定
```
