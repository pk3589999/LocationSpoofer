#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <math.h>

// ============================================================
// LocationSpoofer v1.3.0 - 全局虚拟定位插件（rootless / ElleKit）
// 配置文件: /var/mobile/Library/Preferences/com.pkwb.locationspoofer.plist
//
// v1.3.0: 钉钉仍报「虚拟位置」的针对性加固
//   1. -[CLLocation sourceInformation] 无条件返回 nil（v1.2.0 只在
//      找不到 CLSourceInformation 类时才走这条兜底；实测 iOS 17 上
//      类存在但名字可能对不上，导致 flag patch 没挂上）
//   2. 同一个 CLLocation 对象的 coordinate 做缓存（associated object）：
//      同一对象反复读取返回同一坐标——此前每次读取都重新抖动，
//      风控只要读两次发现坐标变了，就等于自报家门"我被 hook 了"
//   3. horizontalAccuracy 不再恒为 5.0（真 GPS 不会永远正好 5 米），
//      每次 8~14 米随机；altitude 35~50、verticalAccuracy 6~12 同理
//
// v1.2.0: 默认坐标改为钉钉考勤点（中国电信(安徽)大数据产业园，
//         GCJ-02 坐标 31.868904,117.116694 —— iOS 在国内 CoreLocation
//         输出的就是 GCJ-02，之前填 WGS84 导致显示偏移 574 米）
//
// v1.1.2 修复「注入成功但完全不生效」：
//   LSLoadPrefs 在无配置文件时会把 gEnabled 判成 NO（旧逻辑
//   gEnabled = (en == kCFBooleanTrue)，en 为 NULL 即关闭），
//   导致 hook 全部放行。现改为无配置时默认开启。
//
// v1.1.1 修复「装完进安全模式」：
//   1. %ctor 检测进程，SpringBoard / backboardd 等系统进程直接跳过，
//      不再对系统进程执行任何 hook（v1.1.0 全局注入 UIKit 导致
//      SpringBoard 加载插件时崩溃进入安全模式）
//   2. 删除主动推送 CLHeading 的逻辑 —— 手工 alloc 的 CLHeading 内部
//      字段不完整，SpringBoard 的罗盘/方向相关组件读取后崩溃
//   3. didUpdateLocations 主动推送加 @try 保护
//   4. 显式 %init，确保 hook 只在普通 App 进程中生效
//
// v1.1.0 修复「钉钉/打卡类 App 提示检测到虚拟定位」：
//   1. 伪造位置的 accuracy 不再为 -1（负数会被 SDK 判为无效定位直接丢弃）
//   2. 时间戳保证新鲜（旧版是全局单例，timestamp 停在创建那一刻，被判"定位过期"）
//   3. 屏蔽 isSimulatedBySoftware / isProducedByAccessory 两个模拟标记
//   4. 加入 ±2 米随机漂移，避免"坐标恒定不变"被风控当成假位置
// ============================================================

#define kPrefsDomain CFSTR("com.pkwb.locationspoofer")
#define kPrefsPath   @"/var/mobile/Library/Preferences/com.pkwb.locationspoofer.plist"

static BOOL     gEnabled = YES;             // 默认开启
static double   gLat     = 31.868904;       // 合肥·中国电信(安徽)大数据产业园 考勤点（GCJ-02，iOS 国内定位坐标系）
static double   gLon     = 117.116694;
static double   gJitter  = 2.0;             // 随机漂移半径（米），0 = 关闭
static CFAbsoluteTime gLastLoad = 0;

#pragma mark - 配置读取

static void LSLoadPrefs(BOOL force) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!force && (now - gLastLoad) < 2.0) return;
    gLastLoad = now;

    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    if (dict) {
        gEnabled = [dict[@"SpoofEnabled"] boolValue];
        if (dict[@"Latitude"])     gLat    = [dict[@"Latitude"] doubleValue];
        if (dict[@"Longitude"])    gLon    = [dict[@"Longitude"] doubleValue];
        if (dict[@"JitterMeters"]) gJitter = [dict[@"JitterMeters"] doubleValue];
    } else {
        // v1.1.2 关键修复：从未写入过配置时（en == NULL）必须默认开启！
        // 旧逻辑 gEnabled = (en == kCFBooleanTrue) 会把"无配置"判成关闭，
        // 导致插件注入成功但开关为 0，所有 hook 全部放行——等于没装。
        CFPropertyListRef en = CFPreferencesCopyAppValue(CFSTR("SpoofEnabled"), kPrefsDomain);
        if (en == NULL) {
            gEnabled = YES;   // 无配置 → 默认开启，用内置坐标
        } else {
            gEnabled = (en == kCFBooleanTrue);
            CFRelease(en);
        }

        CFPropertyListRef la = CFPreferencesCopyAppValue(CFSTR("Latitude"), kPrefsDomain);
        if (la) { gLat = [(__bridge NSNumber *)la doubleValue]; CFRelease(la); }

        CFPropertyListRef lo = CFPreferencesCopyAppValue(CFSTR("Longitude"), kPrefsDomain);
        if (lo) { gLon = [(__bridge NSNumber *)lo doubleValue]; CFRelease(lo); }
    }

    // 坐标非法时回退默认值，避免把系统搞崩
    if (gLat < -90.0 || gLat > 90.0)     gLat    = 31.868904;
    if (gLon < -180.0 || gLon > 180.0)   gLon    = 117.116694;
    if (gJitter < 0.0 || gJitter > 50.0) gJitter = 2.0;
}

