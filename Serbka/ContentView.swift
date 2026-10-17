//
//  ContentView.swift
//  Serbka
//
//  Created by Niki on 17.10.2026.
//

import SwiftUI

struct MenuBarContent: View {
    @ObservedObject private var controller = AppController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Serbka")
                .font(.headline)
            Text("Сербский ↔ русский")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)

        Text("⌘S  слово под курсором")
        Text("⌘P  выделенный текст")
        Text("⌘Q  сохранить слово")
        Text("⌥⌘S  произнести перевод")

        Divider()

        if controller.isTrusted {
            Text("Универсальный доступ: включён")
        } else {
            Button("Открыть доступ Универсального доступа…") {
                controller.openAccessibilitySettings()
            }
        }

        if controller.canCaptureScreen {
            Text("Запись экрана: включена")
        } else {
            Button("Открыть доступ к записи экрана…") {
                controller.openScreenCaptureSettings()
            }
        }

        Divider()

        Button("Сохранить слово") {
            controller.saveCurrentWord()
        }

        Button("Мои слова") {
            controller.openWordsWindow()
        }

        Divider()

        Button("Выйти") {
            NSApplication.shared.terminate(nil)
        }
    }
}

struct WordsListView: View {
    @ObservedObject private var store = WordStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            if store.words.isEmpty {
                emptyState
            } else {
                wordList
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .background(Color.black.opacity(0.22))
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "sr"))
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Мои слова")
                    .font(.system(size: 20, weight: .semibold, design: .default))
                Text(countLabel)
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Экспорт для Quizlet") {
                AppController.shared.exportWordsToQuizletFile()
            }
            .disabled(store.words.isEmpty)
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 20)
        .padding(.top, 36)
        .padding(.bottom, 14)
    }

    private var wordList: some View {
        List {
            ForEach(store.words) { word in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(word.source)
                            .font(.system(size: 16, weight: .semibold, design: .default))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(word.translation)
                            .font(.system(size: 14, weight: .regular, design: .default))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button {
                        store.delete(word)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Удалить")
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.white.opacity(0.04))
                .listRowSeparator(.visible)
            }
            .onDelete { offsets in
                let items = offsets.compactMap { store.words.indices.contains($0) ? store.words[$0] : nil }
                items.forEach { store.delete($0) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "text.book.closed")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text("Пока нет сохранённых слов")
                .font(.system(size: 16, weight: .medium, design: .default))
            Text("Переведите слово (⌘S) или текст (⌘P),\nзатем нажмите ⌘Q.")
                .font(.system(size: 13, design: .default))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var countLabel: String {
        let count = store.words.count
        switch count {
        case 0: return "список пуст"
        case 1: return "1 пара"
        case 2...4: return "\(count) пары"
        default: return "\(count) пар"
        }
    }
}

struct PopupView: View {
    @ObservedObject var model: PopupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let banner = model.saveBanner, !banner.isEmpty {
                saveBanner(banner)
            }

            if model.mode != .notice {
                header
                Divider().opacity(0.28)
                translationBlock
            } else {
                Text(model.translation)
                    .font(.system(size: 14, weight: .medium, design: .default))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(
            minWidth: minWidth,
            idealWidth: idealWidth,
            maxWidth: maxWidth,
            minHeight: model.mode == .paragraph ? 300 : nil,
            maxHeight: model.mode == .paragraph ? .infinity : nil,
            alignment: .topLeading
        )
        .background(glassBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
        .padding(2)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                caption(sourceCaption)
                sourceText
            }

            Spacer(minLength: 8)

            SpeakButton(
                isSpeaking: model.speakingTarget == .source && model.isSpeaking,
                disabled: !model.canSpeakSource,
                help: "Произнести оригинал"
            ) {
                model.speakSource()
            }
        }
    }

    @ViewBuilder
    private var sourceText: some View {
        if model.mode == .paragraph {
            ScrollView {
                Text(displaySource)
                    .font(.system(size: 17, weight: .semibold, design: .default))
                    .environment(\.locale, sourceLocale)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
        } else {
            Text(displaySource)
                .font(.system(size: 20, weight: .semibold, design: .default))
                .environment(\.locale, sourceLocale)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var translationBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                caption(translationCaption)
                Spacer(minLength: 8)
                SpeakButton(
                    isSpeaking: model.speakingTarget == .translation && model.isSpeaking,
                    disabled: !model.canSpeakTranslation,
                    help: "Произнести перевод (⌥⌘S)"
                ) {
                    model.speakTranslation()
                }
            }

            if model.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Перевод…")
                        .font(.system(size: 14, design: .default))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            } else if model.direction == .russianToSerbian {
                serbianResult
            } else if model.mode == .paragraph {
                ScrollView {
                    Text(model.translation)
                        .font(.system(size: 15, weight: .regular, design: .default))
                        .environment(\.locale, Locale(identifier: "ru_RU"))
                        .foregroundStyle(.primary.opacity(0.92))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(model.translation)
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .environment(\.locale, Locale(identifier: "ru_RU"))
                    .foregroundStyle(.primary.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.isTrusted, !model.isLoading {
                Button("Открыть настройки доступа") {
                    AppController.shared.openAccessibilitySettings()
                }
                .buttonStyle(.link)
                .padding(.top, 2)
            }
        }
        .frame(maxHeight: model.mode == .paragraph ? .infinity : nil, alignment: .topLeading)
    }

    @ViewBuilder
    private var serbianResult: some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            if !model.serbianCyrillic.isEmpty {
                scriptLine(
                    title: "ћирилица",
                    text: model.serbianCyrillic,
                    locale: Locale(identifier: "sr_Cyrl_RS")
                )
            }
            if !model.serbianLatin.isEmpty {
                scriptLine(
                    title: "латиница",
                    text: model.serbianLatin,
                    locale: Locale(identifier: "sr_Latn_RS")
                )
            }
            if model.serbianCyrillic.isEmpty, model.serbianLatin.isEmpty {
                Text(model.translation)
                    .font(.system(size: 16, weight: .medium, design: .default))
                    .environment(\.locale, Locale(identifier: "sr_Latn_RS"))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        if model.mode == .paragraph {
            ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) }
        } else {
            content
        }
    }

    private func scriptLine(title: String, text: String, locale: Locale) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .default))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 16, weight: .medium, design: .default))
                .environment(\.locale, locale)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(model.mode == .paragraph ? nil : 6)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .default))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func saveBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .default))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var glassBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.42))
        }
    }

    private var displaySource: String {
        model.source.isEmpty ? "Нет текста" : model.source
    }

    private var sourceCaption: String {
        if model.source.isEmpty { return "текст" }
        switch model.direction {
        case .russianToSerbian: return "русский"
        case .serbianToRussian: return "сербский"
        case .unknown: return "текст"
        }
    }

    private var translationCaption: String {
        if model.source.isEmpty { return "перевод" }
        switch model.direction {
        case .russianToSerbian: return "сербский"
        case .serbianToRussian: return "русский"
        case .unknown: return "перевод"
        }
    }

    private var sourceLocale: Locale {
        switch model.direction {
        case .russianToSerbian:
            return Locale(identifier: "ru_RU")
        case .serbianToRussian:
            let hasLatin = model.source.unicodeScalars.contains {
                CharacterSet.letters.contains($0) && ($0.value < 0x0400 || $0.value > 0x04FF)
            }
            return Locale(identifier: hasLatin ? "sr_Latn_RS" : "sr_Cyrl_RS")
        case .unknown:
            return Locale(identifier: "sr")
        }
    }

    private var minWidth: CGFloat { model.mode == .paragraph ? 420 : 260 }
    private var idealWidth: CGFloat { model.mode == .paragraph ? 520 : 320 }
    private var maxWidth: CGFloat { model.mode == .paragraph ? .infinity : 400 }
}

struct SpeakButton: View {
    let isSpeaking: Bool
    let disabled: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(disabled ? Color.secondary : Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

#Preview("Serbian → Russian") {
    PopupView(model: {
        let model = PopupModel()
        model.source = "kuća"
        model.translation = "дом"
        model.direction = .serbianToRussian
        model.isLoading = false
        return model
    }())
    .padding()
    .frame(width: 340)
}

#Preview("Russian → Serbian") {
    PopupView(model: {
        let model = PopupModel()
        model.source = "дом"
        model.direction = .russianToSerbian
        model.serbianCyrillic = "кућа"
        model.serbianLatin = "kuća"
        model.isLoading = false
        return model
    }())
    .padding()
    .frame(width: 340)
}
