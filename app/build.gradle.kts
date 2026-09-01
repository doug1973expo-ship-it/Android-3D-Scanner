plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "uk.co.pocket3d.scanner"
    compileSdk = 35
    defaultConfig {
        applicationId = "uk.co.pocket3d.scanner.edge20"
        minSdk = 26
        targetSdk = 33
        versionCode = 5
        versionName = "1.4"
    }
    buildFeatures { viewBinding = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}
dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("com.google.ar:core:1.48.0")
}
