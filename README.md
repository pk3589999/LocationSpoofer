# LocationSpoofer — 全局虚拟定位插件（iOS 15–17 / rootless）

给已越狱（Dopamine / palera1n rootless）的 iPhone 用的定位伪装插件。
装好后所有读取定位的 App（地图、微信、高德、打卡类）都会拿到你设定的坐标。

> 普通 App 无法修改系统定位，这是 iOS 沙盒决定的。能改的只有注入系统的越狱插件，所以本项目是 tweak 而不是 App。

## 一、为什么不用 Xcode 直接编译

Theos 编译链只支持 macOS / Linux。Windows 上用 **GitHub Actions 云端编译**最省事：
把本项目推到 GitHub，Actions 自动编译出 `.deb`，你下载装到手机上即可。全程不装任何开发环境。

## 二、编译（5 分钟，全自动）

1. 打开 https://github.com/new 新建仓库（私有也行），名称随意，如 `LocationSpoofer`
2. 把本目录所有文件上传（网页拖拽即可，注意 `.github/workflows/build.yml` 也要传）
3. 推送后自动开始编译，打开仓库的 **Actions** 标签页看进度（约 3–5 分钟）
4. 编译成功 → 点进这次运行 → 页面底部 **Artifacts** → 下载 `LocationSpoofer-deb`
5. 解压得到 `com.pkwb.locationspoofer_1.0.0_iphoneos-arm64.deb`

## 三、安装到手机

**方式 A：Filza（推荐，手机内完成）**
1. 把 .deb 传到手机（微信/QQ 发给自己 → 用 Filza 打开）
2. Filza 里点这个 .deb → 右上角 **安装**
3. 装完点 **Respring**（或重启手机后打开 Dopamine 重新越狱）

**方式 B：Sileo 本地安装**
Sileo → 源 → 右上 + → 添加本地文件（部分版本支持）；或先装 `Filza` 用方式 A。

**方式 C：命令行（装了 OpenSSH 的话）**
```bash
scp com.pkwb.locationspoofer_1.0.0_iphoneos-arm64.deb root@<手机IP>:/var/mobile/
ssh root@<手机IP> "dpkg -i /var/mobile/com.pkwb.locationspoofer_1.0.0_iphoneos-arm64.deb; killall -9 SpringBoard"
```

## 四、配置坐标（不用重新编译）

插件每次启动会读这个文件：

```
/var/mobile/Library/Preferences/com.pkwb.locationspoofer.plist
```

把项目里的 `com.pkwb.locationspoofer.plist` 用 Filza 复制到上面这个路径，然后改内容：

```xml
<key>SpoofEnabled</key><true/>      <!-- false 即关闭伪装 -->
<key>Latitude</key><real>39.908722</real>
<key>Longitude</key><real>116.397499</real>
```

改完不需要重装，**重新打开目标 App 即可生效**（插件每 2 秒重读一次配置）。

坐标怎么查：高德/百度地图长按地图上的点 → 复制坐标（注意用 **WGS84 或 GCJ02 就近取值**，误差在几十米内肉眼无差别）。

## 五、验证是否生效

1. 配置好 plist，`SpoofEnabled` 设为 true
2. 打开「地图」App，点右下角定位按钮 → 蓝点应该出现在你设定的位置
3. 打开「查找」→ 自己的位置也会变（说明是系统级覆盖）

## 六、实现原理

| Hook 目标 | 作用 |
|---|---|
| `-[CLLocationManager location]` | 直接返回伪造的 CLLocation 对象 |
| `-[CLLocationManager startUpdatingLocation]` / `requestLocation` | 主动向 delegate 推一条假定位回调 |
| `-[CLLocation coordinate]` | 全局拦截，覆盖所有第三方 SDK 自己 new 出来的 CLLocation |
| `altitude` / `speed` / `course` | 一并伪造，避免"高度异常/速度 999"被风控识别 |
| `horizontalAccuracy` / `verticalAccuracy` | 返回正值，否则 SDK 判为无效定位直接丢弃（v1.1.0） |
| `timestamp` | 保证新鲜，否则被判定位过期（v1.1.0） |
| `CLSourceInformation.isSimulatedBySoftware` / `isProducedByAccessory` | 强制返回 `NO`，屏蔽系统级的"模拟定位"标记（v1.1.0） |