#pragma mark - 伪造坐标

// 在目标点周围生成 ±gJitter 米的随机偏移。
// 真实 GPS 静止时本就有 1~5 米漂移，坐标恒定不变反而是最明显的假特征。
static CLLocationCoordinate2D LSCurrentCoord(void) {
    double dLat = 0.0, dLon = 0.0;
    if (gJitter > 0.0) {
        double r1 = ((double)arc4random_uniform(20001) / 10000.0) - 1.0;  // -1 ~ 1
        double r2 = ((double)arc4random_uniform(20001) / 10000.0) - 1.0;
        dLat = (r1 * gJitter) / 111320.0;
        double cosLat = cos(gLat * M_PI / 180.0);
        dLon = (r2 * gJitter) / (111320.0 * (cosLat < 0.01 ? 0.01 : cosLat));
    }
    CLLocationCoordinate2D c;
    c.latitude  = gLat + dLat;
    c.longitude = gLon + dLon;
    return c;
}

// 构造"合法"的 CLLocation：精度为正、时间戳为当下。
// 关键：绝不能用 initWithLatitude:longitude:，那样 accuracy 是 -1，大量 SDK 会直接丢弃。
// v1.3.0: 精度/海拔/垂直精度都加随机——真实 GPS 每次采样都会变，
//         恒定 5.0m / 42m / 8m 是教科书级的伪造特征。
static CLLocation *LSMakeLocation(void) {
    double ha = 8.0 + (arc4random_uniform(700) / 100.0);   // 8.00 ~ 14.99
    double va = 6.0 + (arc4random_uniform(700) / 100.0);   // 6.00 ~ 12.99
    double al = 35.0 + (arc4random_uniform(1500) / 100.0); // 35.00 ~ 49.99
    return [[CLLocation alloc] initWithCoordinate:LSCurrentCoord()
                                         altitude:al
                               horizontalAccuracy:ha
                                 verticalAccuracy:va
                                        timestamp:[NSDate date]];
}

static void LSPushToDelegate(CLLocationManager *manager) {
    id delegate = manager.delegate;
    if (!delegate) return;
    if (![delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) return;
    CLLocation *loc = LSMakeLocation();
    if (!loc) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            [delegate locationManager:manager didUpdateLocations:@[loc]];
        } @catch (NSException *e) {
            NSLog(@"[LocationSpoofer] push exception: %@", e);
        }
    });
}

#pragma mark - CLLocation

// v1.3.0 关键加固：每个 CLLocation 对象首次被读取时生成一套固定值并缓存。
// 此前 coordinate 每次读取都重新抖动——同一个 CLLocation 对象读两次坐标不一样，
// 风控只要对比一下就能确定"坐标被运行时篡改"，这是比 isSimulatedBySoftware
// 更隐蔽也更致命的检测点。
static char kLSFakeKey;

static NSDictionary *LSFakeFor(id obj) {
    NSDictionary *fake = objc_getAssociatedObject(obj, &kLSFakeKey);
    if (!fake) {
        CLLocationCoordinate2D c = LSCurrentCoord();
        double ha = 8.0 + (arc4random_uniform(700) / 100.0);   // 8.00 ~ 14.99
        double va = 6.0 + (arc4random_uniform(700) / 100.0);   // 6.00 ~ 12.99
        double al = 35.0 + (arc4random_uniform(1500) / 100.0); // 35.00 ~ 49.99
        fake = @{ @"lat": @(c.latitude), @"lon": @(c.longitude),
                  @"ha": @(ha), @"va": @(va), @"al": @(al) };
        objc_setAssociatedObject(obj, &kLSFakeKey, fake, OBJC_ASSOCIATION_RETAIN);
    }
    return fake;
}

%hook CLLocation

- (CLLocationCoordinate2D)coordinate {
    LSLoadPrefs(NO);
    if (!gEnabled) return %orig;
    NSDictionary *f = LSFakeFor(self);
    CLLocationCoordinate2D c;
    c.latitude  = [f[@"lat"] doubleValue];
    c.longitude = [f[@"lon"] doubleValue];
    return c;
}

- (CLLocationDegrees)altitude {
    LSLoadPrefs(NO);
    if (!gEnabled) return %orig;
    return [LSFakeFor(self)[@"al"] doubleValue];
}

