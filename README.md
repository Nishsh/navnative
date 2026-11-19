# 私人导航 Pro · NavNative

纯原生 iOS 导航应用（SwiftUI + MapKit），**不含 WKWebView、不含任何第三方 SDK**，编译出的 IPA 可直接拖进全能签签名安装。

## 为什么换成原生

| 项目 | NavApp（WKWebView + 高德 JS） | NavNative（本工程） |
| --- | --- | --- |
| 依赖 | 高德 JS API + Key，需联网加载 | 系统 MapKit，零依赖 |
| 3D 楼块 | Loca PolygonLayer + Overpass | `showsBuildings` 系统 3D 建筑 |
| 车头向上 | JS 每帧 `setRotation` | `MKMapCamera.heading` 原生 |
| 路线规划 | 高德 Driving（含实时路况） | `MKDirections`（驾车，无路况色带） |
| 签名成功率 | 带 web 资源 | 包更小、无嵌入 framework |

两个 App 的 Bundle ID 不同（`com.example.privatenavnative` vs `com.example.privatenav`），可以在手机上共存。

## 功能

- **定位**：CoreLocation，导航级精度，速度 / 海拔 / 航向 / 水平精度实时显示
- **车头向上**：相机 heading 跟随罗盘与 GPS 航迹，角度走最短弧平滑插值
- **3D 视图**：跟随模式 pitch 55°，可切回俯视
- **目的地搜索**：`MKLocalSearchCompleter` 输入补全 + `MKLocalSearch` 解析
- **长按选点**：长按地图任意位置设为终点，自动逆地理编码取名
- **路线规划**：`MKDirections` 多方案，横向卡片切换，自动缩放到全程
- **导航**：转向指令 + 到路口剩余距离 + 剩余里程/时间 + 车速，到达自动提示
- **轨迹**：8 米或 12 秒采一点，蓝色细线绘制，上限 4000 点

## 目录结构

```
NavNative/
├── NavNative/
│   ├── NavNativeApp.swift      # 入口
│   ├── RootView.swift          # 主界面：地图 + 顶部搜索 + 底部操作
│   ├── MapCanvas.swift         # MKMapView 包装：相机/路线/标注/手势
│   ├── NavModel.swift          # 状态机：定位→相机→路线→导航进度
│   ├── LocationEngine.swift    # CoreLocation 采集（回调式）
│   ├── RouteEngine.swift       # MKDirections 规划 + 折线进度计算
│   ├── SearchPanel.swift       # 目的地搜索面板 + 补全
│   ├── NavHUDView.swift        # 导航指引 / 实时数据卡
│   ├── Theme.swift             # 配色与格式化
│   ├── Info.plist
│   └── Assets.xcassets
├── NavNative.xcodeproj
├── build_ipa.sh                # 本地出未签名 IPA
└── .github/workflows/build-ipa.yml
```

## 打包

### 方式一：GitHub Actions（不用 Mac）

推送到 GitHub 后，Actions 自动编译，在运行详情页下载 `NavNative-unsigned-ipa` 压缩包，解压得到 `NavNative-unsigned.ipa`。

若 `github.com` 打不开但 `api.github.com` 可达：

```powershell
$env:GITHUB_TOKEN = "ghp_xxx"
python tools/push_via_api.py --repo navnative --public --watch
```

脚本会建仓、上传、触发构建、等完成后把产物下载到 `dist/`。

### 方式二：本机 Mac

```bash
./build_ipa.sh
# 产物：build/NavNative-unsigned.ipa
# 需要换 Bundle ID：BUNDLE_ID=com.yourname.nav ./build_ipa.sh
```

## 安装

1. 打开全能签 → 导入 `NavNative-unsigned.ipa`
2. 选择证书签名 → 安装
3. 首次启动允许「使用 App 期间」定位
4. 若提示不受信任，去 设置 → 通用 → VPN 与设备管理 里信任描述文件

## 已知限制

- **无实时路况**：`MKDirections` 不返回路况着色，路线时间是不堵车的估算值
- **无语音播报**：未接 `AVSpeechSynthesizer`，只做视觉指引
- **限中国大陆可用性**：Apple 地图国内数据由高德提供，道路/POI 覆盖正常；海外地区同样可用但数据源不同
- **后台不持续定位**：未申请 `location` 后台模式，切到后台导航会暂停，回到前台自动恢复
- **步进单调**：转向判定只在当前 step 与后两步之间前进，掉头绕路时可能短暂停在旧指令
