import SwiftUI

struct User: Equatable {
    var id: UUID
    var name: String
}

struct Theme {          // not Equatable, but every field is: compared field by field
    var accent: Color
    var radius: CGFloat
}

struct Row {            // not Equatable and holds a closure: never compares equal
    var title: String
    var onSelect: () -> Void
}

@Observable final class ProfileModel { var user: User? }
final class LegacyStore: ObservableObject { @Published var items: [String] = [] }
final class Cache { var hits = 0 }

struct ProfileView: View {
    let user: User
    let theme: Theme
    var onTap: () -> Void
    @State private var isExpanded = false
    @Environment(ProfileModel.self) private var model

    var body: some View {
        Text(user.name).onTapGesture(perform: onTap)
    }
}

struct Card<Content: View>: View {
    let title: String
    let content: () -> Content

    var body: some View { VStack { Text(title); content() } }
}

struct ItemList: View {
    @ObservedObject var store = LegacyStore()
    @State private var cache = Cache()
    let rows: [Row]
    let footer: AnyView

    var body: some View {
        List {
            ForEach(store.items.filter { !$0.isEmpty }, id: \.self) { Text($0) }
            ForEach(rows.indices, id: \.self) { Text(rows[$0].title) }
        }
    }
}

struct Badge: View, Equatable {
    let count: Int
    let onClear: () -> Void
    static func == (a: Badge, b: Badge) -> Bool { a.count == b.count }
    var body: some View { Text("\(count)") }
}
