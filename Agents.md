# Barttery - Agent 开发与打包指南 (Agents.md)

本文档面向在此代码库上工作的 AI Agent 及开发者，提供项目的核心架构、构建打包、本地部署与日常测试的规范说明。

---

## 1. 核心架构与设计规范

- **双进程模型**：
  - **主应用程序 (`Barttery.app`)**：常驻 macOS 菜单栏，拥有完整硬件访问权限（BLE 蓝牙、IOKit、Logitech HID、AppleMobileDevice 驱动等）。
  - **小组件扩展 (`BartteryWidget.appex`)**：macOS 14+ WidgetKit 桌面与通知中心小组件，运行于严格沙盒 (`app-sandbox`) 中，**不直接访问底层硬件**。
- **快照共享机制 (Widget Snapshot Store)**：
  - 主程序在电量更新或用户调整设置时，将数据编码为 `WidgetBatterySnapshot` JSON。
  - 主程序直接将快照写入小组件容器路径：  
    `~/Library/Containers/me.yura.barttery.widget/Data/Documents/battery-snapshot.json`
  - 这种设计允许应用在无 Apple Developer Team 证书 / Ad-hoc 签名状态下，依然能在主应用与 Widget 扩展之间稳定通信，避开 App Group 授权限制。
- **WidgetKit 预算与即时刷新策略**：
  - macOS `chronod` 对第三方小组件设置了每日刷新配额。
  - **严禁** 在刷新时循环调用多个 `WidgetCenter.shared.reloadTimelines(ofKind:)`；统一且仅使用单次 `WidgetCenter.shared.reloadAllTimelines()`。
  - 用户触发的设置变更（如更改小组件展示设备、点击菜单栏刷新）必须以 `force: true` 立即写入并触发刷新，绕过后台 BLE 节流。

---

## 2. 本地打包与部署说明 (Local Build & Deploy)

### 2.1 一键本地构建并部署至系统应用目录（推荐）

在终端根目录下运行：

```bash
make install
```

> **注意（Agent 环境执行要求）**：  
> 在 AI Agent 沙盒环境下执行构建与安装命令时，必须设置 `BypassSandbox: true`。因为编译需要访问 `/Users/opm/Library/Caches/org.swift.swiftpm`，安装需要向 `/Applications/` 写入，且启动应用需要 LaunchServices 权限。

#### `make install` 内部执行流程：
1. **清理旧产物**：删除旧版 `./Barttery.app`。
2. **编译主二进制**：执行 `swift build -c release --arch arm64`。
3. **组装 App Bundle**：
   - 拷贝主程序二进制、`Info.plist`、`AppIcon.icns`、本地化字符串（`*.lproj`）。
   - 拷贝并签名底层硬件 Helper 驱动（`idevice_id`、`ideviceinfo`、`comptest`、`bartbeat`、`mobilebeat`、`wifiwatch`）及所需动态库。
4. **编译小组件插件**：
   - 使用 `xcrun swiftc` 独立编译 `Sources/WidgetSnapshot.swift` 与 `Widgets/BartteryWidget.swift`，生成 `BartteryWidget.appex`。
   - 注入小组件 `Info.plist` 并应用 `Widgets/BartteryWidget.entitlements` 权限签名。
5. **签名 Bundle**：使用开发证书（或 Ad-hoc）对整个 `Barttery.app` 进行代码签名。
6. **安装与注销旧进程**：
   - 终止当前运行的 `Barttery` 进程。
   - 将应用同步至 `/Applications/Barttery.app`，并清除隔离属性 (`xattr -dr com.apple.quarantine`)。
7. **注册系统小组件**：
   - 创建小组件数据目录：`~/Library/Containers/me.yura.barttery.widget/Data/Documents/`
   - 使用 `pluginkit -a` 注册并激活 `me.yura.barttery.widget`。
8. **清除系统小组件缓存**：
   - 重启 `chronod` 与 `NotificationCenter`，重置可能耗尽的 WidgetKit 刷新限额预算。
9. **自动启动**：拉起 `/Applications/Barttery.app`。

---

### 2.2 常用开发构建命令

| 命令 | 用途 | 适用场景 |
| :--- | :--- | :--- |
| `make build` | 仅在当前目录编译并组装 `Barttery.app` | 快速检查构建产物与签名，不替换系统应用 |
| `make run` | 编译并在当前目录启动 `Barttery.app` | 本地临时运行与调试 |
| `make clean` | 清理 `.build` 及临时二进制 | 排查缓存污染或重置编译状态 |
| `make widgets-check` | 使用 xcodebuild 静态检查小组件工程 | 检验 Xcode target 语法与编译正确性 |
| `make widget-preview` | 编译并运行无头小组件渲染工具 | 快速验证小组件视图布局，无需启动全量应用 |

---

## 3. 自动化测试与验证

在提交任何代码前，必须保证所有单元测试通过：

```bash
swift test
```

### 关键测试套件分布：
- `WidgetSnapshotTests`: 测试小组件快照编码/解码、空快照容错、多尺寸容量限制、时间戳有效性。
- `WidgetDeviceSelectionTests`: 测试小组件设备自定义模式、勾选过滤逻辑、排序移动。
- `WatchChargingTests` & `AirPodsChargingTests`: 测试设备充电状态机防抖、缓存失效策略。
- `AccessoryUpdateTimeTests`: 测试各类外设更新时间戳与独立读数隔离。

---

## 4. 故障排查与 Agent 避坑要点

1. **小组件显示为空白（"Open Barttery to see your devices"）**：
   - 检查 `~/Library/Containers/me.yura.barttery.widget/Data/Documents/battery-snapshot.json` 是否存在。
   - 若文件存在但小组件仍未更新，运行 `killall chronod` 强制刷新 macOS 桌面小组件守护进程。
2. **菜单栏“刷新”按钮抖动**：
   - 刷新按钮文案需保持固定长度（统一为“刷新”），仅对内部 SF Symbol 图标做旋转动画，禁止动态切换为“正在刷新…”导致视图宽度跳动。
3. **SwiftPM 缓存无法访问报错 (`authorization denied`)**：
   - 智能体环境执行 `swift build` 或 `swift test` 时，必须使用 `BypassSandbox: true`。
4. **Git 提交被锁 (`.git/index.lock`)**：
   - Git 写入操作同样需要在 `BypassSandbox: true` 下执行，以获取宿主真实权限。
