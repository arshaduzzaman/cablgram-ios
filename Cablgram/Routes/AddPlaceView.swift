import SwiftUI
import CoreLocation

/// Sheet for saving a place: pick a type, then search or use where you are.
struct AddPlaceView: View {
    let currentLocation: CLLocation?
    let onAdd: (SavedPlace) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: SavedPlace.Kind
    @State private var query = ""
    @State private var results: [PlaceResult] = []
    @State private var isSearching = false
    @State private var searchedOnce = false
    @FocusState private var searchFocused: Bool

    init(initialKind: SavedPlace.Kind = .other, currentLocation: CLLocation?, onAdd: @escaping (SavedPlace) -> Void) {
        _kind = State(initialValue: initialKind)
        self.currentLocation = currentLocation
        self.onAdd = onAdd
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    kindPicker
                    searchField

                    if let currentLocation {
                        Button {
                            Haptics.tap()
                            add(name: kind == .home ? "Home" : "My spot", coordinate: currentLocation.coordinate)
                        } label: {
                            Label("Use my current location", systemImage: "location.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(Color.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.brand)
                    }

                    resultsList
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Add a place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Haptics.tap()
                        dismiss()
                    }
                }
            }
        }
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What is it?").font(.headline)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(SavedPlace.Kind.allCases) { option in
                    let isOn = option == kind
                    Button {
                        if kind != option { Haptics.select() }
                        kind = option
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: option.systemImage).font(.title3)
                            Text(option.label).font(.caption.weight(.semibold)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(isOn ? .white : .primary)
                        .background(isOn ? AnyShapeStyle(.brandGradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search a place or address", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { Task { await search() } }
            if isSearching { ProgressView() }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var resultsList: some View {
        if !results.isEmpty {
            VStack(spacing: 0) {
                ForEach(results) { result in
                    Button {
                        Haptics.tap()
                        add(name: kind == .home ? "Home" : result.name,
                            coordinate: CLLocationCoordinate2D(latitude: result.latitude, longitude: result.longitude))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title2)
                                .foregroundStyle(Color.brand)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.name).font(.subheadline.weight(.semibold))
                                if let address = result.address {
                                    Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if result.id != results.last?.id { Divider().padding(.leading, 50) }
                }
            }
            .card(cornerRadius: 16)
        } else if searchedOnce && !isSearching {
            Text("No places found. Try a different name or address.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Haptics.tap()
        isSearching = true
        results = await PlaceSearch.search(text, near: currentLocation)
        isSearching = false
        searchedOnce = true
        if results.isEmpty { Haptics.warning() }
    }

    private func add(name: String, coordinate: CLLocationCoordinate2D) {
        onAdd(SavedPlace(name: name, kind: kind, latitude: coordinate.latitude, longitude: coordinate.longitude))
        dismiss()
    }
}
