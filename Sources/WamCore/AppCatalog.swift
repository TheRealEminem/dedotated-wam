import Foundation

/// Built-in catalog that sorts well-known Mac apps into a default triage tier.
///
/// Lookup order: exact bundle identifier, then the longest matching bundle identifier prefix,
/// then the app's `LSApplicationCategoryType`. Anything else is left unsorted (`nil`).
///
/// Maintenance notes:
/// - Every identifier and prefix is written in lowercase.
/// - Every prefix ends with a dot so it can only match whole identifier components.
/// - When an app could sit in two tiers, it goes in the more protective one (the one closed later).
public enum AppCatalog {

    // MARK: - Public API

    /// Exact bundle identifier (lowercased) -> tier.
    public static let known: [String: DefaultTier] = {
        var table: [String: DefaultTier] = [:]
        table.reserveCapacity(
            closeFirstIDs.count + closeNextIDs.count + lastResortIDs.count + neverIDs.count
        )
        // Filled from least to most protective, so if an identifier is ever listed
        // twice by mistake the more protective tier wins instead of crashing.
        for id in closeFirstIDs { table[id.lowercased()] = .closeFirst }
        for id in closeNextIDs { table[id.lowercased()] = .closeNext }
        for id in lastResortIDs { table[id.lowercased()] = .lastResort }
        for id in neverIDs { table[id.lowercased()] = .never }
        return table
    }()

    /// Bundle identifier prefix (lowercased) -> tier, checked longest prefix first,
    /// used when there is no exact match.
    public static let prefixRules: [(prefix: String, tier: DefaultTier)] = {
        var rules: [(prefix: String, tier: DefaultTier)] = []
        var seen: Set<String> = []
        func add(_ prefixes: [String], _ tier: DefaultTier) {
            for prefix in prefixes {
                let key = prefix.lowercased()
                if seen.insert(key).inserted {
                    rules.append((prefix: key, tier: tier))
                }
            }
        }
        // Most protective first, so a prefix listed twice by mistake keeps the safer tier.
        add(neverPrefixes, .never)
        add(lastResortPrefixes, .lastResort)
        add(closeNextPrefixes, .closeNext)
        add(closeFirstPrefixes, .closeFirst)
        // Longest first, so the first match found is the most specific one.
        return rules.sorted { lhs, rhs in
            if lhs.prefix.count != rhs.prefix.count { return lhs.prefix.count > rhs.prefix.count }
            return lhs.prefix < rhs.prefix
        }
    }()

    /// LSApplicationCategoryType value (e.g. "public.app-category.games") -> tier,
    /// used when neither of the above match.
    public static let categoryDefaults: [String: DefaultTier] = {
        var table: [String: DefaultTier] = [:]
        for name in closeFirstCategories { table[categoryPrefix + name] = .closeFirst }
        for name in closeNextCategories { table[categoryPrefix + name] = .closeNext }
        for name in lastResortCategories { table[categoryPrefix + name] = .lastResort }
        for name in neverCategories { table[categoryPrefix + name] = .never }
        return table
    }()

    /// Returns nil when the app is unknown, so the caller can leave it unsorted.
    public static func classify(bundleID: String, category: String?) -> DefaultTier? {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !id.isEmpty {
            if let tier = known[id] {
                return tier
            }
            // `prefixRules` is sorted longest first, so the first hit is the longest match.
            for rule in prefixRules where id.hasPrefix(rule.prefix) {
                return rule.tier
            }
        }
        if let category = category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !category.isEmpty {
            return categoryDefaults[category]
        }
        return nil
    }

    // MARK: - Close first
    // Nothing is lost by closing these: players, chat, stores, launchers, games, news.

