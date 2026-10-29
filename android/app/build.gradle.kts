plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val routingAssetsDirectory = layout.buildDirectory.dir("generated/routing-assets")
val routingAssets = tasks.register<Sync>("prepareRoutingAssets") {
    from("../../routing") { include("default-rules.json") }
    into(routingAssetsDirectory)
}
tasks.named("preBuild") { dependsOn(routingAssets) }

android {
    namespace = "app.wayveil"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.chromvoid.wayveil"
        minSdk = 29
        targetSdk = 36
        versionCode = 6
        versionName = "0.1.1"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }
    buildFeatures { compose = true; buildConfig = true }
    sourceSets.getByName("main").assets.srcDir(routingAssetsDirectory.get().asFile)
    testOptions.unitTests.all {
        it.systemProperty("routingTestdataDir", file("../../routing/testdata").absolutePath)
        it.systemProperty("routingDefaultRulesFile", file("../../routing/default-rules.json").absolutePath)
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildTypes {
        getByName("release") {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}
kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}
dependencies {
    implementation(files("libs/wayveilcore.aar"))
    implementation("androidx.core:core-ktx:1.18.0")
    implementation("androidx.activity:activity-compose:1.12.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation(platform("androidx.compose:compose-bom:2026.06.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    testImplementation("junit:junit:4.13.2")
}
