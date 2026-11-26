import Foundation

/// Which individual processes must not be killed casually.
public enum ProcessCatalog {
    /// Processes the login session depends on, by executable name (lowercased).
    static let critical: Set<String> = [
        "kernel_task", "launchd", "windowserver", "loginwindow", "dock", "finder", "systemuiserver",
        "controlcenter", "notificationcenter", "windowmanager", "spotlight", "siri ai", "siri",
        "cfprefsd", "distnoted", "coreaudiod", "corespotlightd", "mds", "mds_stores", "mdworker",
        "mdworker_shared", "opendirectoryd", "securityd", "trustd", "tccd", "runningboardd", "lsd",
        "launchservicesd", "iconservicesagent", "pboard", "usereventagent", "universalaccessd",
        "sharingd", "bluetoothd", "airportd", "powerd", "logd", "syslogd", "nsurlsessiond",
        "coreservicesuiagent", "textinputmenuagent", "talagent", "backgroundtaskmanagementd",
        "sshd", "sshd-session", "secd", "accountsd", "cloudd", "bird", "fileproviderd",
        "dedotatedwam",
    ]

    /// Folders that hold the operating system's own daemons and agents.
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]

    /// - Parameter path: the executable's full path, when known. Anything that ships inside the
    ///   operating system counts as protected even if its name is not on the list.
    public static func isProtected(name: String, path: String?) -> Bool {
        if critical.contains(name.lowercased()) { return true }
        if let path, systemPrefixes.contains(where: { path.hasPrefix($0) }) { return true }
        return false
    }
}