    private static let closeFirstIDs: [String] = [
        // Apple media, stores and reading
        "com.apple.music",
        "com.apple.tv",
        "com.apple.podcasts",
        "com.apple.itunes",
        "com.apple.news",
        "com.apple.stocks",
        "com.apple.weather",
        "com.apple.ibooksx",
        "com.apple.appstore",
        "com.apple.games",
        "com.apple.chess",
        "com.apple.photobooth",

        // Apple lookup and glance apps
        "com.apple.maps",
        "com.apple.findmy",
        "com.apple.home",
        "com.apple.calculator",
        "com.apple.clock",
        "com.apple.dictionary",
        "com.apple.helpviewer",
        "com.apple.tips",
        "com.apple.fontbook",
        "com.apple.digitalcolormeter",
        "com.apple.systemprofiler",

        // Apple messaging
        "com.apple.mobilesms",

        // Music and video players
        "com.spotify.client",
        "com.tidal.desktop",
        "org.videolan.vlc",
        "com.colliderli.iina",
        "io.mpv",
        "org.niltsh.mplayerx",
        "com.coppertino.vox",
        "com.firecore.infuse",
        "tv.plex.desktop",
        "tv.plex.plexamp",

        // E-book readers
        "com.amazon.kindle",
        "com.amazon.lassen",

        // Chat and social
        "com.tinyspeck.slackmacgap",
        "com.hnc.discord",
        "com.hnc.discordptb",
        "com.hnc.discordcanary",
        "org.whispersystems.signal-desktop",
        "net.whatsapp.whatsapp",
        "ru.keepcoder.telegram",
        "org.telegram.desktop",
        "com.tdesktop.telegram",
        "com.facebook.archon",
        "com.viber.osx",
        "jp.naver.line.mac",
        "com.tencent.xinwechat",
        "com.tencent.qq",
        "com.kakao.kakaotalkmac",
        "im.riot.app",
        "com.twitter.twitter-mac",

        // News and feed readers
        "com.reederapp.5.macos",
        "com.ranchero.netnewswire-evergreen",

        // Game stores and launchers
        "com.valvesoftware.steam",
        "com.epicgames.epicgameslauncher",
        "com.gog.galaxy",
        "net.battle.app",
        "com.mojang.minecraftlauncher",
        "com.heroicgameslauncher.hgl",
        "com.isaacmarovitz.whisky",
        "com.roblox.robloxplayer",

        // Game streaming and emulators
        "com.moonlight-stream.moonlight",
        "com.nvidia.gfnpc.mall",
        "com.playstation.remoteplay",
        "org.openemu.openemu",
        "org.dolphin-emu.dolphin",

        // Games
        "org.openttd.openttd",
    ]

    private static let closeFirstPrefixes: [String] = [
        // Music
        "com.spotify.",
        // Chat
        "com.tinyspeck.",
        "net.whatsapp.",
        // Game publishers and launchers
        "com.valvesoftware.",
        "com.blizzard.",
        "com.riotgames.",
        "com.gog.",
        "com.mojang.",
        "com.aspyr.",
        "com.feralinteractive.",
    ]

    // MARK: - Close next
    // Heavy, but these put you back where you were when reopened.

    private static let closeNextIDs: [String] = [
        // Web browsers
        "com.apple.safari",
        "com.apple.safaritechnologypreview",
        "com.google.chrome",
        "com.google.chrome.beta",
        "com.google.chrome.dev",
        "com.google.chrome.canary",
        "org.chromium.chromium",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.microsoft.edgemac",
        "com.brave.browser",
        "com.operasoftware.opera",
        "com.operasoftware.operagx",
        "com.vivaldi.vivaldi",
        "company.thebrowser.browser",
        "company.thebrowser.dia",
        "com.kagi.kagimacos",
        "com.duckduckgo.macos.browser",
        "org.torproject.torbrowser",
        "net.librewolf.librewolf",
        "net.waterfox.waterfox",
        "app.zen-browser.zen",
        "com.openai.atlas",

        // Mail
        "com.apple.mail",
        "com.microsoft.outlook",
        "org.mozilla.thunderbird",
        "com.readdle.smartemail-mac",
        "com.freron.mailmate",
        "it.bloop.airmail2",
        "com.superhuman.electron",
        "com.mimestream.mimestream",

        // Calendars, contacts and tasks
        "com.apple.ical",
        "com.apple.addressbook",
        "com.apple.reminders",
        "com.flexibits.fantastical2.mac",
        "com.busymac.busycal3",
        "com.cron.electron",
        "com.culturedcode.thingsmac",
        "com.todoist.mac.todoist",
        "com.ticktick.task.mac",
        "com.omnigroup.omnifocus3",
        "com.omnigroup.omnifocus4",

        // Notes and knowledge bases that save as you type
        "com.apple.notes",
        "com.apple.stickies",
        "com.apple.freeform",
        "com.apple.journal",
        "md.obsidian",
        "notion.id",
        "com.evernote.evernote",
        "net.shinyfrog.bear",
        "com.agiletortoise.drafts-osx",
        "com.lukilabs.lukiapp",
        "com.microsoft.onenote.mac",
        "com.electron.logseq",
        "com.bloombuilt.dayone-mac",
        "com.automattic.simplenotemac",
        "net.cozic.joplin-desktop",
        "com.goodnotesapp.x",
        "org.zotero.zotero",
        "net.ankiweb.dtop",

        // AI chat
        "com.openai.chat",
        "com.google.geminimacos",
        "ai.perplexity.mac",

        // Cloud-synced work trackers and boards
        "com.linear",
        "com.atlassian.trello",
        "com.clickup.desktop-app",
        "com.electron.realtimeboard",

        // Calls and meetings (nothing to save, but more disruptive than chat)
        "com.apple.facetime",
        "com.apple.mobilephone",
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.skype.skype",
        "cisco-systems.spark",

        // Apple viewers and libraries
        "com.apple.preview",
        "com.apple.photos",
        "com.apple.shortcuts",
        "com.apple.generativeplaygroundapp",
        "com.apple.screencontinuity",
    ]