- (CLLocationSpeed)speed {
    LSLoadPrefs(NO);
    if (gEnabled) return 0.0;
    return %orig;
}

- (CLLocationDirection)course {
    LSLoadPrefs(NO);
    if (gEnabled) return -1.0;
    return %orig;
}

// 精度必须为正：-1 在 CoreLocation 语义里表示"无效位置"，高德/钉钉等 SDK 会丢弃
- (CLLocationAccuracy)horizontalAccuracy {
    LSLoadPrefs(NO);
    if (!gEnabled) return %orig;
    return [LSFakeFor(self)[@"ha"] doubleValue];
}

- (CLLocationAccuracy)verticalAccuracy {
    LSLoadPrefs(NO);
    if (!gEnabled) return %orig;
    return [LSFakeFor(self)[@"va"] doubleValue];
}

// 定位过期判定：SDK 一般把超过 5~10 秒的定位视为不可用
- (NSDate *)timestamp {
    LSLoadPrefs(NO);
    if (gEnabled) {
        NSDate *t = %orig;
        if (!t || [t timeIntervalSinceNow] < -5.0) return [NSDate date];
    }
    return %orig;
}

%end

#pragma mark - CLLocationManager

%hook CLLocationManager

- (CLLocation *)location {
    LSLoadPrefs(NO);
    if (!gEnabled) return %orig;
    CLLocation *fake = LSMakeLocation();
    return fake ?: %orig;
}

- (void)startUpdatingLocation {
    %orig;
    LSLoadPrefs(YES);
    if (gEnabled) LSPushToDelegate(self);
}

- (void)requestLocation {
    %orig;
    LSLoadPrefs(YES);
    if (gEnabled) LSPushToDelegate(self);
}

%end

#pragma mark - 模拟定位标记屏蔽（v1.1.0 新增，钉钉检测的核心）

// iOS 15 起 CLLocation 带 sourceInformation，其中：
//   isSimulatedBySoftware -> 走 DVT / 系统模拟定位时被置 true，钉钉据此报"检测到虚拟定位"
//   isProducedByAccessory -> 外接设备注入时为 true
// 把这两个 getter 全局改成 NO，让任何读到它们的 App/SDK 都认为这是真实 GPS 定位。
static BOOL LSReturnNO(id self, SEL _cmd) { return NO; }
static id   LSReturnNil(id self, SEL _cmd) { return nil; }

static void LSPatchSourceInformation(void) {
    // 1) flag patch：类存在就改，让 isSimulatedBySoftware / isProducedByAccessory 恒为 NO
    NSArray<NSString *> *classNames = @[@"CLSourceInformation",
                                        @"CLLocationSourceInformation",
                                        @"CLCLLocationSourceInformation"];
    NSArray<NSString *> *selectors  = @[@"isSimulatedBySoftware",
                                        @"isProducedByAccessory"];
    BOOL patched = NO;
    for (NSString *clsName in classNames) {
        Class cls = objc_getClass(clsName.UTF8String);
        if (!cls) continue;
        for (NSString *selName in selectors) {
            Method m = class_getInstanceMethod(cls, NSSelectorFromString(selName));
            if (m) {
                method_setImplementation(m, (IMP)LSReturnNO);
                patched = YES;
                NSLog(@"[LocationSpoofer] patched %@ -%@", clsName, selName);
            }
        }
    }
    if (!patched) NSLog(@"[LocationSpoofer] WARN: no SourceInformation class found");

    // 2) v1.3.0：无条件让 -[CLLocation sourceInformation] 返回 nil（之前只在
    //    flag 类没找到时才走兜底）。nil 消息等价 NO，且钉钉连 SourceInformation
    //    对象本身都拿不到，"对象存在但标志为假"这一层检查根本不成立。
    Method m = class_getInstanceMethod(objc_getClass("CLLocation"),
                                       @selector(sourceInformation));
    if (m) {
        method_setImplementation(m, (IMP)LSReturnNil);
        NSLog(@"[LocationSpoofer] sourceInformation -> nil (unconditional)");
    }
}

#pragma mark - 入口

%ctor {
    @autoreleasepool {
        // v1.1.1: 系统核心进程一律跳过，绝不 hook。
        // SpringBoard / backboardd 被注入后加载期崩溃会直接把手机打入安全模式。
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if ([bid isEqualToString:@"com.apple.springboard"] ||
            [bid hasPrefix:@"com.apple.backboardd"] ||
            [bid isEqualToString:@"com.apple.frontrow"]) {
            NSLog(@"[LocationSpoofer] v1.1.1 skip system process: %@", bid);
            return;
        }

        // 显式 %init：保证上面 return 之前没有任何 hook 被安装
        %init;

        LSLoadPrefs(YES);
        LSPatchSourceInformation();
        NSLog(@"[LocationSpoofer] v1.3.0 loaded, enabled=%d lat=%.6f lon=%.6f jitter=%.1fm",
              gEnabled, gLat, gLon, gJitter);
    }
}
