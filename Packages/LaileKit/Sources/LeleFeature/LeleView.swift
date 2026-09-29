import AppCore
import DesignSystem
import LaileCore
import SwiftUI

public struct LeleModule: FeatureModule {
    public init() {}
    public var id: String { "lele" }
    public var tab: FeatureTab? { FeatureTab(title: "Lele", systemImage: "bubble.left.and.text.bubble.right.fill", order: 2) }
    public func makeRootView(app: AppModel) -> AnyView { AnyView(LeleView(app: app)) }
}

/// The conversation with Lele: everything Lele started (check-ins, nudges, reminders), your
/// answers, and free chat. Lele can see your programs, measurements and notes.
struct LeleView: View {
    @Bindable var app: AppModel
    @State private var draft = ""
    @State private var sending = false
    @State private var showGoals = false
    @FocusState private var focused: Bool

    private var suggestions: [String] {
        var list = ["How am I doing?", "Why am I doing this exercise?", "I've been sore after sessions"]
        if !(app.today?.medicationDoses.isEmpty ?? true) { list.append("What are my medicines for?") }
        return list
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        intro
                        ForEach(app.leleMessages) { message in
                            LeleBubble(message: message) { action in Task { await app.perform(action, on: message) } }
                                .id(message.id)
                        }
                        if sending {
                            HStack { LeleAvatar(); ProgressView().padding(.leading, 6); Spacer() }.id("typing")
                        }
                    }
                    .padding(16)
                }
                .onChange(of: app.leleMessages.count) { _, _ in scrollToEnd(proxy) }
                .onChange(of: sending) { _, _ in scrollToEnd(proxy) }
                .onAppear { scrollToEnd(proxy) }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .screenBackground()
            .navigationTitle("Lele")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { app.showLeleCall = true } label: { Image(systemName: "phone.fill") }
                        .accessibilityLabel("Talk to Lele")
                }
            }
            .task { await app.refreshLele() }
            .onChange(of: app.leleDraft, initial: true) { _, text in
                if let text { draft = text; app.leleDraft = nil; focused = true }
            }
            .sheet(isPresented: $showGoals) {
                GoalsConversationView(app: app) { enrollment in
                    showGoals = false
                    if let enrollment { app.afterSheetCloses { app.start(enrollment) } }
                }
            }
        }
    }

    private var intro: some View {
        VStack(spacing: 10) {
            LeleAvatar(size: 56)
            Text("Lele, your coach from Laile").font(.laileHeadline).foregroundStyle(Theme.text)
            Text("I check in on you, remember what felt sore, explain your exercises and medicines, and tell your clinician what matters.")
                .font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            if !app.isSupervised {
                Button { showGoals = true } label: { Label("Build me a new plan", systemImage: "sparkles") }
                    .font(.footnote.weight(.semibold)).tint(Theme.accent)
            }
        }
        .padding(.vertical, 8)
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if app.leleMessages.filter({ $0.author == .person }).count < 2 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(suggestions, id: \.self) { s in
                            Button(s) { Task { await send(s) } }
                                .font(.caption.weight(.semibold)).buttonStyle(.bordered).tint(Theme.accent)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            HStack(spacing: 10) {
                TextField("Message Lele", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.surface2, lineWidth: 1))
                if draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button { app.showLeleCall = true } label: {
                        Image(systemName: "mic.fill").font(.title3).frame(width: 40, height: 40).background(Theme.accentSoft, in: Circle())
                    }
                    .accessibilityLabel("Talk to Lele")
                } else {
                    Button { Task { await send(draft) } } label: {
                        Image(systemName: "arrow.up").font(.title3.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40).background(Theme.accent, in: Circle())
                    }
                    .disabled(sending)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func send(_ text: String) async {
        let message = text
        draft = ""
        sending = true
        defer { sending = false }
        await app.chat(message)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if sending { proxy.scrollTo("typing", anchor: .bottom) } else if let last = app.leleMessages.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }
}
