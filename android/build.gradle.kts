allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    // Must be registered before evaluationDependsOn(":app") below forces :app
    // to evaluate immediately, otherwise registration would be too late.
    afterEvaluate {
        if (!plugins.hasPlugin("com.android.library")) return@afterEvaluate
        val android = extensions.getByName("android")
        val methods = android.javaClass.methods
        // Legacy pub plugins (e.g. flutter_media_metadata) neither declare a
        // namespace nor keep pace with modern compileSdk requirements.
        val getNamespace = methods.firstOrNull { it.name == "getNamespace" }
            ?: return@afterEvaluate
        if (getNamespace.invoke(android) == null) {
            val manifest = file("src/main/AndroidManifest.xml")
            if (manifest.isFile) {
                val document =
                    javax.xml.parsers.DocumentBuilderFactory.newInstance()
                        .newDocumentBuilder()
                        .parse(manifest)
                val packageName = document.documentElement.getAttribute("package")
                if (packageName.isNotBlank()) {
                    methods
                        .firstOrNull {
                            it.name == "setNamespace" &&
                                it.parameterTypes.contentEquals(arrayOf(String::class.java))
                        }
                        ?.invoke(android, packageName)
                }
            }
        }
        val appCompileSdk =
            rootProject.project(":app").extensions.getByName("android")
                .let { ext ->
                    ext.javaClass.methods
                        .firstOrNull { it.name == "getCompileSdk" }
                        ?.invoke(ext) as? Int
                } ?: 34
        val getCompileSdk =
            methods.firstOrNull { it.name == "getCompileSdk" } ?: return@afterEvaluate
        if ((getCompileSdk.invoke(android) as? Int ?: 0) < appCompileSdk) {
            methods
                .firstOrNull {
                    it.name == "setCompileSdk" &&
                        it.parameterTypes.firstOrNull() == Integer.TYPE
                }
                ?.invoke(android, appCompileSdk)
        }
    }
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
