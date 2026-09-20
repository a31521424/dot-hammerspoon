# Hammerspoon 配置

基于 [Hammerspoon](https://www.hammerspoon.org/) 的 macOS 自动化工具集，包含以下模块：

- **蓝牙遥控器控制 (`modules/remote_control`)**：通过 Swift `IOHIDManager` 监听硬件报文，结合 `hidutil` 隔离原生键盘输入；支持多应用场景键位路由、鼠标指针模式与 Web 控制面板。
- **流式语音输入 (`modules/voice_input`)**：对接火山引擎豆包语音大模型 WebSocket 接口，实现按住说话（Hold-to-Talk）与实时文字上屏。
- **垂直窗口切换器 (`modules/window_switcher`)**：基于 macOS WindowServer 真实 Z-order（MRU）排序的垂直 Alt-Tab 切换器，支持多显示器跟随。

---

## 目录结构

```text
~/.hammerspoon/
├── init.lua                           # 入口文件：包路径注入与模块加载
├── requirements.txt                   # 流式语音 WebSocket 依赖
├── README.md                          # 配置与使用说明
├── LICENSE                            # MIT 开源许可证
├── .gitignore                         # 敏感信息与临时文件过滤
│
├── modules/
│   ├── remote_control/                # 遥控器模块
│   │   ├── init.lua                   # 状态机、按键分发与 Webview 调度
│   │   ├── listener.swift             # Swift IOHIDManager 硬件监听器源码
│   │   ├── listener                   # 监听器可执行文件（git 忽略）
│   │   ├── dashboard.html             # WebKit 控制面板与实时按键监视器
│   │   ├── config.json.example        # 默认按键映射模板
│   │   └── config.json                # 本地按键配置（git 忽略）
│   │
│   ├── voice_input/                   # 语音输入模块
│   │   ├── init.lua                   # 录音进程管理与按键生命周期
│   │   ├── stream.py                  # Python 音频采集与 WebSocket 传输客户端
│   │   ├── hotwords.lua.example       # 自定义热词模板
│   │   ├── hotwords.lua               # 本地热词配置（git 忽略）
│   │   ├── secret.lua.example         # 豆包 API Key 模板
│   │   └── secret.lua                 # 本地 API Key（git 忽略）
│   │
│   └── window_switcher/               # 窗口切换模块
│       └── init.lua                   # 垂直 Alt-Tab 渲染与排序
│
└── tests/                             # 自动化测试
    ├── remote_control_test.lua        # 遥控器状态机与按键隔离测试
    └── window_switcher_test.lua       # 窗口切换器多屏过滤测试
```

---

## 遥控器键位映射（以小米蓝牙语音遥控器 2 Pro 为例）

| 按键 | 内部标识 | 终端 (Terminal / iTerm2) | 浏览器 (Chrome / Safari / Arc) | 全局默认 |
| :--- | :--- | :--- | :--- | :--- |
| **语音键** | `voice` | 按住说话，松开即刻上屏 | 同左 | 同左 |
| **OK 键** | `ok` | 短按：确认 (`y` + 回车)<br>长按：重启服务 (`Ctrl+C` → `↑` → 回车) | 短按：回车 (`Return`)<br>长按：开关开发者工具 | 回车 (`Return`) |
| **返回键** | `back` | 短按：退格 (`Backspace`)<br>长按：中断 (`Ctrl+C`) | 短按：后退 (`Cmd+[`)<br>长按：强制刷新 (`Shift+Cmd+R`) | 退格 (`Backspace`) |
| **菜单键** | `menu` | 短按：唤起垂直窗口切换器<br>长按：重置遥控器状态 | 同左 | 同左 |
| **TV 键** | `tv` | 短按：切换至浏览器<br>长按：开关控制面板 | 短按：切换至终端<br>长按：开关控制面板 | 短按：终端 ↔ 浏览器切换<br>长按：开关控制面板 |
| **音量 +** | `volume_up` | tmux 下一个窗口 (`Ctrl+B` → `n`) | 下一个标签页 (`Ctrl+Tab`) | 系统音量加 |
| **音量 -** | `volume_down` | tmux 上一个窗口 (`Ctrl+B` → `p`) | 上一个标签页 (`Ctrl+Shift+Tab`) | 系统音量减 |
| **主页键** | `home` | 短按：调度中心 (`Mission Control`)<br>双击：显示桌面 (`Show Desktop`) | 同左 | 同左 |
| **电源键** | `power` | 短按：熄灭屏幕<br>长按：开关鼠标指针模式 | 同左 | 同左 |
| **方向键** | `up/down/left/right` | 命令历史翻查 / 光标词跳转 | 页面滚动 / 标签页切换 | 原生方向键 |

*注：鼠标指针模式下，方向键控制光标平滑移动，OK 键为左键单击，返回键为右键单击，音量 +/- 为滚轮上下平滑滚动。*

> [!NOTE] 硬件限制与安全说明
> - **0xF1 限制**：Back 的键盘页 `0xF1` 只能靠 IOHID 监听；hidutil 无法重映射该 usage。若 listener 未运行，Back 键不保证隔离。
> - **Listener 失败降级**：解锁状态下若 listener 未运行，系统不会应用 hidutil 映射（或自动重置本设备），遥控器退回原生多媒体键，避免音量/Home/电源成为死键；未运行时不声称已隔离。
> - **锁屏残留风险**：Mac 锁屏或屏保期间，系统会自动丢弃全部遥控 HID 事件。但在 hidutil 尚未生效的瞬间、`0xF1` Back、或 hidutil 失败时，原生遥控键仍可能打进锁屏密码框。
> - **特权输入与危险宏风险**：遥控器属于特权输入设备。任何人拿到已配对的蓝牙遥控器，都可在 macOS 解锁会话下通过终端 OK 键批准 Agent 操作 (`macro:approve_agent`) 或重启开发服务器。如需防范此风险，可在配置中将 `settings.dangerousMacros` 设为 `false` 以全局禁用上述危险宏。

---

## 快速上手

### 1. 依赖准备

```bash
brew install --cask hammerspoon
brew install ffmpeg

# 创建流式语音识别使用的 Python 虚拟环境并安装依赖
python3 -m venv ~/.hammerspoon/.venv
~/.hammerspoon/.venv/bin/pip install -r ~/.hammerspoon/requirements.txt
```

### 2. 克隆配置

```bash
git clone https://github.com/a31521424/dot-hammerspoon.git ~/.hammerspoon
```

### 3. 配置与初始化

1. **语音识别 API Key**：
   ```bash
   cp ~/.hammerspoon/modules/voice_input/secret.lua.example ~/.hammerspoon/modules/voice_input/secret.lua
   # 编辑填入火山引擎豆包语音识别的 apiKey
   ```
   *注意：macOS GUI 启动的 Hammerspoon 不会加载 `~/.zshrc`，因此请直接在 `modules/voice_input/secret.lua`（或兼容别名 `~/.hammerspoon/voice_input_secret.lua`）中填写 `apiKey`，不要依赖在 `~/.zshrc` 中 export；环境变量仅在终端执行 `hs` 启动时有效。*

2. **编译硬件监听器**（首次加载时脚本亦会自动触发编译）：
   ```bash
   swiftc -O ~/.hammerspoon/modules/remote_control/listener.swift -o ~/.hammerspoon/modules/remote_control/listener
   ```

3. **连接外设与控制面板**：
   - 在 macOS 蓝牙设置中配对遥控器。
   - 按下快捷键 `⌥ + ⇧ + R` 打开控制面板，确认设备已识别并点击应用配置。

---

## 测试

可通过 Hammerspoon 命令行工具运行自动化测试：

```bash
# 运行遥控器状态机与隔离测试
hs -c "return dofile(hs.configdir .. '/tests/remote_control_test.lua')"

# 运行窗口切换器测试
hs -c "return dofile(hs.configdir .. '/tests/window_switcher_test.lua')"
```

---

## 开源协议

本项目基于 [MIT License](LICENSE) 开源。