    private static let closeNextPrefixes: [String] = [
        // Browser channels, profiles and installed web apps
        "com.apple.safari.",
        "com.google.chrome.",
        "org.chromium.",
        "org.mozilla.",
        "com.microsoft.edgemac.",
        "com.brave.browser.",
        "com.operasoftware.",
        "com.vivaldi.",
        "company.thebrowser.",
        "net.librewolf.",
        // Shortcut apps that open cloud documents in the browser
        "com.google.drivefs.shortcuts.",
    ]

    // MARK: - Last resort
    // May hold unsaved work or a long-running job.

    private static let lastResortIDs: [String] = [
        // Terminal emulators and multiplexers
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "dev.warp.warp-stable",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "org.tabby",
        "com.raphaelamorim.rio",
        "com.termius-dmg.mac",
        "dev.herdr.app",
        "org.xquartz.x11",

        // Code editors and IDEs
        "com.apple.dt.xcode",
        "com.apple.iphonesimulator",
        "com.apple.playgrounds",
        "com.microsoft.vscode",
        "com.microsoft.vscodeinsiders",
        "com.vscodium",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
        "dev.zed.zed",
        "dev.zed.zed-preview",
        "com.sublimetext.3",
        "com.sublimetext.4",
        "com.sublimemerge",
        "com.google.android.studio",
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.webstorm",
        "com.jetbrains.clion",
        "com.jetbrains.goland",
        "com.jetbrains.rider",
        "com.jetbrains.datagrip",
        "com.jetbrains.phpstorm",
        "com.jetbrains.rubymine",
        "com.jetbrains.toolbox",
        "org.vim.macvim",
        "org.gnu.emacs",
        "com.neovide.neovide",
        "com.barebones.bbedit",
        "com.macromates.textmate",
        "com.coteditor.coteditor",
        "com.panic.nova",
        "com.github.atom",
        "com.rstudio.desktop",
        "com.mathworks.matlab",
        "com.wolfram.mathematica",
        "cc.arduino.ide2",

        // Game engines and editors
        "org.godotengine.godot",
        "com.epicgames.unrealeditor",
        "com.roblox.robloxstudio",

        // AI coding agents and local model runners
        "com.anthropic.claudefordesktop",
        "com.openai.codex",
        "com.electron.ollama",
        "ai.elementlabs.lmstudio",
        "com.liuliu.draw-things",

        // Meeting capture and transcription
        "com.granola.app",
        "com.goodsnooze.macwhisper",

        // Virtual machines and container runtimes
        "com.docker.docker",
        "dev.kdrag0n.macvirt",
        "com.utmapp.utm",
        "com.parallels.desktop.console",
        "com.vmware.fusion",
        "org.virtualbox.app.virtualbox",
        "org.virtualbox.app.virtualboxvm",
        "io.rancherdesktop.app",

        // Version control, API and network debugging
        "com.github.githubclient",
        "com.torusknot.sourcetreenotmas",
        "com.fournova.tower3",
        "com.postmanlabs.mac",
        "com.proxyman.nsproxy",
        "com.xk72.charles",
        "org.wireshark.wireshark",

        // Database tools
        "com.tinyapp.tableplus",
        "com.sequel-ace.sequel-ace",
        "com.sequelpro.sequelpro",
        "com.mongodb.compass",
        "org.jkiss.dbeaver.core.product",
        "com.postgresapp.postgres2",

        // Remote desktop sessions
        "com.apple.screensharing",
        "com.apple.remotedesktop",
        "com.microsoft.rdc.macos",
        "com.realvnc.vncviewer",

        // Office suites and writing
        "com.apple.pages",
        "com.apple.numbers",
        "com.apple.keynote",
        "com.apple.iwork.pages",
        "com.apple.iwork.numbers",
        "com.apple.iwork.keynote",
        "com.apple.textedit",
        "com.microsoft.word",
        "com.microsoft.excel",
        "com.microsoft.powerpoint",
        "org.libreoffice.script",
        "org.openoffice.script",
        "com.omnigroup.omnigraffle7",
        "com.omnigroup.omnioutliner5",
        "com.literatureandlatte.scrivener3",
        "com.ulyssesapp.mac",
        "pro.writer.mac",
        "abnerworks.typora",
        "com.devon-technologies.think3",

        // PDF editors and annotators
        "com.adobe.acrobat.pro",
        "com.adobe.reader",
        "com.readdle.pdfexpert-mac",
        "net.sourceforge.skim-app.skim",

        // Apple pro and creative apps
        "com.apple.finalcut",
        "com.apple.logic10",
        "com.apple.mainstage3",
        "com.apple.garageband10",
        "com.apple.imovieapp",
        "com.apple.motionapp",
        "com.apple.compressor",
        "com.apple.voicememos",
        "com.apple.quicktimeplayerx",

        // Apple tools that may be mid-task or hold unsaved documents
        "com.apple.automator",
        "com.apple.scripteditor2",
        "com.apple.grapher",
        "com.apple.console",
        "com.apple.image_capture",
        "com.apple.archiveutility",
        "com.apple.printcenter",
        "com.apple.bluetoothfileexchange",
        "com.apple.colorsyncutility",
        "com.apple.audio.audiomidisetup",
        "com.apple.airport.airportutility",
        "com.apple.configurator.ui",

        // Design, photo and illustration
        "com.adobe.photoshop",
        "com.adobe.illustrator",
        "com.adobe.indesign",
        "com.adobe.lightroomcc",
        "com.figma.desktop",
        "com.bohemiancoding.sketch3",
        "com.pixelmatorteam.pixelmator.x",
        "com.seriflabs.affinityphoto2",
        "com.seriflabs.affinitydesigner2",
        "com.seriflabs.affinitypublisher2",
        "org.gimp.gimp-2.10",
        "org.inkscape.inkscape",

        // Video
        "com.blackmagic-design.davinciresolve",
        "com.blackmagic-design.davinciresolvelite",
        "com.lemon.lvoverseas",
        "fr.handbrake.handbrake",

        // Audio production
        "com.ableton.live",
        "com.cockos.reaper",
        "org.audacityteam.audacity",

        // 3D, CAD, electronics and printing
        "org.blenderfoundation.blender",
        "net.maxon.cinema4d",
        "org.freecad.freecad",
        "org.kicad.kicad",
        "com.bambulab.bambu-studio",

        // Disk imaging and long transfers
        "io.balena.etcher",
        "org.raspberrypi.imagingutility",
        "org.m0k.transmission",
    ]

