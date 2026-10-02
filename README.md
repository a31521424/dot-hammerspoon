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

## 遥控器键位映射（iTerm2 SSH Agent 体验版）

遥控器默认只向前台 iTerm2 发出输入。其他应用中，主页仍可回到 iTerm2，电源长按仍可打开配置面板。键盘的 Option+W 语音入口保留。

| 按键 | 短按／按住 | 长按 |
| :--- | :--- | :--- |
| 语音 | 按住录音，松开完成转录并粘贴；不自动发送 | 持续录音 |
| OK | Enter；有待恢复转录时先插入，再按一次发送 | 单次 Enter，不重跑历史命令 |
| 返回 | 按下立即退格；查看模式中同时回到输入 | 连续退格，松开停止 |
| 方向键 | 原生方向键；查看输出模式中上下为 Shift+PageUp／PageDown | 350ms 后每 90ms 重复，松开停止 |
| 音量 +／− | 原生 PageUp／PageDown，查看 Agent 输出 | 500ms 后每 250ms 连续翻页 |
| 菜单（三横线） | 按下立即退格，修改输入文字 | 连续退格，松开停止 |
| 主页 | 回到 iTerm2 | 800ms 后重置遥控器临时模式 |
| TV | 查看输出／返回输入 | 无操作 |
| 电源 | 无操作 | 800ms 后打开／隐藏配置面板 |

HERDR 的快捷键尚未确认。音量键用于原生 PageUp/PageDown；TV 查看模式保留 Shift+PageUp/PageDown，供查看终端历史。翻页最终行为取决于当前 iTerm2 Profile 和交互程序的键位设置。不会向 SSH 终端发送猜测的 HERDR 命令或 tmux 前缀。

语音开始时记录应用、窗口和 AX 输入区域。完成时焦点不匹配、遥控器切换过输入目标或锁屏，则保留文本并显示提示。回原输入区按 OK 插入，不同时发送。该保护不识别同一终端 pane 内通过键盘或远端命令发生的 HERDR/tmux 会话切换。

遥控器原生输入统一经 hidutil 转为 F20 并吞掉；实际按键身份由 IOHID listener 提供，避开 F14/F15 中转和遥控器 Consumer 亮度 usage。listener 失败时恢复本设备原生映射。实体键盘 F20 也会被吞掉；常规方向键、Enter、Escape 和 F1–F19 不受此中转拦截影响。Back 的键盘 usage 0xF1 仍只能通过 IOHID 监听，无法保证其原生输入完全隔离。

未连接遥控器时，全局键盘监听暂停，IOHID helper 保留并等待系统连接通知，不轮询蓝牙；连接后先恢复键盘监听，再应用隔离映射。最后一个匹配的 HID 服务断开、锁屏或监听进程退出时，会停止鼠标移动、长按、双击和连按任务，并重置临时模式。断连只结束遥控器触发的录音；锁屏会结束当前录音。锁屏期间 listener 退出时保留按键隔离，解锁后还原。实体键盘 F20 仅在遥控器键盘监听启用期间被吞掉。

本机原配置快照位于 `backups/remote-workflow-v1/`，不包含语音 API 密钥。快照仅保存首次体验版实施前的文件，不应覆盖已有快照。

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
