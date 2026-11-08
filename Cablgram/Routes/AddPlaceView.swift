import SwiftUI
import MapKit

/// Sheet for saving a place: pick a type, then search or use where you are.
struct AddPlaceView: View {
    let currentLocation: CLLocation?
    let onAdd: (SavedPlace) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: SavedPlace.Kind
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false
    @State private var searchedOnce = false

    init(initialKind: SavedPlace.Kind = .other, currentLocation: CLLocation?, onAdd: @escaping (SavedPlace) -> Void) {
        _kind = State(initialValue: initialKind)
        self.currentLocation = currentLocation
        self.onAdd = onAdd
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(SavedPlace.Kind.allCases) { kind in
                            Label(kind.label, systemImage: kind.systemImage).tag(kind)
                        }
                    }
                }

                if let currentLocation {
                    Section {
                        Button {
                            add(name: kind == .home ? "Home" : "My spot", coordinate: currentLocation.coordinate)
                        } label: {
                            Label("Use my current location", systemImage: "location.fill")
                        }
                    }
                }

                if isSearching {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if !results.isEmpty {
                    Section("Results") {
                        ForEach(results, id: \.self) { item in
                            Button {
                                let name = kind == .home ? "Home" : (item.name ?? "Place")
                                add(name: name, coordinate: item.placemark.coordinate)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name ?? "Place").foregroundStyle(.primary)
                                    if let address = item.placemark.title {
                                        Text(address).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } else if searchedOnce {
                    Text("No places found. Try a different name or address.")
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search a place or address")
            .onSubmit(of: .search) { Task { await search() } }
            .navigationTitle("Add a place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isSearching = true
        defer { isSearching = false; searchedOnce = true }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let currentLocation {
            request.region = MKCoordinateRegion(center: currentLocation.coordinate,
                                                latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        }
        results = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
    }

    private func add(name: String, coordinate: CLLocationCoordinate2D) {
        onAdd(SavedPlace(name: name, kind: kind, latitude: coordinate.latitude, longitude: coordinate.longitude))
        dismiss()
    }
}