    private static let lastResortPrefixes: [String] = [
        // IDEs and editors
        "com.apple.dt.",
        "com.jetbrains.",
        "com.sublimetext.",
        "dev.zed.",
        "com.panic.",
        "com.barebones.",
        "org.qt-project.",
        "com.unity3d.",
        // AI agents
        "com.anthropic.",
        // Virtual machines and containers
        "com.docker.",
        "com.parallels.",
        "com.vmware.",
        "com.utmapp.",
        "org.virtualbox.",
        // Office and finance
        "org.libreoffice.",
        "com.intuit.turbotax.",
        // Creative suites
        "com.adobe.",
        "com.seriflabs.",
        "com.blackmagic-design.",
        "com.autodesk.",
        "net.maxon.",
        "com.sketchup.",
        "org.gimp.",
        "org.inkscape.",
        "org.blenderfoundation.",
        // Audio production
        "com.ableton.",
        "com.native-instruments.",
        "com.steinberg.",
        "org.audacityteam.",
        // CAD, electronics and 3D printing
        "org.freecad.",
        "org.kicad.",
        "com.bambulab.",
        "com.prusa3d.",
        "nl.ultimaker.",
    ]

    // MARK: - Never
    // Closing these breaks the desktop, drops protection or connectivity, or takes away input.

