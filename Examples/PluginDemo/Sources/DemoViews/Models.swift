import SwiftUI

public struct User: Equatable {
    public var id: UUID
    public var name: String
}

@Observable public final class ProfileModel { public var user: User? }
