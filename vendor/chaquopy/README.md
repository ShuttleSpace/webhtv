# vendor/chaquopy — Chaquopy 17.2.0 本地化（API 23 适配）

本目录是 [chaquo/chaquopy](https://github.com/chaquo/chaquopy) tag **17.2.0** 的
**Gradle 插件模块**源码副本，带两处 API 23 适配补丁，通过 Gradle composite build
（`includeBuild` + 依赖替换）被 webhtv 直接使用。不再需要 fork 到 GitHub、
`publishToMavenLocal` 或对 `~/.gradle/caches` 里的插件 jar 打字节码补丁。

## 为什么需要它

webhtv 为了在 Android 6.0 (API 23) 上安装运行，把 `minSdk` 降到了 23，而
Chaquopy 17 有两处硬编码下限 24：

1. **配置期守卫** `PythonPlugin.onVariant()`：`minSdk < Common.MIN_SDK_VERSION` 直接
   `GradleException`（"This version of Chaquopy requires minSdk version 24 or higher"）。
2. **构建期 wheel 平台标签**：插件把项目 minSdk 作为 `--min-api-level` 传给
   `chaquopy.pip_install`，`platform_tag()` 生成 `android_<minSdk>_<abi>`；而 Chaquopy
   pypi 镜像里 Python >= 3.10 的 wheel 全部标记为 `android_24_*`，minSdk=23 时 pip
   报 "from versions: none"（lxml / ujson / pycryptodome 等装不上）。

此外还有第三处与本项目无关、但同样挡住构建的**上游与 Gradle 9.5.1 的不兼容**
（见下表第 3 条）：Gradle 9.5.1 给 `TaskContainer.register` 新增了
`(String, Class<T>, Object...)` 构造参数重载，而上游用 Kotlin 写的
`tasks.register(name, cls, configure)`（lambda 同样是 `Object`）会被解析到该重载，
把 configure lambda 当成任务构造参数传入，任务实例化时抛
`Too many parameters provided for constructor for type TaskBuilder.ProxyTask. Expected 0, received 1`。
**官方发布的 Chaquopy 17.2.0 插件在 Gradle 9.5.1 上同样会失败**，本 vendor 是修掉它的最短路径。

## 补丁清单（相对上游 17.2.0 共 3 处）

| # | 文件 | 改动 | 作用 |
|---|------|------|------|
| 1 | `buildSrc/src/main/java/com/chaquo/python/internal/Common.java` | `MIN_SDK_VERSION = 24` → `23` | 放行 minSdk 23 项目的配置期守卫 |
| 2 | `gradle-plugin/src/main/kotlin/PythonTasks.kt` (约 L239) | `args("--min-api-level", variant.minSdkVersion.apiLevel)` → `args("--min-api-level", Math.max(variant.minSdkVersion.apiLevel, 24))` | min-api-level 下限抬到 24，使 `android_24_*` wheel 被选中 |
| 3 | `gradle-plugin/src/main/kotlin/PythonTasks.kt` (`registerTask`) | `tasks.register(name, cls, configure)` → 显式构造 `Action<T>` 并传 `cls.java` | 绕开 Gradle 9.5.1 新增的 varargs 构造参数重载，修复任务实例化失败 |

前两处补丁与历史上 `scripts/patch_chaquopy_minsdk.sh` 对缓存 jar 的字节码补丁
（`bipush 24` → `bipush 1`；`platform_tag` 取 `max(min_api_level, 24)`）效果等价，
但改在源码层，可读、可 review、随仓库走。第 3 处是上游尚未适配的新问题，
只能靠改源码解决——这正是把 Chaquopy 放进 vendor 的价值。

## 与上游源码的差异（除补丁外）

- 只保留 `gradle-plugin` 插件模块；上游 `product/runtime`、`target/` 未纳入
  （插件在应用构建时从 Maven Central 解析 `com.chaquo.python.runtime:*` 与
  `com.chaquo.python:target`，版本 = 本目录 `VERSION.txt`，即 17.2.0）。
- `gradle-plugin/src/test` 及 `build.gradle.kts` 中的 testPython / testIntegration
  任务已剥离（它们依赖 `:runtime` 项目与 `BuildCommon.androidHome()`，后者在
  composite build 下会误读本目录的 local.properties 导致配置期崩溃）。
- `settings.gradle` 只 `include ':gradle'`（`projectDir = gradle-plugin`）；
  项目名必须保持 `gradle`——`PythonPlugin.findPlugin("com.chaquo.python", "gradle")`
  靠它在 buildscript classpath 里定位插件版本。
- 根 `build.gradle` 中 `VERSION.txt` 路径由仓库根调整为本构建根。
- `PythonTasks.kt` 的 `registerTask()` 改为显式传 `Action<T>`（见补丁清单第 3 条），
  以适配 Gradle 9.5.1 的 `TaskContainer.register` 新重载。

## 消费方式（webhtv 侧，已配置）

`settings.gradle`：

```groovy
includeBuild('vendor/chaquopy') {
    dependencySubstitution {
        substitute module('com.chaquo.python:gradle').using project(':gradle')
    }
}
```

`gradle/libs.versions.toml`：`python = "17.2.0"`（与 vendor 版本一致；替换后版本号
仅用于定位 Central 上的插件 marker POM，实际插件代码来自本目录）。

构建：`just android6-build`（默认 leanback arm64 Release）。

## 升级 / 重新同步上游

```bash
git -C /tmp clone --depth 1 --branch <新tag> https://github.com/chaquo/chaquopy.git
# 按上方“补丁清单”重新应用两处改动（或从本目录 diff 取补丁）
rsync -a --exclude src/test /tmp/chaquopy/product/gradle-plugin/ vendor/chaquopy/gradle-plugin/
cp /tmp/chaquopy/product/buildSrc/src/main/java/com/chaquo/python/internal/Common.java \
   vendor/chaquopy/buildSrc/src/main/java/com/chaquo/python/internal/
cp /tmp/chaquopy/product/gradle.properties vendor/chaquopy/gradle.properties
printf '<新tag>\n' > vendor/chaquopy/VERSION.txt
# 同步 libs.versions.toml 的 python 版本，重新构建验证
```

## 已知边界

- runtime / target 产物（含原生 `.so`）仍使用 Central 上按 API 24 构建的官方发布件；
  API 23 上的实际可用性需真机验证：运行时调用一次 Python（如 Python Spider），
  确认 `PyLoader.isAvailable()` 为 true 且无 `UnsatisfiedLinkError`。
- 若未来需要在 runtime 层打补丁（而非仅插件层），需把 `product/runtime` 也纳入
  vendor 并本地构建——那会引入 NDK 原生构建，成本高得多，暂不需要。
