// vendor/chaquopy — Chaquopy 17.2.0 Gradle 插件（webhtv API 23 适配版）。
// 源码取自上游 chaquo/chaquopy tag 17.2.0 的 product/gradle-plugin/build.gradle.kts。
// 与上游的差异（详见 ../README.md）：
//   1) 剥离了 testPython / testIntegration 等开发期测试任务（依赖 src/test 与
//      :runtime 项目，本 vendor 不需要，且 testIntegration 在配置期读取
//      ANDROID_HOME/local.properties，在 composite build 下会误读本目录而崩溃）；
//   2) 移除了随测试任务一起失效的 import（BuildCommon / osName）。
// 本 vendor 只构建 Gradle 插件；runtime / target 产物仍从 Maven Central 解析。
import com.chaquo.python.internal.Common

plugins {
    `java-gradle-plugin`
    `kotlin-dsl`
}

group = "com.chaquo.python"

gradlePlugin {
    plugins {
        create("gradle") {
            id = "com.chaquo.python"
            implementationClass = "com.chaquo.python.PythonPlugin"

            // For these fields, the `pom` block in the root build.gradle doesn't have
            // any effect on the plugin marker artifact.
            displayName = "Chaquopy"
            description = "The Python SDK for Android"
        }
    }
}

dependencies {
    // gradleApi() (for the API of Gradle itself) is added automatically by
    // java-gradle-plugin.
    //
    // gradle-api is the API of the Android Gradle plugin. If we made it an
    // `implementation` dependency, and the user selected an AGP version that was too
    // old, then Gradle would use the MIN_AGP_VERSION of gradle-api along with the
    // older version of the AGP, and the build would fail with an incomprehensible
    // error message before even getting as far as our own AGP version check.
    compileOnly("com.android.tools.build:gradle-api:${Common.MIN_AGP_VERSION}")

    implementation("org.apache.commons:commons-compress:1.18")
    implementation("org.json:json:20160810")
}

java {
    sourceCompatibility = JavaVersion.VERSION_11
}

sourceSets.main {
    java.srcDir("../buildSrc/src/main/java")
}

tasks.register<Zip>("zipBuildPackages") {
    destinationDirectory.set(file("$buildDir/tmp/$name"))
    archiveFileName.set("build-packages.zip")
    from("src/main/python")
    exclude("**/*.pyc")
}

tasks.processResources {
    doFirst { delete(destinationDir) }
    into("com/chaquo/python") {
        from(tasks.named("zipBuildPackages"))
    }
}
