import SwiftUI

/// Asks for Full Disk Access before the first scan, then waits for it. The scan starts
/// by itself once macOS grants access, or straight away if the user skips it.
struct AccessSheet: View {
    @ObservedObject var model: AppModel
    let request: AppModel.AccessRequest

    static let height: CGFloat = 330

    private var isWaiting: Bool {
        if case .waiting = request { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Allow Full Disk Access")
                .font(Theme.Font.pageTitle)
                .foregroundColor(Theme.text)
                .padding(.bottom, 8)
            Text("To measure every folder, TrashFree needs Full Disk Access. Without it, Mail, Messages, other apps' data, and system folders count as hidden space, and macOS asks about Desktop, Documents, and Downloads one by one.")
                .font(Theme.Font.pageSubtitle)
                .foregroundColor(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Open Full Disk Access in System Settings.")
                step(2, "Turn on TrashFree. If it is not in the list, drag it in from the Finder window that opens.")
                step(3, request.sourceID == nil ? "Come back here." : "Come back here. The scan starts on its own.")
            }
            .padding(.bottom, 20)

            if isWaiting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for access…")
                        .font(Theme.Font.rowDetail)
                        .foregroundColor(Theme.secondaryText)
                    Spacer()
                    if FullDiskAccess.appBundle != nil {
                        // macOS can apply the grant only to a fresh process.
                        Button("Still waiting after turning it on? Quit & Reopen") { model.relaunchForAccess() }
                            .buttonStyle(.link)
                            .font(Theme.Font.rowDetail)
                    }
                }
                .transition(.opacity)
                .padding(.bottom, 16)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                ActionButton(title: "Cancel") { model.cancelAccessRequest() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                ActionButton(title: request.sourceID == nil ? "Not Now" : "Scan Without Access") {
                    model.scanWithoutAccess()
                }
                ActionButton(title: isWaiting ? "Open Again" : "Open Settings", kind: .primary) {
                    model.openAccessSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: Self.height)
        .animation(Theme.Motion.change, value: isWaiting)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(Theme.Font.rowDetail.weight(.semibold))
                .foregroundColor(Theme.secondaryText)
                .frame(width: 14, alignment: .leading)
            Text(text)
                .font(Theme.Font.pageSubtitle)
                .foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
