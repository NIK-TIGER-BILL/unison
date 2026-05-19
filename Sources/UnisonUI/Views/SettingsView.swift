import SwiftUI
import UnisonDomain

public struct SettingsView: View {
    @Bindable var vm: SettingsViewModel

    public init(vm: SettingsViewModel) {
        self.vm = vm
    }

    public var body: some View {
        Form {
            Section("Языки") {
                Picker("Я говорю на", selection: Binding(
                    get: { vm.settings.languagePair.mine },
                    set: { vm.setLanguagePair(LanguagePair(mine: $0, peer: vm.settings.languagePair.peer)) }
                )) {
                    ForEach(Language.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                Picker("Собеседник", selection: Binding(
                    get: { vm.settings.languagePair.peer },
                    set: { vm.setLanguagePair(LanguagePair(mine: vm.settings.languagePair.mine, peer: $0)) }
                )) {
                    ForEach(Language.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
            }

            Section("Аудио") {
                Picker("Микрофон", selection: Binding(
                    get: { vm.settings.inputDeviceUID ?? "" },
                    set: { vm.setInputDeviceUID($0.isEmpty ? nil : $0) }
                )) {
                    Text("По умолчанию").tag("")
                    ForEach(vm.availableInputs, id: \.uid) { d in
                        Text(d.name).tag(d.uid)
                    }
                }
                Picker("Выход", selection: Binding(
                    get: { vm.settings.outputDeviceUID ?? "" },
                    set: { vm.setOutputDeviceUID($0.isEmpty ? nil : $0) }
                )) {
                    Text("По умолчанию").tag("")
                    ForEach(vm.availableOutputs, id: \.uid) { d in
                        Text(d.name).tag(d.uid)
                    }
                }
                HStack {
                    Text("Громкость оригинала")
                    Slider(value: Binding(
                        get: { Double(vm.settings.originalMixVolume) },
                        set: { vm.setOriginalMixVolume(Float($0)) }
                    ), in: 0...1)
                    Text("\(Int(vm.settings.originalMixVolume * 100))%")
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .padding()
        .frame(width: 460, height: 360)
    }
}
