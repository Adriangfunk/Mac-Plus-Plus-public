import Foundation

#if MACPP_CAELESTIA_PRODUCTION
let macppShellDomain = "org.macplusplus.shell"
let macppShellBundleIdentifier = macppShellDomain
let macppShellAlternateDomain = "org.macplusplus.caelestia-shell"
#else
let macppShellDomain = "org.macplusplus.caelestia-shell"
let macppShellBundleIdentifier = macppShellDomain
let macppShellAlternateDomain = "org.macplusplus.shell"
#endif
