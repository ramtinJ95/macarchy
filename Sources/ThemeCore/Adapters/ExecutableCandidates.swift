import Foundation

package func externalThenHomebrewExecutableURLs(
  homeDirectory: URL,
  externalRelativePath: String,
  homebrewExecutableName: String
) -> [URL] {
  [
    homeDirectory.standardizedFileURL.appending(path: externalRelativePath),
    URL(filePath: "/opt/homebrew/bin/\(homebrewExecutableName)"),
  ]
}

package func preferredExternalOrHomebrewExecutableURL(
  homeDirectory: URL,
  externalRelativePath: String,
  homebrewExecutableName: String
) -> URL {
  let candidates = externalThenHomebrewExecutableURLs(
    homeDirectory: homeDirectory,
    externalRelativePath: externalRelativePath,
    homebrewExecutableName: homebrewExecutableName
  )
  return FileManager.default.isExecutableFile(atPath: candidates[0].path)
    ? candidates[0] : candidates[1]
}
