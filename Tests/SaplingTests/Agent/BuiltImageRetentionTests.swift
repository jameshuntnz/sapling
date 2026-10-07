import Testing

@testable import SaplingAgent

@Suite("Built image retention")
struct BuiltImageRetentionTests {
    let client = "sapling-img-acme-web-client"
    let server = "sapling-img-acme-web-server"

    @Test("keeps the two most recently used builds of each image")
    func keepsNewestPerImage() {
        let built = ["\(client):a", "\(client):b", "\(client):c", "\(server):x"]
        let removable = BuiltImageRetention.removable(
            built: built,
            recentRefs: ["\(client):c", "\(client):c", "\(client):a", "\(client):b", "\(server):x"],
            active: [])
        #expect(removable == ["\(client):b"])
    }

    @Test("never removes an image a running job is using")
    func keepsActive() {
        let built = ["\(client):a", "\(client):b", "\(client):c"]
        let removable = BuiltImageRetention.removable(
            built: built, recentRefs: ["\(client):c", "\(client):b", "\(client):a"], active: ["\(client):a"])
        #expect(removable.isEmpty)
    }

    @Test("removes builds no recent job used")
    func removesUnreferenced() {
        let removable = BuiltImageRetention.removable(
            built: ["\(client):a", "\(server):x"], recentRefs: ["\(client):a"], active: [])
        #expect(removable == ["\(server):x"])
    }
}
