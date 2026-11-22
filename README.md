# dsh-easysnap-plugin · 截图取景框

> **让截图直接进入对话。** 点输入框旁的相机图标，桌面出现常驻取景框；拖到任意窗口上方按 `Snap`，框内画面立刻作为图片附件插入当前输入框——不用保存文件，也不用拖拽。**取景框不会关闭**：翻页、切窗口、改参数后可以接着拍，连拍多张一次性发送。框内透明穿透，能一边操作下面的程序一边取景；支持拖动和四边、四角缩放。Windows 专用。
>
> **Capture straight into the chat.** Click the camera by the composer, park the always-on-top frame over any window, hit **Snap**, and the framed area lands as an image attachment — no saving, no dragging. The frame stays open: snap again and again and send several at once. The click-through hole keeps the app under it usable. Windows only.

## 安装

```bash
# 从 GitHub 安装（推荐）
dsh plugin --profile web add github:wangtengteng498/dsh-easysnap-plugin

# 或从本地目录安装
dsh plugin --profile web add /path/to/dsh-easysnap-plugin
```

也可以打开 DSH 的 **Plugin Manager → Install bundle → 选择本仓库目录**。

装完**重启 DSH**（宿主模块在启动时加载），然后在输入框「＋」右边会多出一个相机图标。

![icon](icon.svg)

---

## 它和普通截图工具有什么不一样

| | 普通截图（Snipaste / Win+Shift+S / 豆包） | dsh-easysnap-plugin |
|---|---|---|
| 取景框 | 一次性，截完就消失 | **常驻**，可以一直摆在那里 |
| 框内画面 | 冻结成一张静态图 | **透明穿透**，可以继续操作底下的程序 |
| 出图方式 | 截完存文件 / 进剪贴板 | **点 Snap 直接进当前对话** |
| 连拍 | 每次都要重新框 | 框不动，**点一下多一张** |

典型用法：把框罩在 Godot / Blender / 浏览器的某个区域上，改一下参数、翻一页、切个视角，再点一次 `Snap`——图直接进对话框，不用保存、不用找文件、不用拖拽。

---

## 为什么不能纯前端实现

DSH 的 Electron 主进程里显式关掉了浏览器截屏能力：

```js
browserSession.setDisplayMediaRequestHandler((_request, callback) => {
  callback({});          // 永远返回空 → getDisplayMedia() 永久 pending
});
```

所以任何 `navigator.mediaDevices.getDisplayMedia()` 的写法在 DSH 里都会卡在“等待屏幕选择”。
本插件改为**宿主侧 PowerShell 拍屏 + 本地路由回传**，页面只负责选窗口、框选和插入。

## 工作方式

```
点击相机按钮
   │  GET /dsh-easysnap-plugin/frame
   ▼
宿主 spawn 一个 PowerShell 进程 → 桌面上出现置顶取景框（WinForms）
   │  拖底栏移动 / 拖上/左/右边框拉伸 / 右上、左上斜向缩放 / X 或 Esc 关闭
   │  点 Snap（或按 Enter）
   ▼
取景框隐藏 150ms → CopyFromScreen 抓框内区域 → 写 PNG + marker 文件 → 框重新出现
   │  页面每 600ms 轮询 /dsh-easysnap-plugin/state 与 /dsh-easysnap-plugin/last?since=<上次时间戳>
   ▼
新图到达 → 合成一次 paste 事件塞进输入框 → 一张图片附件
```

## 使用

1. 点相机图标 → 桌面中央出现取景框
2. **拖底栏**（含文字区域）移动整个框
3. **拖上 / 左 / 右边框**拉伸；左上、右上角斜向缩放（底边不参与拉伸，避免和拖动条抢事件）
4. 点 **Snap**（或 Enter）→ 框内画面进对话；框不会关，可以继续拍
5. 点 **X**（或 Esc）关闭取景框；页面会立刻收到状态，按钮恢复

## 接口

| 路由 | 作用 |
|---|---|
| `GET /dsh-easysnap-plugin/frame` | 启动取景框（单实例：会先关掉上一个） |
| `GET /dsh-easysnap-plugin/state` | `{alive, hasShot}`，页面据此决定继续轮询还是收工 |
| `GET /dsh-easysnap-plugin/last?since=<ms>` | 取最近一张 PNG；没有新图返回 204，响应头 `x-shot-ts` 给时间戳用于去重 |
| `GET /dsh-easysnap-plugin/windows` | 窗口列表（备用能力，当前 UI 未使用） |
| `GET /dsh-easysnap-plugin/capture?hwnd=<id>` | 抓指定窗口或整屏（备用能力） |

## 已知限制

- **仅 Windows**：拍屏依赖 PowerShell + WinForms + `user32`。
- 取景框是**独立进程**，DSH 退出后它不会自动消失（点 X / Esc 即可）。
- 单实例：每次点相机都会关掉上一个框。
- 框内画面靠 `CopyFromScreen` 抓取，**框外被其他窗口遮挡不影响**，但**框内如果被别的窗口挡住，抓到的就是那个遮挡物**（这是屏幕抓取的本质）。
- 多显示器目前只按主屏工作区居中，跨屏需要手动拖过去。
- 一次会话最多连拍 10 分钟后自动停止轮询（防泄漏）。

## 目录结构

```
dsh-easysnap-plugin/
├─ index.js          宿主：路由 + 启动取景框进程
├─ client.js         页面：相机按钮 + 轮询 + 插入附件
├─ frame.ps1         取景框（WinForms，DPI-aware，Region 抠洞）
├─ capture.ps1       窗口枚举 / 单窗口截图（备用）
├─ cordis.patch.yml  bundle 行插桩
├─ package.json      dsh.bundle + dsh.client 声明
├─ locale/           en.json / zh.json（插件市场展示用）
├─ docs/DETAIL.md    插件详情页
└─ icon.svg
```

## 开发

```bash
# 语法自检（无构建步骤）
node --check index.js
node --check client.js
powershell -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('frame.ps1',[ref]$null,[ref]$e)"
```

页面端改动刷新即可；**宿主端（index.js）改动需要重启 DSH**。

## License

MIT
