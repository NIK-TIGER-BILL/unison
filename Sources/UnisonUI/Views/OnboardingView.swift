import SwiftUI
import UnisonDomain

public struct OnboardingView: View {
    @Bindable var vm: OnboardingViewModel
    @State private var apiKeyDraft: String = ""

    public init(vm: OnboardingViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Добро пожаловать в Unison")
                .font(.title2.weight(.semibold))
            Text("Несколько шагов для начала работы")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(vm.steps) { step in
                stepRow(step)
            }

            Spacer()
        }
        .padding(28)
        .frame(width: 460, height: 360)
    }

    @ViewBuilder
    private func stepRow(_ step: OnboardingStep) -> some View {
        HStack(spacing: 12) {
            Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(step.isDone ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.callout)
                if !step.isDone {
                    actionButton(for: step.kind)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.4)))
    }

    @ViewBuilder
    private func actionButton(for kind: OnboardingStepKind) -> some View {
        switch kind {
        case .blackHole:
            Button("Установить") {
                Task { try? await vm.installBlackHole() }
            }.buttonStyle(.bordered)
        case .microphone:
            Button("Разрешить") {
                Task { await vm.requestMicPermission() }
            }.buttonStyle(.bordered)
        case .apiKey:
            HStack {
                SecureField("sk-...", text: $apiKeyDraft)
                Button("Сохранить") { try? vm.saveAPIKey(apiKeyDraft) }
                    .buttonStyle(.bordered)
            }
        }
    }
}
