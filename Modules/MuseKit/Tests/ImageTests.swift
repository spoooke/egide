import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import MuseKit

/// Image PNG unie de la taille voulue, pour les tests.
func makePNG(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func pixelSize(_ data: Data) throws -> (width: Int, height: Int, type: String) {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    return (props[kCGImagePropertyPixelWidth] as! Int, props[kCGImagePropertyPixelHeight] as! Int,
            CGImageSourceGetType(source) as String? ?? "")
}

struct ImageProcessingTests {
    @Test func largeImageIsShrunkAndConvertedToJPEG() throws {
        let output = try #require(ImageProcessing.prepare(try makePNG(width: 4000, height: 3000)))
        let size = try pixelSize(output)
        #expect(max(size.width, size.height) == ImageProcessing.maxPixelSize)
        #expect(size.type == UTType.jpeg.identifier)
    }

    @Test func smallImageKeepsItsSize() throws {
        let output = try #require(ImageProcessing.prepare(try makePNG(width: 800, height: 600)))
        let size = try pixelSize(output)
        #expect(size.width == 800 && size.height == 600)
    }

    @Test func nonImageDataIsRejected() {
        #expect(ImageProcessing.prepare(Data("pas une image".utf8)) == nil)
    }
}

@MainActor
@Suite(.serialized)
struct IdeaImageTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(for: Schema(AppSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        IdeaActions.scheduler = SpyScheduler()
    }

    @Test func addingImagesKeepsOrderAndTouchesIdea() throws {
        let idea = try #require(IdeaActions.add("Avec captures", in: context))
        let before = idea.modifiedAt
        #expect(IdeaActions.addImage(try makePNG(width: 100, height: 100), to: idea, in: context))
        #expect(IdeaActions.addImage(try makePNG(width: 50, height: 50), to: idea, in: context))
        #expect(idea.sortedImages.map(\.order) == [0, 1])
        #expect(idea.sortedImages.allSatisfy { $0.data != nil && !$0.isUploaded })
        #expect(idea.modifiedAt >= before)
    }

    @Test func invalidImageIsNotAdded() throws {
        let idea = try #require(IdeaActions.add("Idée", in: context))
        #expect(!IdeaActions.addImage(Data("texte".utf8), to: idea, in: context))
        #expect(idea.images?.isEmpty ?? true)
    }

    @Test func removingImageDeletesIt() throws {
        let idea = try #require(IdeaActions.add("Idée", in: context))
        IdeaActions.addImage(try makePNG(width: 10, height: 10), to: idea, in: context)
        IdeaActions.removeImage(try #require(idea.sortedImages.first), from: idea, in: context)
        #expect(idea.images?.isEmpty ?? true)
        #expect(try context.fetchCount(FetchDescriptor<IdeaImage>()) == 0)
    }

    @Test func snapshotListsImageIDs() throws {
        let idea = try #require(IdeaActions.add("Idée", in: context))
        IdeaActions.addImage(try makePNG(width: 10, height: 10), to: idea, in: context)
        let snapshot = try IdeaSync.snapshot(of: context, deviceID: "a", deviceName: "iPhone")
        #expect(snapshot.ideas.first?.imageIDs == idea.sortedImages.map(\.imageID))
    }

    @Test func remoteImagesArriveAsPlaceholdersAndRemovalsApply() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func file(_ ids: [String]?, at date: Date) -> SyncFile {
            SyncFile(deviceID: "mac", deviceName: "Mac", writtenAt: date, ideas: [
                .init(syncID: "x", text: "Idée", isDone: false, createdAt: t0, completedAt: nil,
                      sortIndex: 0, modifiedAt: date, imageIDs: ids),
            ], tombstones: [])
        }
        try IdeaSync.merge([file(["img1", "img2"], at: t0)], into: context)
        let idea = try #require(try context.fetch(FetchDescriptor<Idea>()).first)
        #expect(idea.sortedImages.map(\.imageID) == ["img1", "img2"])
        #expect(idea.sortedImages.allSatisfy { $0.data == nil && $0.isUploaded })

        try IdeaSync.merge([file(["img2"], at: t0 + 60)], into: context)
        #expect(idea.sortedImages.map(\.imageID) == ["img2"])
        #expect(try context.fetchCount(FetchDescriptor<IdeaImage>()) == 1)
    }

    @Test func fileWithoutImageListLeavesImagesAlone() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let idea = try #require(IdeaActions.add("Idée", in: context))
        IdeaActions.addImage(try makePNG(width: 10, height: 10), to: idea, in: context)
        idea.touch(at: t0)
        // Ancien format (avant les images) : pas de champ imageIDs.
        let old = SyncFile(deviceID: "mac", deviceName: "Mac", writtenAt: t0 + 60, ideas: [
            .init(syncID: idea.syncID, text: "Texte modifié", isDone: false, createdAt: t0,
                  completedAt: nil, sortIndex: 0, modifiedAt: t0 + 60),
        ], tombstones: [])
        try IdeaSync.merge([old], into: context)
        #expect(idea.text == "Texte modifié")
        #expect(idea.images?.count == 1)
    }
}
