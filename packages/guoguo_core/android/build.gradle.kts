group = "com.maxduke.guoguo_core"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

// Android libraries cannot bundle a direct local AAR dependency. The generated
// gomobile archive owns only its Java bridge and JNI libraries; include both in
// this plugin so the consuming app receives the complete native core.
val coreAar = layout.projectDirectory.file("libs/guoguo.aar")
val coreOutput = layout.buildDirectory.dir("generated/guoguo-core")
val unpackCore = tasks.register<Sync>("unpackGuoguoCore") {
    from(zipTree(coreAar))
    include("classes.jar", "jni/**", "proguard.txt")
    into(coreOutput)
}

android {
    namespace = "com.maxduke.guoguo_core"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
            jniLibs.srcDir(coreOutput.get().dir("jni").asFile)
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
        consumerProguardFiles(coreOutput.get().file("proguard.txt").asFile)
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation(files(coreOutput.map { it.file("classes.jar") }).builtBy(unpackCore))
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}

tasks.named("preBuild") { dependsOn(unpackCore) }
tasks.matching { it.name.endsWith("ConsumerProguardFiles") }.configureEach {
    dependsOn(unpackCore)
}
