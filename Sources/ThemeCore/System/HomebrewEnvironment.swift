/// Every Homebrew environment variant Macarchy passes to `brew` or prints in an
/// instruction. Approval digests, rendered commands and tests depend on their exact
/// contents and order, so the variants stay distinct; changing one changes those bytes.
package enum HomebrewEnvironment {
  /// Queries and `brew services`: no analytics and no implicit `brew update`.
  package static let quiet = [
    "HOMEBREW_NO_ANALYTICS": "1",
    "HOMEBREW_NO_AUTO_UPDATE": "1",
  ]

  /// `quiet` with the C locale, for parsed `brew list` output.
  package static let listing = [
    "HOMEBREW_NO_AUTO_UPDATE": "1",
    "HOMEBREW_NO_ANALYTICS": "1",
    "LC_ALL": "C",
  ]

  /// Macarchy self-update's `brew update`.
  package static let selfUpdate = [
    "HOMEBREW_NO_ANALYTICS": "1",
    "HOMEBREW_NO_AUTOREMOVE": "1",
    "HOMEBREW_NO_INSTALL_CLEANUP": "1",
    "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1",
  ]

  /// Macarchy self-update's `brew upgrade`: `selfUpdate` without the implicit update.
  package static let selfUpgrade = selfUpdate.merging(
    ["HOMEBREW_NO_AUTO_UPDATE": "1"],
    uniquingKeysWith: { _, override in override }
  )

  /// Setup's `brew bundle install`, as `NAME=value` entries in approval-digest order.
  package static let bundleInstall = [
    "HOMEBREW_NO_ANALYTICS=1", "HOMEBREW_NO_AUTO_UPDATE=1",
    "HOMEBREW_NO_AUTOREMOVE=1", "HOMEBREW_NO_INSTALL_CLEANUP=1",
    "HOMEBREW_NO_INSTALL_UPGRADE=1",
  ]

  /// Shell prefix of the printed self-update recovery `brew reinstall`.
  package static let selfReinstallCommandPrefix =
    "HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_AUTOREMOVE=1 "
    + "HOMEBREW_NO_INSTALL_CLEANUP=1 "
    + "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 "

  /// Shell prefix of the printed `brew install` for externally trusted formulae.
  package static let trustedFormulaInstallCommandPrefix =
    "HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 "
    + "HOMEBREW_NO_INSTALL_UPGRADE=1 "

  /// Shell prefix of the printed teardown `brew uninstall`.
  package static let uninstallCommandPrefix =
    "HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 "
}