    private static let neverIDs: [String] = [
        // This app
        "com.dedotatedwam.app",

        // Core system UI
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.loginwindow",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.usernotificationcenter",
        "com.apple.spotlight",
        "com.apple.windowmanager",
        "com.apple.securityagent",
        "com.apple.coreservices.uiagent",
        "com.apple.textinputmenuagent",
        "com.apple.textinputswitcher",
        "com.apple.universalcontrol",
        "com.apple.airplayuiagent",
        "com.apple.wifi.wifiagent",
        "com.apple.screensaver.engine",
        "com.apple.exposelauncher",
        "com.apple.launchpad.launcher",
        "com.apple.apps.launcher",

        // Siri
        "com.apple.siri",
        "com.apple.siri.launcher",
        "com.apple.campo",

        // System settings, monitoring and maintenance
        "com.apple.systempreferences",
        "com.apple.activitymonitor",
        "com.apple.diskutility",
        "com.apple.migrateassistant",
        "com.apple.installer",
        "com.apple.backup.launcher",

        // Screen capture and recording
        "com.apple.screencaptureui",
        "com.apple.screenshot.launcher",
        "com.obsproject.obs-studio",
        "com.loom.desktop",
        "pl.maketheweb.cleanshotx",
        "com.wulkano.kap",
        "cc.ffitch.shottr",

        // Accessibility
        "com.apple.voiceover",
        "com.apple.voiceoverutility",
        "com.apple.magnifier",

        // Password managers, keys and authenticators
        "com.apple.passwords",
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "in.sinew.enpass-desktop",
        "me.proton.pass.electron",
        "com.maxgoedjen.secretive",
        "com.yubico.ykman",
        "com.yubico.yubioath",

        // VPN and mesh networking
        "io.tailscale.ipn.macos",
        "io.tailscale.ipn.macsys",
        "io.netbird.client",
        "org.openvpn.client.app",
        "com.wireguard.macos",
        "net.mullvad.vpn",
        "ch.protonvpn.mac",
        "com.nordvpn.macos",
        "com.expressvpn.expressvpn",
        "com.privateinternetaccess.vpn",
        "net.tunnelblick.tunnelblick",
        "com.viscosityvpn.viscosity",
        "com.cisco.anyconnect.gui",
        "com.cisco.secureclient.gui",
        "com.cloudflare.1dot1dot1dot1.macos",
        "com.paloaltonetworks.globalprotect.client",
        "com.fortinet.forticlient",
        "com.zerotier.zerotier-one",
        "ui.wifiman.desktop",

        // Firewalls, endpoint protection and device management
        "at.obdev.littlesnitch",
        "com.objective-see.lulu.app",
        "com.microsoft.wdav",
        "com.microsoft.companyportalmac",

        // Remote access hosts
        "com.carriez.rustdesk",
        "com.teamviewer.teamviewer",
        "com.philandro.anydesk",

        // Backup and file sync
        "com.google.drivefs",
        "com.getdropbox.dropbox",
        "com.microsoft.onedrive",
        "com.box.desktop",
        "com.nextcloud.desktopclient",
        "mega.mac",
        "com.bombich.ccc",
        "com.shirtpocket.superduper",
        "com.haystacksoftware.arq",

        // Keyboard, mouse and other input
        "com.lujjjh.linearmouse",
        "com.theron.unnaturalscrollwheels",
        "com.logitech.logi-options",
        "com.logi.optionsplus",
        "com.caldis.mos",
        "com.pilotmoon.scroll-reverser",
        "com.hegenberg.bettertouchtool",
        "org.hammerspoon.hammerspoon",
        "com.smileonmymac.textexpander",
        "com.elgato.streamdeck",
        "com.electron.wispr-flow",

        // Launchers
        "com.raycast.macos",
        "com.runningwithcrayons.alfred",
        "at.obdev.launchbar",

        // Window management
        "com.knollsoft.rectangle",
        "com.knollsoft.hookshot",
        "com.crowdcafe.windowmagnet",
        "com.manytricks.moom",
        "com.divisiblebyzero.spectacle",
        "com.amethyst.amethyst",
        "com.hegenberg.bettersnaptool",
        "com.lwouis.alt-tab-macos",

        // Clipboard managers
        "org.p0deje.maccy",
        "com.wiheads.paste",
        "com.generalarcade.flycut",
        "com.tapbots.pastebot2mac",

        // Menu bar, display, audio and power utilities
        "com.surteesstudios.bartender",
        "com.jordanbaird.ice",
        "com.dwarvesv.minimalbar",
        "eu.exelban.stats",
        "com.bjango.istatmenus",
        "com.ameba.swiftbar",
        "com.mowglii.itsycalmac",
        "com.if.amphetamine",
        "com.apphousekitchen.aldente-pro",
        "fyi.lunar.lunar",
        "pro.betterdisplay.betterdisplay",
        "com.rogueamoeba.soundsource",
        "com.rogueamoeba.loopback",
        "com.vorssaint.utils",
    ]

