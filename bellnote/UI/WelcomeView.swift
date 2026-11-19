import SwiftUI

/// The first screens: one page per idea, swiped or stepped with Next. Skip and the last page both end it.
struct WelcomeView: View {
    var onFinish: () -> Void

    @State private var page = 0

    private struct Page: Identifiable {
        let id: Int
        let symbol: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
    }

    private let pages: [Page] = [
        Page(
            id: 0,
            symbol: "bell.fill",
            title: "Welcome to Bellnote",
            detail: "Your classes, turned into notes on your own device."
        ),
        Page(
            id: 1,
            symbol: "mic.fill",
            title: "Record a class",
            detail: "Record with permission. Pause, resume and stop, even from the Lock Screen."
        ),
        Page(
            id: 2,
            symbol: "doc.text.fill",
            title: "Notes you can trace",
            detail: "Each recording becomes a transcript, a summary, notes and homework, and every point opens its minute."
        ),
        Page(
            id: 3,
            symbol: "calendar",
            title: "Timetable and exams",
            detail: "Add your weekly slots, exam dates and scores, and get a reminder before class."
        ),
        Page(
            id: 4,
            symbol: "pencil.and.list.clipboard",
            title: "Files and quizzes",
            detail: "Keep slides and PDFs with each course, then study with questions made from them."
        ),
        Page(
            id: 5,
            symbol: "bubble.left.and.bubble.right.fill",
            title: "Ask and listen",
            detail: "Ask about a course by voice or text, or have a lecture read back to you."
        ),
        Page(
            id: 6,
            symbol: "lock.shield.fill",
            title: "Private on your device",
            detail: "No account and no upload. Audio, notes and the AI stay on this device, behind Face ID if you like."
        ),
        Page(
            id: 7,
            symbol: "arrow.down.circle.fill",
            title: "Models download once",
            detail: "Bellnote needs a few AI models. You download each one yourself, only when you tap Download. They take a few gigabytes, so use Wi-Fi."
        ),
    ]

    private var isLast: Bool { page == pages.count - 1 }

    var body: some View {
        TabView(selection: $page) {
            ForEach(pages) { item in
                pageView(item)
                    .tag(item.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .overlay(alignment: .topTrailing) {
            if !isLast {
                Button("Skip", action: onFinish)
                    .appFont(.body)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                if isLast {
                    onFinish()
                } else {
                    withAnimation { page += 1 }
                }
            } label: {
                Text(isLast ? LocalizedStringKey("Get started") : LocalizedStringKey("Next"))
                    .appFont(.body, weight: .semibold)
                    .frame(maxWidth: .infinity)
            }
            // Glass, like the lock screen: a prominent button takes the app tint, which is white in dark mode.
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
        }
    }

    /// A big colored symbol on a soft tile of the same color, then the title and the line, in the middle of the page.
    private func pageView(_ item: Page) -> some View {
        let tint = CourseStyle.color(at: item.id, fallbackName: "")
        return GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 28) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 64, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 140, height: 140)
                        .background(tint.opacity(0.16), in: .rect(cornerRadius: 36))
                        .accessibilityHidden(true)
                    VStack(spacing: 12) {
                        Text(item.title)
                            .appFont(.largeTitle, weight: .bold)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text(item.detail)
                            .appFont(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 56)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
