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
        val getNamespace =
            android.javaClass.methods.firstOrNull { it.name == "getNamespace" }
                ?: return@afterEvaluate
        if (getNamespace.invoke(android) != null) return@afterEvaluate
        val manifest = file("src/main/AndroidManifest.xml")
        if (!manifest.isFile) return@afterEvaluate
        val document =
            javax.xml.parsers.DocumentBuilderFactory.newInstance()
                .newDocumentBuilder()
                .parse(manifest)
        val packageName = document.documentElement.getAttribute("package")
        if (packageName.isBlank()) return@afterEvaluate
        android.javaClass.methods
            .firstOrNull {
                it.name == "setNamespace" &&
                    it.parameterTypes.contentEquals(arrayOf(String::class.java))
            }
            ?.invoke(android, packageName)
    }
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
