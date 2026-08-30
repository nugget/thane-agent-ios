import SwiftUI

struct AppCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(
        title: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
        }
    }
}

struct PreferenceLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct OperationalRow: View {
    let title: String
    let value: String
    let systemImage: String
    var color: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 16)
            Text(value)
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
        }
    }
}
