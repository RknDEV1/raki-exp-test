import SwiftUI
import UIKit

@main
struct ThreeOneOSFiveApp: App {
    private static let portugueseDefaultMigrationKey = "appLanguage.ptBRDefaultMigrated"
    @StateObject private var appState = AppState()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator()
    @StateObject private var patchStore = PatchProjectStore()
    @StateObject private var repositoryStore = PackageRepositoryStore()
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.portugueseBrazilian.rawValue
    @State private var showAttribution = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.portugueseDefaultMigrationKey) {
            if defaults.string(forKey: AppLanguage.storageKey) == nil
                || defaults.string(forKey: AppLanguage.storageKey) == AppLanguage.english.rawValue {
                defaults.set(AppLanguage.portugueseBrazilian.rawValue, forKey: AppLanguage.storageKey)
            }
            defaults.set(true, forKey: Self.portugueseDefaultMigrationKey)
        }
        setupLogCapture()
        log("app: 3105 launching — iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) \(AppInfo.machineName)")
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .portugueseBrazilian
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(patchDraftCoordinator)
                .environmentObject(fileOperationCoordinator)
                .environmentObject(patchStore)
                .environmentObject(repositoryStore)
                .environment(\.appLanguage, language)
                .environment(\.locale, language.locale)
                .displayIdentityAttribution(isPresented: $showAttribution, enabled: true)
            .sheet(isPresented: $showAttribution) {
                DisplayAttributionSheet()
            }
            .onAppear {
                appState.detectSupport()
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active else { return }
                appState.detectSupport()
            }
            .onOpenURL { url in
                patchDraftCoordinator.presentImport(url)
            }
        }
    }
}

class AppState: ObservableObject {
    @Published var exploitStatus: ExploitStatus = .notStarted
    @Published var unsupportedMessage: String?
    @Published var kernelExploitRunning = false

    private var autoRunAttempted = false

    var kernelExploitApplicable: Bool {
        KernelExploit.isApplicable(
            major: AppInfo.versionTuple.major,
            minor: AppInfo.versionTuple.minor,
            patch: AppInfo.versionTuple.patch,
            build: AppInfo.osBuild
        )
    }

    var isSupported: Bool { unsupportedMessage == nil }

    func detectSupport() {
        let v = AppInfo.versionTuple
        let supported = ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-access") {
            exploitStatus = .success(method: "Simulator preview")
        }
#endif

        unsupportedMessage = supported ? nil : "iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))"
        if let unsupportedMessage {
            exploitStatus = .unsupported(unsupportedMessage)
            return
        }

        let applicable = KernelExploit.isApplicable(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
        guard applicable else { return }

        refreshKernelExploitStatus()
        maybeAutoRunKernelExploit()
    }

    private func maybeAutoRunKernelExploit() {
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed,
              !autoRunAttempted else { return }
        autoRunAttempted = true
        log("app: starting kernel exploit automatically")
        runKernelExploitIfNeeded()
    }

    private func refreshKernelExploitStatus() {
        guard !kernelExploitRunning else { return }

        // iOS < 26: kernel R/W success persists (no sandbox probe)
        // iOS >= 26: verify full sandbox escape is still active
        if KernelExploit.requiresSandboxEscape {
            if KernelExploit.hasSandboxAccess() {
                if !exploitStatus.isSuccess {
                    exploitStatus = .success(method: "kexploit")
                    log("app: existing sandbox access is still active; skipping kernel exploit")
                }
            } else if exploitStatus.isSuccess {
                exploitStatus = .notStarted
                log("app: sandbox access is no longer active")
            }
        }
    }

    func runKernelExploitIfNeeded() {
        refreshKernelExploitStatus()
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed else { return }
        kernelExploitRunning = true
        exploitStatus = .notStarted
        
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        
        // Se for iOS 27.1, 27.2, 27.3 (ou iOS 28+), usa o novo exploit
        let isNewExploitNeeded = osVersion.majorVersion > 27 || (osVersion.majorVersion == 27 && osVersion.minorVersion >= 1)
        
        if isNewExploitNeeded {
            log("app: rodando worse_query (iOS 27.1+)")
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = worse_query() // Chama a função C do novo exploit
                DispatchQueue.main.async {
                    self.kernelExploitRunning = false
                    if ok == 0 {
                        self.exploitStatus = .success(method: "worse_query")
                        log("app: worse_query success — sandbox ativo")
                    } else {
                        self.exploitStatus = .failed(method: "worse_query", code: -1)
                        log("app: worse_query failed — code \(ok)")
                    }
                }
            }
        } else {
            // Fallback: iOS 27.0 ou menor (usa o antigo)
            log("app: rodando kernel exploit antigo (iOS <= 27.0)")
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = KernelExploit.run() 
                DispatchQueue.main.async {
                    self.kernelExploitRunning = false
                    if ok {
                        self.exploitStatus = .success(method: "kexploit")
                        log("app: kernel exploit success")
                    } else {
                        self.exploitStatus = .failed(method: "kexploit", code: -1)
                    }
                }
            }
        }
    }
