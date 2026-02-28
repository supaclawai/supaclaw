//
//  ContentView.swift
//  MLXSampleApp
//
//  Created by İbrahim Çetin on 28.02.2025.
//

import SwiftUI
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import MLXNN
import PhotosUI

struct ContentView: View {
    init() {
        replacementTokenizers["TokenizersBackend"] = "PreTrainedTokenizer"
        registerMistral3CompatibilityLoader()
        LLMModelFactory.shared.modelRegistry.registerCustomModels()
    }

    private var vm = MLXViewModel(
        modelConfiguration: defaultModelConfiguration
    )

    #if os(iOS)
    private static let defaultModelConfiguration = MLXLLM.ModelRegistry.ministral3_3BInstruct4bit
    #else
    private static let defaultModelConfiguration = MLXLLM.ModelRegistry.mistralNeMoMinitron8BInstruct4bit
    #endif

    @State private var prompt: String = ""
    @State private var selectedImages: [Data] = []

    @State private var showingPhotoPicker: Bool = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var generationTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack {
                ScrollView {
                    if let selectedImage = selectedImages.first, let image = PlatformImage(data: selectedImage) {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 200, alignment: .trailing)
                    }

                    Text(vm.output)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("output_text")
                }

                HStack {
                    Button {
                        showingPhotoPicker = true
                    } label: {
                        Image(systemName: "photo.badge.plus")
                    }

                    TextField("Prompt", text: $prompt)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("prompt_field")

                    if vm.isRunning {
                        Button(action: stopGeneration) {
                            Image(systemName: "stop.fill")
                        }
                        .accessibilityIdentifier("stop_button")
                    } else {
                        Button(action: generate) {
                            Image(systemName: "paperplane.fill")
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(sendButtonDisabled)
                        .accessibilityIdentifier("send_button")
                    }
                }
            }
            .padding()
#if(os(iOS))
            .photosPicker(isPresented: $showingPhotoPicker, selection: $photoSelection)
            .onChange(of: photoSelection, addImage)
#elseif(os(macOS))
            .fileImporter(isPresented: $showingPhotoPicker, allowedContentTypes: [.image], onCompletion: addImage)
#endif

            .toolbar {
                if let progress = vm.downloadProgress, !progress.isFinished {
                    DownloadProgressView(progress: progress)
                }

                Button(action: reset) {
                    TokensPerSecondView(value: vm.tokensPerSecond)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("MLXSampleApp")
#if(os(macOS))
            .navigationSubtitle(vm.modelConfiguration.name)
#endif
        }
    }

    private func generate() {
        generationTask?.cancel()
        generationTask = Task {
            await vm.generate(prompt: prompt, images: selectedImages)
            generationTask = nil
        }
    }

    private func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
    }

#if(os(iOS))
    private func addImage() {
        Task {
            if let data = try? await photoSelection?.loadTransferable(type: Data.self) {
                selectedImages = [data]
            } else {
                selectedImages = []
            }
        }
    }
#elseif(os(macOS))
    private func addImage(_ result: Result<URL, any Error>) {
        if let url = try? result.get(), let data = try? Data(contentsOf: url) {
            selectedImages = [data]
        } else {
            selectedImages = []
        }
    }
#endif

    private func reset() {
        vm.output = ""
        vm.tokensPerSecond = 0

        prompt = ""
        selectedImages = []
    }

    private var sendButtonDisabled: Bool {
        vm.isRunning ||
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        (vm.downloadProgress != nil && !vm.downloadProgress!.isFinished)
    }
}

#Preview {
    ContentView()
}

private enum Mistral3CompatibilityError: LocalizedError {
    case missingTextConfig

    var errorDescription: String? {
        switch self {
        case .missingTextConfig:
            return "mistral3 config.json is missing text_config"
        }
    }
}

private final class Mistral3TextLlamaWrapper: Module, LLMModel, KVCacheDimensionProvider {
    @ModuleInfo(key: "language_model") var languageModel: LlamaModel

    init(_ languageModel: LlamaModel) {
        self._languageModel.wrappedValue = languageModel
    }

    var kvHeads: [Int] {
        languageModel.kvHeads
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        languageModel(inputs, cache: cache)
    }

    func loraLinearLayers() -> LoRALinearLayers {
        languageModel.loraLinearLayers()
    }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var filtered = [String: MLXArray]()
        filtered.reserveCapacity(weights.count)

        for (key, value) in weights {
            guard key.hasPrefix("language_model.") else {
                continue
            }
            if key.contains("self_attn.rotary_emb.inv_freq") {
                continue
            }
            filtered[key] = value
        }

        return filtered
    }
}

private enum Mistral3ConfigAdapter {
    static func makeLlamaConfigData(from configURL: URL) throws -> Data {
        let rootData = try Data(contentsOf: configURL)
        guard
            let root = try JSONSerialization.jsonObject(with: rootData) as? [String: Any],
            var textConfig = root["text_config"] as? [String: Any]
        else {
            throw Mistral3CompatibilityError.missingTextConfig
        }

        // Ministral-3 stores RoPE settings under rope_parameters with yarn metadata.
        // Older LlamaConfiguration decoders don't accept that shape.
        if let ropeParameters = textConfig["rope_parameters"] as? [String: Any] {
            if let ropeTheta = ropeParameters["rope_theta"] {
                textConfig["rope_theta"] = ropeTheta
            }
            textConfig.removeValue(forKey: "rope_parameters")
            textConfig.removeValue(forKey: "rope_scaling")
        }

        return try JSONSerialization.data(withJSONObject: textConfig)
    }
}

private func registerMistral3CompatibilityLoader() {
    LLMModelFactory.shared.typeRegistry.registerModelType("mistral3") { configURL in
        let configData = try Mistral3ConfigAdapter.makeLlamaConfigData(from: configURL)
        let llamaConfiguration = try JSONDecoder().decode(LlamaConfiguration.self, from: configData)
        return Mistral3TextLlamaWrapper(LlamaModel(llamaConfiguration))
    }
}
