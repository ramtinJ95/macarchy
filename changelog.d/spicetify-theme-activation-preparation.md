### Fixed

- Theme activation and reconciliation now check that Spotify's unpacked `xpui`
  is prepared before refreshing Spicetify, as standalone environment commands
  already did, instead of failing midway through the refresh.
