import Foundation
import UIKit

/**
 * Image cache manager for branding logos
 *
 * Stores images in app's cache directory for fast retrieval.
 */
class ImageCache {
    private let cacheDirectory: URL
    private let session: URLSession
    
    init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = cacheDir.appendingPathComponent("SecureNodeBranding", isDirectory: true)
        
        // Create cache directory if it doesn't exist
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        session = URLSession(configuration: config)
    }
    
    /**
     * Get cached image if available
     */
    func getImage(for urlString: String) -> UIImage? {
        guard let filename = urlToFilename(urlString) else {
            return nil
        }
        
        let fileURL = cacheDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data) else {
            return nil
        }
        
        return image
    }
    
    /**
     * Load image asynchronously and cache it
     */
    func loadImageAsync(from urlString: String, completion: @escaping (UIImage?) -> Void) {
        // Check cache first
        if let cachedImage = getImage(for: urlString) {
            completion(cachedImage)
            return
        }
        
        guard let url = URL(string: urlString),
              let filename = urlToFilename(urlString) else {
            completion(nil)
            return
        }
        
        let fileURL = cacheDirectory.appendingPathComponent(filename)
        
        session.dataTask(with: url) { data, response, error in
            guard let data = data,
                  let image = UIImage(data: data),
                  error == nil else {
                completion(nil)
                return
            }
            
            // Save to cache
            try? data.write(to: fileURL)
            completion(image)
        }.resume()
    }
    
    /**
     * Clean up old images (older than 30 days)
     */
    func cleanupOldImages() {
        let cutoffTime = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        
        for file in files {
            if let modificationDate = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modificationDate < cutoffTime {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
    
    /**
     * Convert URL to safe filename
     */
    private func urlToFilename(_ urlString: String) -> String? {
        guard let data = urlString.data(using: .utf8) else {
            return nil
        }
        
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        
        return encoded + ".png"
    }
}

