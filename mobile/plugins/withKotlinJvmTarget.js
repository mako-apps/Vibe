const { withProjectBuildGradle } = require("expo/config-plugins");

/**
 * Forces all subprojects to use JVM target 17 for Kotlin compilation,
 * fixing inconsistency between Java (17) and Kotlin (11) in plugins
 * like expo-dynamic-app-icon.
 */
const withKotlinJvmTarget = (config) => {
  return withProjectBuildGradle(config, (config) => {
    if (config.modResults.language === "groovy") {
      // Insert into the existing allprojects block instead of appending
      const target = "allprojects {";
      const replacement = `allprojects {
    tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile).configureEach {
        kotlinOptions {
            jvmTarget = "17"
        }
    }`;
      if (
        config.modResults.contents.includes(target) &&
        !config.modResults.contents.includes("KotlinCompile")
      ) {
        config.modResults.contents = config.modResults.contents.replace(
          target,
          replacement
        );
      }
    }
    return config;
  });
};

module.exports = withKotlinJvmTarget;
