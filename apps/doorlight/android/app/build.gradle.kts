import java.security.MessageDigest
import java.util.Base64
import java.net.URI

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services") apply false
}

val firebaseConfig = file("google-services.json")
if (firebaseConfig.isFile) pluginManager.apply("com.google.gms.google-services")
val emulatorX86 = System.getenv("SYBL_EMULATOR_X86_64") == "1"
val nativeAbi = if (emulatorX86) "x86_64" else "arm64-v8a"

// Flutter passes these same compile-time values to Dart and Gradle. No generic
// HTTPS filter is registered when an owned origin/certificate is unconfigured.
val doorlightDefines = (project.findProperty("dart-defines") as? String).orEmpty()
    .split(',').filter { it.isNotEmpty() }.map {
        String(Base64.getDecoder().decode(it), Charsets.UTF_8)
    }.associate { val parts = it.split('=', limit = 2); parts[0] to parts.getOrElse(1) { "" } }
val inviteOrigin = doorlightDefines["DOORLIGHT_INVITE_ORIGIN"].orEmpty()
val verifiedAppLinks = doorlightDefines["DOORLIGHT_VERIFIED_APP_LINKS"] == "true"
val inviteHost = if (inviteOrigin.isEmpty()) "" else {
    val origin = URI(inviteOrigin)
    require(origin.scheme == "https" && origin.host != null && origin.rawAuthority == origin.host &&
        origin.port == -1 && origin.rawUserInfo == null && origin.rawQuery == null && origin.rawFragment == null &&
        origin.rawPath.isEmpty() && origin.host.length <= 253 && origin.host.split('.').all {
            it.length <= 63 && it.matches(Regex("[a-z0-9](?:[a-z0-9-]*[a-z0-9])?"))
        }) { "DOORLIGHT_INVITE_ORIGIN must be a canonical HTTPS origin" }
    origin.host
}
require(!verifiedAppLinks || inviteHost.isNotEmpty()) { "Verified App Links require a configured origin" }
val doorlightManifest = layout.buildDirectory.file("doorlight/AndroidManifest.xml")
val generateDoorlightManifest = tasks.register("generateDoorlightManifest") {
    val base = file("src/main/AndroidManifest.xml")
    inputs.file(base)
    inputs.property("inviteHost", inviteHost)
    inputs.property("verifiedAppLinks", verifiedAppLinks)
    outputs.file(doorlightManifest)
    doLast {
        val marker = "<!-- Doorlight configured App Links -->"
        val source = base.readText()
        check(source.split(marker).size == 2) { "Missing unique Doorlight manifest insertion point" }
        val filter = if (verifiedAppLinks) """
            <intent-filter android:autoVerify="true">
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="https" android:host="$inviteHost" android:pathPrefix="/invite/"/>
            </intent-filter>
        """.trimIndent() else ""
        doorlightManifest.get().asFile.apply { parentFile.mkdirs(); writeText(source.replace(marker, filter)) }
    }
}
tasks.named("preBuild").configure { dependsOn(generateDoorlightManifest) }

android {
    sourceSets.getByName("main").manifest.srcFile(doorlightManifest)
    namespace = "app.sybl.sybl"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "app.sybl.sybl"
        testInstrumentationRunner = "app.sybl.sybl.WireRuntimeTest"
        // libjami's AAudioLayer (the daemon-owned mic/speaker path) needs AAudio = API 26+.
        // Production currently ships arm64 only — that is the only ABI for which this repo has a matching libjami .so.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk { abiFilters += listOf(nativeAbi) }
        buildConfigField("boolean", "SYBL_FIREBASE_CONFIGURED", firebaseConfig.isFile.toString())
        buildConfigField("String", "DOORLIGHT_INVITE_ORIGIN", "\"$inviteOrigin\"")
    }

    buildFeatures { buildConfig = true }

    // The prebuilt libjami .so is large + unstripped — don't let AGP strip it, and dedupe libc++_shared
    // against whatever the Flutter engine bundles.
    packaging {
        jniLibs {
            keepDebugSymbols += "**/$nativeAbi/libjami-core-jni.so"
            pickFirsts += "**/libc++_shared.so"
        }
    }

    lint {
        lintConfig = file("lint.xml")
        // Syb-L ships only the ABI for which this repository has a matching
        // libjami build. Do not imply ChromeOS/x86 support until those native
        // artifacts are built and accepted as a separate compatibility target.
        disable += "ChromeOsAbiSupport"
    }

    buildTypes {
        release {
            // M9-M11 acceptance devices already contain this package under the
            // controlled debug certificate. Keep the signer stable so `adb
            // install -r` preserves their Jami identities and app-private
            // state. This artifact is internal-only; the production-signing
            // unit must use external CI credentials and fail closed when they
            // are absent instead of silently falling back here.
            signingConfig = signingConfigs.getByName("debug")
            // SWIG's JNI_OnLoad registers the complete generated method table by exact Java names/signatures.
            // R8 cannot infer that native reachability and otherwise removes unused overloads from release DEX.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.google.android.gms:play-services-nearby:19.5.1")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("com.google.firebase:firebase-messaging:25.1.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}

// Fail fast if the ignored prebuilt native bundle is missing or differs from the accepted hashes.
// A fresh checkout omits the large bundle; without this guard the build "succeeds" but the app crashes
// at launch in System.loadLibrary("jami-core-jni"). See docs/OPERATIONS.md for the matched native-input boundary.
// These hashes identify accepted inputs; source/JNI reconstruction limits are in docs/OPERATIONS.md.
val acceptedJamiLibs = if (emulatorX86) mapOf(
    "libjami-core-jni.so" to "6683e031bb90d19543a97bbc805da99777d058287d911de226cc3e33fecf1b2e",
    "libc++_shared.so" to "e28cb9e0f456caf8498d0e8562b3ac3f73bf78c07555a52b5602396f240abec3",
) else mapOf(
    "libjami-core-jni.so" to "dd463413a5185bf2e004106e2bf44ba2dc6b86f1d0f53ff84e3c6fba1fbb6f6f",
    "libc++_shared.so" to "0c52cfab2df0d957d8b346a2bdc5ae8d71feca2591924d77e1cd724d5bf74352",
)

tasks.register("checkJamiLib") {
    val nativeDir = file("src/main/jniLibs/$nativeAbi")
    inputs.files(acceptedJamiLibs.keys.map(nativeDir::resolve))
    doLast {
        acceptedJamiLibs.forEach { (name, expected) ->
            val so = nativeDir.resolve(name)
            if (!so.isFile) {
                throw GradleException(
                    "Missing ${so.path}\n" +
                        "Copy the accepted native bundle from <repo>/local/dev/jami-out/jniLibs/arm64-v8a/."
                )
            }
            val digest = MessageDigest.getInstance("SHA-256")
            so.inputStream().use { input ->
                val buffer = ByteArray(1024 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
            if (actual != expected) {
                throw GradleException(
                    "Unaccepted ${so.path}\nExpected SHA-256: $expected\nActual SHA-256:   $actual"
                )
            }
        }
    }
}
tasks.matching { it.name == "preBuild" }.configureEach { dependsOn("checkJamiLib") }
