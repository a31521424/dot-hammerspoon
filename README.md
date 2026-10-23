# Hammerspoon 模块化配置

基于 [Hammerspoon](https://www.hammerspoon.org/) 的 macOS 自动化插件集。各模块相互解耦，支持**全量克隆后按需开关**或**通过 Git Sparse Checkout 定向安装单个/多个插件**。

---

## 插件模块一览

| 编号 | 模块路径 | 功能简介 | 核心入口 / 快捷键 | 外部依赖 | 默认启用 |
| :---: | :--- | :--- | :--- | :--- | :---: |
| **1** | `modules/window_switcher` | **垂直窗口切换器**：基于 macOS WindowServer 真实 Z-order（MRU）排序与多屏鼠标跟随 | `Command + Tab` / `Command + Shift + Tab` | Xcode Command Line Tools (`swiftc` 自动编译) | `true` |
| **2** | `modules/remote_control` | **蓝牙遥控器控制引擎**：Swift `IOHIDManager` 硬件监听、`hidutil` F20 隔离、多场景键位与 Web 面板 | 蓝牙遥控器按键 / `⌥ + ⇧ + R` 控制面板 | Xcode Command Line Tools (`swiftc`) | `false` |
| **3** | `modules/voice_input` | **流式语音输入**：对接火山引擎豆包流式 ASR（SAUC WebSocket）与 HTTP Flash 校对 | 按住 `Option + W` 说话，松开上屏 | `ffmpeg`、豆包 API Key、Python `.venv`（可选，流式） | `true` |
| **4** | `modules/input_target.lua` | **跨模块焦点一致性保护**：校验应用/窗口/AX 焦点元素，防遥控器与语音异步切窗误投递 | 自动协同模块 **2** 与 **3**（按遥控器 `OK` 恢复插入） | 无（纯 Lua，配合模块 **2** 使用） | `false` |

---

## 目录结构

```text
~/.hammerspoon/
├── init.lua                           # 入口文件：ENABLED_MODULES 插件开关与按需加载
├── requirements.txt                   # 流式语音 WebSocket 依赖（仅模块 3 流式模式需要）
├── README.md                          # 配置、定向安装与使用说明
├── LICENSE                            # MIT 开源许可证
├── .gitignore                         # 敏感信息与构建产物过滤
│
├── modules/
│   ├── window_switcher/               # [模块 1] 垂直窗口切换器
│   │   ├── init.lua                   # 垂直列表渲染与 MRU 排序
│   │   ├── native_hotkeys.lua         # 原生快捷键守护进程管理
│   │   └── native_guard.swift         # SkyLight 符号热键挂起与 Carbon 手势账本
│   │
│   ├── remote_control/                # [模块 2] 蓝牙遥控器模块
│   │   ├── init.lua                   # 状态机、按键分发与 Webview 调度
│   │   ├── listener.swift             # Swift IOHIDManager 硬件监听器源码
│   │   ├── dashboard.html             # WebKit 控制面板与实时按键监视器
│   │   └── config.json.example        # 默认按键映射模板
│   │
│   ├── voice_input/                   # [模块 3] 流式语音输入模块
│   │   ├── init.lua                   # 录音进程管理、预览卡片与识别生命周期
│   │   ├── stream.py                  # Python WebSocket 流式传输守护进程
│   │   ├── hotwords.lua.example       # 自定义热词与纠错替换模板
│   │   └── secret.lua.example         # 豆包 API Key 模板
│   │
│   └── input_target.lua               # [模块 4] 跨模块焦点一致性保护
│
└── tests/                             # 自动化测试套件
    ├── window_switcher_test.lua       # 窗口切换器多屏过滤与手势队列测试
    ├── native_hotkeys_test.lua        # 原生快捷键进程管理测试
    ├── native_gestures_test.py        # 原始时间戳与手势归属测试
    ├── native_guard_test.py           # 系统原生入口恢复集成测试
    └── remote_control_test.lua        # 遥控器状态机、F20 隔离与焦点保护测试
```

---

## 安装与按需启用指南

前置基础环境：

```bash
brew install --cask hammerspoon
```

你可以根据自身需求选择 **方式一（克隆全仓 + 开关控制）** 或 **方式二（Git Sparse Checkout 定向拉取指定模块）**。

### 方式一：克隆全仓 + `init.lua` 按需开关（推荐）

```bash
git clone https://github.com/a31521424/dot-hammerspoon.git ~/.hammerspoon
```

编辑 `~/.hammerspoon/init.lua` 顶部的 `ENABLED_MODULES` 表，将不需要的模块设为 `false`（默认仅启用 **1 窗口切换器** 与 **3 流式语音输入**，关闭 **2 蓝牙遥控器** 与 **4 跨模块焦点保护**）：

```lua
local ENABLED_MODULES = {
  window_switcher = true,  -- 1. 垂直窗口切换器 (modules/window_switcher)
  remote_control  = false, -- 2. 蓝牙遥控器控制引擎 (modules/remote_control)
  voice_input     = true,  -- 3. 流式语音输入 (modules/voice_input)
  input_target    = false, -- 4. 跨模块焦点一致性保护 (modules/input_target.lua)
}
```

随后只需执行你所启用模块对应的初始化步骤（见下方「各模块依赖与初始化」）。

---

### 方式二：定向安装（仅检出所需插件目录）

若不希望在本地拉取不需要的模块代码（例如不需要 `2. remote_control` 和 `4. input_target.lua`），可使用 `git sparse-checkout` 按需拉取，`init.lua` 会自动跳过未安装的模块：

#### 方案 A：仅安装「1. 垂直窗口切换器」

```bash
git clone --filter=blob:none --sparse https://github.com/a31521424/dot-hammerspoon.git ~/.hammerspoon
cd ~/.hammerspoon
git sparse-checkout set --no-cone /init.lua /README.md /LICENSE /.gitignore /modules/window_switcher/
```

#### 方案 B：安装「1. 垂直窗口切换器 + 3. 流式语音输入」（不含遥控器 2 与焦点保护 4）

```bash
git clone --filter=blob:none --sparse https://github.com/a31521424/dot-hammerspoon.git ~/.hammerspoon
cd ~/.hammerspoon
git sparse-checkout set --no-cone /init.lua /requirements.txt /README.md /LICENSE /.gitignore /modules/window_switcher/ /modules/voice_input/
```

#### 方案 C：全量检出所有模块（1 + 2 + 3 + 4）

```bash
git -C ~/.hammerspoon sparse-checkout disable
```

---

## 各模块依赖与初始化（按需执行）

### 模块 1：垂直窗口切换器 (`modules/window_switcher`)

- **依赖**：首次启动或 `native_guard.swift` 更新时会自动调用 `/usr/bin/swiftc` 编译守护进程（需安装 Xcode Command Line Tools：`xcode-select --install`）。
- **使用**：Reload Hammerspoon 后即可使用 `Command + Tab` / `Command + Shift + Tab`。

### 模块 3：流式语音输入 (`modules/voice_input`)

1. **安装音频采集与流式依赖**：
   ```bash
   brew install ffmpeg

   # 创建流式语音识别使用的 Python 虚拟环境（若不创建则自动降级为 HTTP Flash 识别）
   python3 -m venv ~/.hammerspoon/.venv
   ~/.hammerspoon/.venv/bin/pip install -r ~/.hammerspoon/requirements.txt
   ```
2. **配置豆包语音 API Key**：
   ```bash
   cp ~/.hammerspoon/modules/voice_input/secret.lua.example ~/.hammerspoon/modules/voice_input/secret.lua
   # 编辑填入火山引擎豆包语音识别的 apiKey
   ```
   *注意：macOS GUI 启动的 Hammerspoon 不会加载 `~/.zshrc`，请直接在 `modules/voice_input/secret.lua` 中填写 `apiKey`。*
3. **（可选）配置自定义热词**：
   ```bash
   cp ~/.hammerspoon/modules/voice_input/hotwords.lua.example ~/.hammerspoon/modules/voice_input/hotwords.lua
   ```

### 模块 2 & 4：蓝牙遥控器与跨模块焦点保护 (`modules/remote_control` + `modules/input_target.lua`)

仅在使用蓝牙遥控器操控终端/浏览器时需要：

1. 在 `init.lua` 中将 `remote_control = true`（如需录音期间防切窗误粘贴，同时将 `input_target = true`）。
2. **编译硬件监听器**（首次加载时脚本亦会自动触发编译）：
   ```bash
   swiftc -O ~/.hammerspoon/modules/remote_control/listener.swift -o ~/.hammerspoon/modules/remote_control/listener
   ```
3. **配对与配置**：在系统蓝牙设置中配对遥控器，按下 `⌥ + ⇧ + R` 打开控制面板识别设备并应用配置。

---

## 模块详细说明

### 窗口切换快捷键 (`modules/window_switcher`)

- `Command + Tab`：下一个窗口；`Command + Shift + Tab`：上一个窗口。松开 Command 确认，即使 Shift 仍按住；Esc 取消。
- 只注册这一组窗口切换快捷键；`Option + Tab`／`Option + Shift + Tab` 不再绑定。也可鼠标点击选择窗口。

`init.lua` 中的 `nativeCommandTab = true` 启用原生快捷键。参考 [AltTab 的实现](https://github.com/lwouis/alt-tab-macos/blob/master/src/events/KeyboardEvents.swift)，辅助进程通过 SkyLight 私有 API 暂停系统 Command+Tab／Command+Shift+Tab，再用 Carbon `RegisterEventHotKey` 注册两个组合键。无需手动改系统设置或键盘映射；密码框开启 Secure Input 时仍使用同一套窗口切换流程。窗口筛选、排序和跟随鼠标所在显示器的行为保持不变。

原生辅助进程记录每次 Command 按住和松开的原始时间，并将 Carbon 按键关联到对应手势。普通输入下，只观察 Command+Tab 的键码、方向和时间来校正其他监听器造成的延迟，不读取或保存文字；Secure Input 隐藏原始 Tab 时使用 Carbon 路径。Carbon 是唯一触发入口。同步标记确保先处理已有修饰键通知再确定手势；无法确定归属或同步失败时恢复系统入口。触发、取消和确认从同一消息流发送，Lua 按手势编号处理，避免快速连按时串会话。迟到的同一次手势仍沿用原窗口列表；遥控器或鼠标接管时清除排队动作，并拒绝旧手势的迟到消息。窗口枚举、绘图和确认选择在输入回调之外执行。辅助进程首次运行或源文件更新时自动编译，需要 Apple Command Line Tools；编译或注册失败时恢复系统 Command+Tab。

辅助进程记录系统入口原来的启用状态；停止模块、重新加载或 Hammerspoon 退出时恢复。辅助进程被强制结束时，由 Hammerspoon 恢复；若两者同时被强制结束，下次启动从记录恢复。设为 `nativeCommandTab = false` 并重新加载后恢复系统入口。这里使用私有 API，macOS 升级后需重新验证。

### 遥控器键位映射（`modules/remote_control`，iTerm2 SSH Agent 工作流）

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

当同时启用 `input_target` 时，语音开始会记录应用、窗口和 AX 输入区域；完成时若焦点不匹配、遥控器切换过输入目标或锁屏，则保留文本并显示提示，回原输入区按 OK 插入。仅单独启用 `voice_input`（未启用 `input_target`）时，识别结果直接粘贴至当前光标处。

遥控器原生输入统一经 hidutil 转为 F20 并吞掉；实际按键身份由 IOHID listener 提供，避开 F14/F15 中转和遥控器 Consumer 亮度 usage。listener 失败时恢复本设备原生映射。未连接遥控器时，全局键盘监听暂停，IOHID helper 保留并等待系统连接通知，不轮询蓝牙；连接后先恢复键盘监听，再应用隔离映射。最后一个匹配的 HID 服务断开、锁屏或监听进程退出时，会停止鼠标移动、长按、双击和连按任务，并重置临时模式。

---

## 测试

可通过 Hammerspoon 命令行工具运行自动化测试：

```bash
# 运行窗口切换器测试
hs -c "return dofile(hs.configdir .. '/tests/window_switcher_test.lua')"

# 原生快捷键进程管理测试（使用模拟进程，不改变系统入口）
hs -c "return dofile(hs.configdir .. '/tests/native_hotkeys_test.lua')"

# 运行遥控器状态机与隔离测试
hs -c "return dofile(hs.configdir .. '/tests/remote_control_test.lua')"

# 编译并测试实际 Swift 手势状态机（不修改系统入口）
python3 tests/native_gestures_test.py
```

`tests/native_guard_test.py` 在 macOS 上验证真实系统入口的恢复。先执行 `hs -c 'WindowSwitcher:stop()'`，再运行 `python3 tests/native_guard_test.py`；测试结束后重新加载配置以启用切换器。

---

## 开源协议

本项目基于 [MIT License](LICENSE) 开源。
