//  MTKShaderPlugin.swift
//  MTK
//  Build-tool plugin that compiles shader sources into MTK.metallib.
//  Thales Matheus Mendonça Santos — October 2025

import PackagePlugin
import Foundation

@main
struct MTKShaderPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let swiftTarget = target as? SwiftSourceModuleTarget,
              swiftTarget.name == "MTKCore" else {
            return []
        }
        return try Self.makeCommands(
            packageDir: context.package.directory,
            workDir: context.pluginWorkDirectory
        )
    }
}

private extension MTKShaderPlugin {
    static func makeCommands(packageDir: Path, workDir: Path) throws -> [Command] {
        let script = packageDir.appending(["Tooling", "Shaders", "build_metallib.sh"])
        let shaderDir = packageDir.appending(["Sources", "MTKCore", "Resources", "Shaders"])
        let outputDir = workDir.appending("GeneratedResources")
        let outputFile = outputDir.appending("MTK.metallib")

        guard FileManager.default.isExecutableFile(atPath: script.string) else {
            Diagnostics.warning("MTKShaderPlugin: missing executable script at \(script.string)")
            return []
        }

        guard FileManager.default.fileExists(atPath: shaderDir.string) else {
            Diagnostics.warning("MTKShaderPlugin: shader directory \(shaderDir.string) not found")
            return []
        }

        return [
            .prebuildCommand(
                displayName: "Compile MTK.metallib",
                executable: script,
                arguments: [shaderDir.string, outputFile.string],
                environment: [:],
                outputFilesDirectory: outputDir
            )
        ]
    }
}
