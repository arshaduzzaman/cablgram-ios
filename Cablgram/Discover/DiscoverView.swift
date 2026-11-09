import SwiftUI
import SafariServices

/// Events happening in Bangladesh from Tickify and Quicket: the sites'
/// featured picks up top, then everything on now or coming up, filterable
/// by category. Tapping an event opens its page on that site to get tickets.
struct DiscoverView: View {
    @StateObject private var store = EventStore()
    @State private var category: String?
    @State private var opened: ListedEvent?

    private var shown: [ListedEvent] {
        guard let category else { return store.current }
        return store.current.filter { $0.categories?.contains(category) == true }
    }

    /// Categories that have something on, most events first.
    private var categories: [String] {
        var counts: [String: Int] = [:]
        for event in store.current {
            for name in event.categories ?? [] { counts[name, default: 0] += 1 }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if store.events.isEmpty {
                    if let message = store.errorMessage {
                        ContentUnavailableView {
                            Label("No events right now", systemImage: "ticket")
                        } description: {
                            Text(message)
                        } actions: {
                            Button("Try again") {
                                Haptics.tap()
                                Task { await store.refresh() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.top, 60)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    }
                } else {
                    if category == nil, !store.featured.isEmpty {
                        featured
                    }

                    Section {
                        if shown.isEmpty {
                            Text("Nothing in \(category ?? "this category") right now.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(16)
                        }
                        ForEach(shown) { event in
                            EventRow(event: event)
                                .contentShape(Rectangle())
                                .onTapGesture { open(event) }
                                .hairline(leading: 104)
                        }
                        credit
                    } header: {
                        chips
                    }
                }
            }
        }
        .background(Color(.systemBackground))
        .refreshable {
            Haptics.soft()
            await store.refresh()
        }
        .task { await store.refresh() }
        .sheet(item: $opened) { event in
            if let url = event.pageURL {
                SafariView(url: url)
                    .ignoresSafeArea()
            }
        }
        .animation(.snappy, value: category)
    }

    // MARK: - Featured

    /// Tickify's featured events as big swipeable banners.
    private var featured: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Featured")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(store.featured) { event in
                        FeaturedCard(event: event)
                            .containerRelativeFrame(.horizontal) { width, _ in width - 48 }
                            .onTapGesture { open(event) }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
            }
            .scrollTargetBehavior(.viewAligned)
        }
        .padding(.top, 16)
        .padding(.bottom, 6)
    }

    // MARK: - Category chips

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", selected: category == nil) { category = nil }
                ForEach(categories, id: \.self) { name in
                    chip(name, selected: category == name) { category = name }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
        .hairline()
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            guard !selected else { return }
            Haptics.select()
            action()
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(selected ? Color.brand : Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var credit: some View {
        Text("Events and tickets from tickify.live and quicket.me")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    private func open(_ event: ListedEvent) {
        Haptics.tap()
        opened = event
    }
}

// MARK: - Rows and cards

/// One event: square poster, name, when, where, price.
private struct EventRow: View {
    let event: ListedEvent

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RemoteImage(url: event.imageURL)
                .frame(width: 74, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                if event.isLive {
                    Label("Happening now", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.brand)
                }
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(event.whenText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let location = event.location, !location.isEmpty {
                    Text(location)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    if let price = event.priceText {
                        Text(price)
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(event.canBuy ? Color.brand : .secondary)
                    }
                    SourceTag(name: event.sourceName)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// A featured event: its wide banner with the name and date under it.
private struct FeaturedCard: View {
    let event: ListedEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: event.bannerURL)
                .aspectRatio(8 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if event.isLive {
                        Text("NOW")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.brand, in: Capsule())
                            .padding(8)
                    }
                }
            HStack(alignment: .firstTextBaseline) {
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let price = event.priceText {
                    Text(price)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.brand)
                }
            }
            HStack(spacing: 8) {
                Text(event.whenText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                SourceTag(name: event.sourceName)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Which site an event is from, small and quiet.
private struct SourceTag: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(.secondarySystemBackground), in: Capsule())
    }
}

/// A picture from the web, kept on disk by the shared photo cache.
private struct RemoteImage: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .clipped()
        .task(id: url) {
            guard let url else { return }
            image = PhotoCache.shared.cached(url.absoluteString)
            if image == nil { image = await PhotoCache.shared.load(url.absoluteString) }
        }
    }
}

/// Tickify's event page inside the app, to see details and buy tickets.
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let safari = SFSafariViewController(url: url)
        safari.preferredControlTintColor = UIColor(Color.brand)
        return safari
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