    private static let neverPrefixes: [String] = [
        // This app and its helpers
        "com.dedotatedwam.",

        // Apple: anything not listed by name above is treated as a system component.
        "com.apple.",
        "com.apple.accessibility.",
        "com.apple.inputmethod.",
        "com.apple.preference.",
        "com.apple.coreservices.",
        "com.apple.security.",

        // Password managers and authenticators
        "com.1password.",
        "com.bitwarden.",
        "com.lastpass.",
        "com.dashlane.",
        "com.yubico.",

        // VPN and mesh networking
        "io.tailscale.",
        "io.netbird.",
        "org.openvpn.",
        "com.wireguard.",
        "ch.protonvpn.",
        "com.nordvpn.",
        "com.expressvpn.",
        "com.cisco.anyconnect.",
        "com.cisco.secureclient.",
        "com.cloudflare.1dot1dot1dot1.",
        "com.paloaltonetworks.",
        "com.zscaler.",

        // Firewalls, endpoint protection and device management
        "at.obdev.littlesnitch.",
        "com.objective-see.",
        "com.crowdstrike.",
        "com.sentinelone.",
        "com.malwarebytes.",
        "com.sophos.",
        "com.eset.",
        "com.microsoft.wdav.",
        "com.jamfsoftware.",
        "io.kandji.",

        // Backup
        "com.backblaze.",

        // Input devices, automation and audio routing
        "com.logitech.",
        "com.logi.",
        "org.pqrs.",
        "com.stairways.keyboardmaestro.",
        "com.raycast.",
        "com.knollsoft.",
        "com.bjango.istatmenus.",
        "com.rogueamoeba.",
    ]

    // MARK: - App Store categories

    private static let categoryPrefix = "public.app-category."

    private static let closeFirstCategories: [String] = [
        "books",
        "entertainment",
        "food-drink",
        "lifestyle",
        "magazines-newspapers",
        "navigation",
        "news",
        "reference",
        "shopping",
        "social-networking",
        "sports",
        "travel",
        "weather",
        // Games and every game sub-category
        "games",
        "action-games",
        "adventure-games",
        "arcade-games",
        "board-games",
        "card-games",
        "casino-games",
        "dice-games",
        "educational-games",
        "family-games",
        "kids-games",
        "music-games",
        "puzzle-games",
        "racing-games",
        "role-playing-games",
        "simulation-games",
        "sports-games",
        "strategy-games",
        "trivia-games",
        "word-games",
    ]

    private static let closeNextCategories: [String] = [
        "education",
        "healthcare-fitness",
        "medical",
    ]

    /// These categories mix harmless viewers with editors that hold unsaved work
    /// (music holds both players and audio workstations), so they take the protective tier.
    private static let lastResortCategories: [String] = [
        "business",
        "developer-tools",
        "finance",
        "graphics-design",
        "music",
        "photography",
        "productivity",
        "video",
    ]

    /// Unknown utilities are mostly background helpers: input, window, clipboard and menu bar tools.
    private static let neverCategories: [String] = [
        "utilities",
    ]
}
