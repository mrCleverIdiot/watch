import Foundation
import MediaPlayer

/// Manages media playback control commands from Samsung Galaxy Watch
class MediaControlManager {
    static let shared = MediaControlManager()
    
    private let commandCenter = MPRemoteCommandCenter.shared()
    
    // MARK: - Public Methods
    
    func executeCommand(_ command: String) {
        switch command.uppercased() {
        case "PLAY":
            play()
        case "PAUSE":
            pause()
        case "NEXT":
            next()
        case "PREVIOUS":
            previous()
        case "TOGGLE":
            togglePlayPause()
        default:
            print("Unknown media command: \(command)")
        }
    }
    
    private func play() {
        if commandCenter.playCommand.isEnabled {
            _ = commandCenter.playCommand.addTarget { _ in .success }
        }
    }
    
    private func pause() {
        if commandCenter.pauseCommand.isEnabled {
            _ = commandCenter.pauseCommand.addTarget { _ in .success }
        }
    }
    
    private func togglePlayPause() {
        if commandCenter.togglePlayPauseCommand.isEnabled {
            _ = commandCenter.togglePlayPauseCommand.addTarget { _ in .success }
        }
    }
    
    private func next() {
        if commandCenter.nextTrackCommand.isEnabled {
            _ = commandCenter.nextTrackCommand.addTarget { _ in .success }
        }
    }
    
    private func previous() {
        if commandCenter.previousTrackCommand.isEnabled {
            _ = commandCenter.previousTrackCommand.addTarget { _ in .success }
        }
    }
    
    func getNowPlayingInfo() -> String? {
        let nowPlaying = MPNowPlayingInfoCenter.default().nowPlayingInfo
        
        if let title = nowPlaying?[MPMediaItemPropertyTitle] as? String,
           let artist = nowPlaying?[MPMediaItemPropertyArtist] as? String {
            return "\(artist) - \(title)"
        }
        
        return nil
    }
}