## 七、打卡类 App 报「检测到虚拟定位」怎么办

这是 v1.0.0 的已知问题，v1.1.0 已修。钉钉/企微这类 App 判断虚拟定位，**不只看坐标**：

| 检测点 | v1.0.0 的毛病 | v1.1.0 的修法 |
|---|---|---|
| `sourceInformation.isSimulatedBySoftware` | 没处理；用 DVT 模拟定位时系统把它置为 `true`，直接被抓 | 把该 getter 全局改为 `NO`（找不到类时降级为 `sourceInformation` 返回 nil） |
| `isProducedByAccessory` | 没处理 | 同上，一并改为 `NO` |
| `horizontalAccuracy` | `initWithLatitude:longitude:` 造出来的位置精度是 **-1**，SDK 判为无效定位并丢弃 | 改用带 accuracy 的初始化方法，固定返回 5 米 |
| `timestamp` | 假位置是全局单例，时间戳停在插件加载那一刻，被判「定位过期」 | 每次取用都返回新鲜时间戳，超过 5 秒自动刷新 |
| 坐标恒定不变 | 永远同一个点，是最明显的假特征 | 每 2 米内随机漂移，模仿真实 GPS 静止漂移 |

### 关键原则：别用系统级模拟定位

- ❌ **DVT 模拟定位**（`set-location.bat`）—— 系统层会打上 `isSimulatedBySoftware = true`，这是钉钉最主要的判据，改坐标也躲不掉
- ❌ **LocSim / 同类 locationd 注入**—— 原理相同，标记同样会被置位
- ✅ **只用本插件（进程内 hook）**—— 系统交上来的是真实定位（标记干净），插件只在 App 读坐标时替换数值，对 App 而言这就是一次正常 GPS 定位

所以正确姿势是：**先 `clear-location.bat` 清掉系统模拟定位，再只依赖插件**。

### 另外两个容易被忽略的点

1. **开发者模式**：DVT 模拟定位要求「设置 → 隐私与安全性 → 开发者模式」开启。该模式开启时部分风控会加分，不需要调试时建议关掉（关了会重启一次）
2. **考勤规则本身**：如果公司考勤要求连公司 WiFi（BSSID 校验）或蓝牙信标，改 GPS 一定失败——这种必须在规则层面，不在地理位置层面
3. **打卡前先验位**：打开「地图」看蓝点是否在目标点，蓝点不对就是插件没生效，别急着点打卡

## 八、风险与边界

- **重启后失效**：越狱本身重启就失效，重新越狱后插件自动生效（配置还在）
- **部分 App 有反作弊**：金融、打卡、游戏类可能检测模拟定位（速度恒定、海拔不合理、坐标在室内等），本项目已把 speed 设为 0、altitude 固定 50，但不保证绕过所有检测
- **系统 App 可能异常**：极端坐标（如海上）会让天气、日落时间显示错乱，正常现象
- **仅供学习与开发测试**：用于考勤作弊、位置欺诈等用途可能违反平台协议或劳动纪律，后果自负
- **卸载**：Sileo/Filza 里卸载 `LocationSpoofer` → Respring 即完全恢复，无残留

## 九、比它更省事的选择

如果你不想编译：
- **Horythia**（Havoc 源，$4.99，iOS 15–26 明确支持）——按 App 伪装，还带隐藏越狱功能
- **Relocate Reborn**（`repo.nepeta.me`，免费）——但没适配 iOS 17，可能无效

自己编译的好处：免费、源码可控、坐标随便改、不依赖任何第三方仓库。
