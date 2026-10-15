import SwiftUI

public struct ProfileView: View {
    let user: User
    var onTap: () -> Void
    @Environment(ProfileModel.self) private var model

    public var body: some View {
        Text(user.name).onTapGesture(perform: onTap)
    }
}

struct Card<Content: View>: View {
    let title: String
    let content: () -> Content

    var body: some View { VStack { Text(title); content() } }
}
