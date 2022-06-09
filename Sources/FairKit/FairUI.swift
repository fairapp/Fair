/**
 Copyright (c) 2022 Marc Prud'hommeaux

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as
 published by the Free Software Foundation, either version 3 of the
 License, or (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
import Swift

@_exported import FairApp

#if canImport(SwiftUI)
import SwiftUI

public extension Bundle {
    /// Creates a label with the given localized key and the optional icon
    @available(*, deprecated)
    func label(_ title: LocalizedStringKey, _ iconSymbol: String? = nil) -> Label<Text, Image?> {
        Label(title: {
            Text(title, bundle: self)
        }, icon: {
            iconSymbol.flatMap(Image.init(systemName:))
        })
    }

    /// Creates a button with the given localized key and the optional icon
    @available(*, deprecated)
    func button(_ title: LocalizedStringKey, _ iconSymbol: String? = nil, action: @escaping () -> ()) -> Button<Label<Text, Image?>> {
        Button(action: action, label: { label(title, iconSymbol) })
    }
}


/// A caching mechanism for images
public protocol CachedImageCache {
    @MainActor subscript(url: URL) -> Image? { get nonmutating set }
}

public final class AsyncCachedImageCache : CachedImageCache {
    /// A singleton image cache that can be used globally
    public static let shared = AsyncCachedImageCache()

    private var cache = NSCache<NSURL, ImageInfo>()

    /// Access the underlying cached image
    @MainActor public subscript(_ url: URL) -> Image? {
        get {
            cache.object(forKey: url as NSURL)?.image
        }

        set {
            if let newValue = newValue {
                cache.setObject(ImageInfo(image: newValue), forKey: url as NSURL)
            } else {
                cache.removeObject(forKey: url as NSURL)
            }
        }
    }

    /// Clear the image cache
    public func clear() {
        cache.removeAllObjects()
    }

    private final class ImageInfo {
        let image: SwiftUI.Image

        init(image: SwiftUI.Image) {
            self.image = image
        }
    }
}

@available(*, deprecated, message: "cached SwiftUI.Image instances seem to become invalid after a while")
public struct AsyncCachedImage<Content>: View where Content: View {
    private let cache: CachedImageCache
    private let url: URL
    private let scale: CGFloat
    private let transaction: Transaction
    private let content: (AsyncImagePhase) -> Content

    public init(cache: CachedImageCache = AsyncCachedImageCache.shared, url: URL, scale: CGFloat = 1.0, transaction: Transaction = Transaction(), @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.cache = cache
        self.url = url
        self.scale = scale
        self.transaction = transaction
        self.content = content
    }

    public var body: some View {
        if let cached = cache[url] {
            content(.success(cached))
        } else {
            AsyncImage(url: url, scale: scale, transaction: transaction) { phase in
                cacheAndRender(phase: phase)
            }
        }
    }

    @MainActor func cacheAndRender(phase: AsyncImagePhase) -> some View {
        if case .success (let image) = phase {
            cache[url] = image // cache the image
        }
        return content(phase)
    }
}

/// An image that loads from a URL, either synchronously or asynchronously
public struct URLImage : View, Equatable {
    /// Whether the image should be loaded synchronously or asynchronously
    public let sync: Bool
    /// The URL from which to load
    public let url: URL
    /// The scale of the image
    public let scale: CGFloat
    /// Whether the image should be resizable or not
    public let resizable: ContentMode?
    /// Whether a progress placeholder should be used
    public let showProgress: Bool
    /// Whether a progress placeholder should be used
    public let showError: Bool
    /// The recommended size of the image, as encoded with the image ending in `"-widthxheight"`
    public let suggestedSize: CGSize?

    public init(sync: Bool = false, url: URL, scale: CGFloat = 1.0, resizable: ContentMode? = nil, showProgress: Bool = false, showError: Bool = false) {
        self.sync = sync
        self.url = url
        self.scale = scale
        self.resizable = resizable
        self.showProgress = showProgress
        self.showError = showError

        if let assetName = try? AssetName(string: url.lastPathComponent) {
            self.suggestedSize = assetName.size
        } else {
            self.suggestedSize = nil
        }
    }

    public var body: some View {
        if sync == false, #available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *) {
            AsyncImage(url: url, scale: scale, transaction: Transaction(animation: .easeIn)) { phase in
                if let image = phase.image {
                    if let resizable = resizable {
                        image
                            .resizable(resizingMode: .stretch)
                            .aspectRatio(contentMode: resizable)
                    } else {
                        image
                    }
                } else if let error = phase.error {
                    if showError {
                        Text(error.localizedDescription)
                            .label(image: FairSymbol.xmark_octagon)
                    } else {
                        //Circle()
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.secondary).opacity(0.5)
//                        FairSymbol.xmark_octagon.image
//                            .resizable(resizingMode: .stretch)
                    }
                } else if showProgress == true {
                    ProgressView().progressViewStyle(.automatic)
                } else if let suggestedSize = suggestedSize, suggestedSize.width > 0.0, suggestedSize.height > 0.0 {
                    // we make a placeholder with the specified size in order to maintain the correct aspect ratio
                    // this doesn't work: the
//                    Rectangle()
//                        .aspectRatio(suggestedSize.height / suggestedSize.width, contentMode: .fill)
//                        .background(Material.thick)

                    if let resizable = resizable {
                        placeholderImage(size: suggestedSize)?
                            .resizable()
                            .aspectRatio(contentMode: resizable)
                            .overlay(Material.thick)
                    } else {
                        placeholderImage(size: suggestedSize)
                            .redacted(reason: .placeholder)
                            .overlay(Material.thick)
                    }
                } else {
                    Circle().hidden()
                    // Color.gray.opacity(0.5)
                }
            }
        } else { // load the image synchronously
            if let img = try? UXImage(data: Data(contentsOf: url)) {
                if let resizable = resizable {
                    Image(uxImage: img)
                        .resizable(resizingMode: .stretch)
                        .aspectRatio(contentMode: resizable)
                } else {
                    Image(uxImage: img)
                }
            } else {
                Label("Error Loading Image", systemImage: "xmark.octagon")
            }
        }
    }

    /// Creates an empty image with a certain dimension.
    /// Useful for replicating the behavior of a placeholder image when all that is known is the size.
    func placeholderImage(size: CGSize, scale: CGFloat = 1.0, opaque: Bool = true) -> Image? {
        #if os(iOS)
        let rect = CGRect(origin: .zero, size: size)

        UIGraphicsBeginImageContextWithOptions(size, opaque, scale)
        // color.set()
        UIRectFill(rect)
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return Image(uxImage: image!)
        #elseif os(macOS)
        return Image(uxImage: NSImage(size: size, flipped: false) { rect in
            if opaque {
                rect.fill()
            }
            return true
        })
        #else
        return nil
        #endif
    }
}

extension ForEach where Content : View {
    /// Initialize with elements that are identified merely by their index
    public init<S : Sequence>(enumerated sequence: S, @ViewBuilder content: @escaping (Int, S.Element) -> Content) where ID == Int, Data == Array<EnumeratedSequence<S>.Element> {
        self = ForEach(Array(sequence.enumerated()), id: \.offset, content: content)
    }
}

public extension UsageDescriptionKeys {
    var icon: FairSymbol {
        switch self {
        case .NSSiriUsageDescription: return .ear
        case .NSSpeechRecognitionUsageDescription: return .waveform
        case .NSMicrophoneUsageDescription: return .mic_circle
        case .NSCameraUsageDescription: return .camera
        case .NSMotionUsageDescription: return .gyroscope
        case .NFCReaderUsageDescription: return .barcode_viewfinder
        case .NSBluetoothUsageDescription: return .cable_connector
        case .NSBluetoothAlwaysUsageDescription: return .cable_connector_horizontal
        case .NSBluetoothPeripheralUsageDescription: return .printer
        case .NSRemindersUsageDescription: return .text_badge_checkmark
        case .NSContactsUsageDescription: return .person_text_rectangle
        case .NSCalendarsUsageDescription: return .calendar
        case .NSPhotoLibraryAddUsageDescription: return .text_below_photo_fill
        case .NSPhotoLibraryUsageDescription: return .photo
        case .NSAppleMusicUsageDescription: return .music_note
        case .NSHomeKitUsageDescription: return .house
            //case .NSVideoSubscriberAccountUsageDescription: return .sparkles_tv
        case .NSHealthShareUsageDescription: return .stethoscope
        case .NSHealthUpdateUsageDescription: return .stethoscope_circle
        case .NSAppleEventsUsageDescription: return .scroll
        case .NSFocusStatusUsageDescription: return .eyeglasses
        case .NSLocalNetworkUsageDescription: return .network
        case .NSFaceIDUsageDescription: return .viewfinder
        case .NSLocationUsageDescription: return .location
        case .NSLocationAlwaysUsageDescription: return .location_fill
        case .NSLocationTemporaryUsageDescriptionDictionary: return .location_circle
        case .NSLocationWhenInUseUsageDescription: return .location_north
        case .NSLocationAlwaysAndWhenInUseUsageDescription: return .location_fill_viewfinder
        case .NSUserTrackingUsageDescription: return .eyes
        case .NSNearbyInteractionAllowOnceUsageDescription:
                return .person_badge_clock_fill
        case .NSLocationDefaultAccuracyReduced: return .location_square_fill
        case .NSWidgetWantsLocation: return .location_magnifyingglass
        case .NSVoIPUsageDescription: return .network_badge_shield_half_filled
        case .NSNearbyInteractionUsageDescription: return .person_2_wave_2
        case .NSSensorKitUsageDescription: return .antenna_radiowaves_left_and_right
        case .NSBluetoothWhileInUseUsageDescription: return .dot_radiowaves_right
        case .NSFallDetectionUsageDescription: return .figure_walk
        case .NSVideoSubscriberAccountUsageDescription: return .play_tv
        case .NSGKFriendListUsageDescription: return .person_3_sequence
        case .NSHealthClinicalHealthRecordsShareUsageDescription: return .cross_circle
        case .NSDesktopFolderUsageDescription: return .dock_rectangle
        case .NSDocumentsFolderUsageDescription: return .menubar_dock_rectangle
        case .NSDownloadsFolderUsageDescription: return .dock_arrow_down_rectangle
        case .NSSystemExtensionUsageDescription: return .desktopcomputer
        case .NSSystemAdministrationUsageDescription: return .lock_laptopcomputer
        case .NSFileProviderDomainUsageDescription: return .externaldrive_connected_to_line_below
        case .NSFileProviderPresenceUsageDescription: return .externaldrive_badge_checkmark
        case .NSNetworkVolumesUsageDescription: return .externaldrive_badge_wifi
        case .NSRemovableVolumesUsageDescription: return .externaldrive
        }
    }
}

@available(macOS 12.0, iOS 15.0, *)
extension SwiftUI.TextField {
    /// Creates a `Link` to the given URL and overlays it over the trailing end of the field.
    public func overlink(to destination: URL?, image: Image = FairSymbol.arrowshape_turn_up_right_circle_fill.image) -> some View {
        self.overlay(alignment: .trailing) {
            if let destination = destination {
                Link(destination: destination) {
                    image
                }
                //.padding(.horizontal) // causes a crash
            }
        }
    }

}



#endif
