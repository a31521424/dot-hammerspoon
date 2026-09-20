# Hammerspoon macOS 生产力外设与自动化套件

一套基于 [Hammerspoon](https://www.hammerspoon.org/) 构建的 macOS 极客级生产力自动化套件。集成了**蓝牙硬件遥控器驱动与控制中心**、**豆包流式实时语音输入**以及**垂直 Alt-Tab 窗口切换器**三大核心模块，旨在将 Mac 桌面拓展为支持远场操控、AI Agent 协同与高频键盘流的多模态开发工作台。

---

## 🌟 核心特性

### 1. 🎮 硬件级蓝牙遥控器控制中心 (`modules/remote_control`)
- **硬件级隔离与监听**：通过 Swift 原生编写的 `IOHIDManager` 守护进程，直接通过 Vendor ID / Product ID 精准捕获外设物理报文，彻底摆脱系统层按键吞咽。
- **Mac 自带键盘绝对免疫**：通过 macOS `hidutil` 将遥控器物理按键重定向至隔离虚拟键区，全局 `eventtap` 绝不污染自带键盘的任何原生按键（如 F1~F12、退格、回车等）。
- **多场景 Per-App Profile 动态路由**：
  - **终端开发模式 (Termux / iTerm / Ghostty)**：专为命令行与 AI Coding Agent 设计，支持一键发送 `y`+回车确认、Ctrl+C 终止、tmux 窗口秒切、服务热重启。
  - **浏览器调试模式 (Chrome / Safari / Arc)**：支持标签页左右穿梭、网页硬刷新、DevTools 开发者工具一键开关。
  - **全局通用模式**：终端 ↔ 浏览器无缝穿梭、垂直 Alt-Tab 唤起、平滑音量调节、显示器即时熄屏。
- **鼠标指针模式 (Mouse Mode)**：支持通过遥控器方向环按键平滑移动鼠标光标，短按 OK 执行鼠标左键单击，短按返回键执行右键菜单。
- **可视化控制面板 (Dashboard)**：按下快捷键 `⌥ + ⇧ + R` 或长按遥控器 TV 键唤出 WebKit 控制面板，顶部全局常驻**实时按键捕捉监视器**（带按键高亮动效），支持图形化配置热更与外设扫描。

### 2. 🎤 豆包流式实时语音输入 (`modules/voice_input`)
- **Hold-to-Talk 交互**：按下物理按键即时开启音频流采集，松开按键瞬间完成文本上屏，无感对齐光标。
- **双模型协同加速**：
  - 首选火山引擎豆包实时语音大模型 (SeedASR) WebSocket 双向流式转写；
  - 辅以本地守护进程与 Flash 极速校验，端到端延迟低至毫秒级。
- **热词与文本替换支持**：支持配置发音纠错（Hotwords）与专业术语缩写自动替换。

### 3. 🪟 垂直 Alt-Tab 窗口切换器 (`modules/window_switcher`)
- **真实 Z-order 排序**：直接读取 macOS WindowServer 的真实窗口层级（`hs.window.orderedWindows`），精准还原 MRU（最近使用）时间轴，多窗口重排不跳变。
- **多显示器指针跟随**：智能识别鼠标所在显示器，会话开启时光标所在屏幕窗口自动置顶并过滤干扰。
- **极简垂直列表 UI**：无预览图性能负担，毫秒级即按即现，多重快速切换零掉帧。

---

## 📁 模块化项目结构

本项目遵循标准的 Lua 模块化架构组织，所有业务模块统一收敛于 `modules/` 目录，职责清晰且互相解耦：

```text
~/.hammerspoon/
├── init.lua                           # 入口文件：运行时环境检测、package.path 注入与模块装载
├── README.md                          # 项目中文使用与开发指南
├── .gitignore                         # 私有密钥、本地配置与二进制忽略规则
│
├── modules/                           # 业务模块根目录
│   ├── remote_control/                # 遥控器映射与控制中心模块
│   │   ├── init.lua                   # 核心按键状态机、Profile 路由与 Webview 调度
│   │   ├── listener.swift             # Swift IOHIDManager 硬件级精准事件监听器源码
│   │   ├── listener                   # 编译生成的 Mach-O 监听守护进程（已 gitignore）
│   │   ├── dashboard.html             # 基于 WebKit 的可视化管理面板与按键监视器
│   │   ├── config.json.example        # 默认键位映射与应用规则模板
│   │   └── config.json                # 本地私有运行时配置文件（已 gitignore）
│   │
│   ├── voice_input/                   # 豆包流式语音输入模块
│   │   ├── init.lua                   # 语音输入调度、录音生命周期与文本注入
│   │   ├── stream.py                  # Python 音频捕获与 WebSocket 流式传输客户端
│   │   ├── hotwords.lua.example       # 自定义发音纠错与热词词库模板
│   │   ├── hotwords.lua               # 本地私有热词配置（已 gitignore）
│   │   ├── secret.lua.example         # 火山引擎 API Key 模板
│   │   └── secret.lua                 # 本地私有 API Key（已 gitignore）
│   │
│   └── window_switcher/               # 垂直 Alt-Tab 窗口切换器模块
│       └── init.lua                   # WindowServer Z-Order 排序与列表渲染
│
└── tests/                             # 自动化单元与集成测试套件
    ├── remote_control_test.lua        # 遥控器状态机、按键防抖与隔离校验
    └── window_switcher_test.lua       # 窗口切换器会话隔离与候选排序校验
```

---

## 🎮 遥控器 12 键功能速查表 (以小米遥控器 2 Pro 为例)

| 按键图标 | 物理按键标识 | 终端模式 (Termux / iTerm / Ghostty) | 浏览器模式 (Chrome / Safari / Arc) | 全局通用模式 |
| :---: | :--- | :--- | :--- | :--- |
| 🎤 | **语音键** (`voice`) | **按住说话** (实时流式转写，松开即刻上屏) | 同左 | 同左 |
| ⭕ | **OK 键** (`ok`) | **短按**：确认 Agent 执行 (`y` + 回车)<br>**长按**：重启开发服务 (Ctrl+C → ↑ → 回车) | **短按**：回车键 (Return)<br>**长按**：开启/关闭 DevTools | 回车键 (Return) |
| `<` | **返回键** (`back`) | **短按**：退格删除 (Backspace)<br>**长按**：发送命令中断 (Ctrl+C) | **短按**：网页后退上一页 (Cmd+[)<br>**长按**：强制硬刷新 (Shift+Cmd+R) | 退格删除 (Backspace) |
| ≡ | **菜单键** (`menu`) | **短按**：唤起垂直窗口切换器 (Alt-Tab)<br>**长按**：重置遥控状态 / 逃生键 | 同左 | 同左 |
| 📺 | **TV 键** (`tv`) | **短按**：一键切换并聚焦至浏览器<br>**长按**：打开/关闭遥控器控制面板 | **短按**：一键切换并聚焦至终端<br>**长按**：打开/关闭遥控器控制面板 | **短按**：终端 ↔ 浏览器秒级对切<br>**长按**：打开控制面板 |
| 🔊 | **音量 +** (`volume_up`) | 切换 tmux 下一个窗口 (Ctrl+B → n) | 切换下一个标签页 (Ctrl+Tab) | 系统音量增加 |
| 🔉 | **音量 -** (`volume_down`) | 切换 tmux 上一个窗口 (Ctrl+B → p) | 切换上一个标签页 (Ctrl+Shift+Tab) | 系统音量减小 |
| ⏻ | **电源键** (`power`) | **短按**：熄灭显示器 (任意键瞬时唤醒)<br>**长按**：开启/关闭**鼠标指针模式** | 同左 | 同左 |
| ↑ ↓ ← → | **方向环** | 翻查命令历史 / 逐词光标跳转 | 页面滚动 / 标签页左右切换 | 系统原生方向键 |

---

## 🚀 快速上手

### 1. 环境准备
确保你的 Mac 已安装必要依赖：
```bash
# 安装 Hammerspoon 与命令行工具
brew install --cask hammerspoon
brew install ffmpeg

# 验证 Swift 编译器（用于编译底层硬件监听器）
swiftc --version
```

### 2. 克隆仓库至配置目录
```bash
git clone https://github.com/a31521424/hammerspoon-config.git ~/.hammerspoon
```

### 3. 配置密钥与首次初始化
#### (1) 配置语音输入 API Key
复制并填入火山引擎豆包语音识别密钥：
```bash
cp ~/.hammerspoon/modules/voice_input/secret.lua.example ~/.hammerspoon/modules/voice_input/secret.lua
# 编辑填入你的 apiKey
```

#### (2) 编译硬件监听器
进入遥控器模块编译原生监听器（首次启动时 Hammerspoon 亦会自动触发编译）：
```bash
swiftc -O ~/.hammerspoon/modules/remote_control/listener.swift -o ~/.hammerspoon/modules/remote_control/listener
```

#### (3) 蓝牙遥控器配对与识别
1. 打开 Mac「系统设置」->「蓝牙」，按住遥控器的「主页键 + 菜单键」进入配对模式并完成连接；
2. 在键盘上按下快捷键 **`⌥ + ⇧ + R`** 打开控制面板；
3. 控制面板将自动检测到外设的 Vendor ID (`0x2717` / 10007) 与 Product ID (`0x32B8` / 12984)，点击「应用配置并重绑 hidutil 隔离」即可生效。

---

## 🧪 自动化测试

项目内置了完整的单元测试与端到端状态机测试套件，可通过 Hammerspoon CLI 一键运行：

```bash
# 1. 运行遥控器按键状态机与硬件 Usage 校验测试
hs -c 'return dofile(hs.configdir .. "/tests/remote_control_test.lua")'

# 2. 运行窗口切换器多屏与排序测试
hs -c 'return dofile(hs.configdir .. "/tests/window_switcher_test.lua")'
```

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 协议开源。
