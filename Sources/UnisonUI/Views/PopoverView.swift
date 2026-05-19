import SwiftUI
import UnisonDomain

public struct PopoverView: View {
    @Bindable var vm: PopoverViewModel

    public init(vm: PopoverViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Unison")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button(action: { /* open Settings */ }) {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
            }

            Picker("", selection: $vm.settings.sessionMode) {
                Label("Call", systemImage: "phone").tag(SessionMode.call)
                Label("Listen", systemImage: "ear").tag(SessionMode.listen)
            }
            .pickerStyle(.segmented)

            Text(vm.languagePairDisplay)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: { Task { await toggle() } }) {
                Text(vm.state.isActive ? "Stop" : "Start translating")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!vm.canStart && !vm.state.isActive)

            if let reason = vm.startBlockedReason {
                Text(blockedText(reason))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func toggle() async {
        if vm.state.isActive { await vm.stop() } else { await vm.start() }
    }

    private func blockedText(_ reason: StartBlockedReason) -> String {
        switch reason {
        case .micPermissionRequired: "Нужно разрешение микрофона"
        case .blackHole2chMissing: "Не установлен BlackHole 2ch"
        case .blackHole16chMissing: "Не установлен BlackHole 16ch"
        }
    }
}
