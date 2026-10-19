import AppKit
import SwiftUI

/// The Sessions page's list column (236 pt): every session, newest first.
struct HomeSessionsList: View {
    @ObservedObject var model: HomeSessionsModel
    @ObservedObject var router: HomeRouter
    /// The session shown in the detail (the router's choice, or the first one).
    var selectedName: String?
    @Environment(\.homeInk) private var ink

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sessions").font(VT.Font.largeTitle).tracking(VT.Font.largeTitleTracking).foregroundStyle(ink.primary)
                .padding(.leading, 10).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.sessions) { s in
                        Button { router.selectedSession = s.name } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(VT.Font.bodyEmph).foregroundStyle(ink.primary).lineLimit(1)
                                HStack(spacing: 6) {
                                    Text("\(HomeFormat.day(s.date)) · \(s.kindText)").font(VT.Font.callout).foregroundStyle(ink.secondary).lineLimit(1)
                                    if s.unprepared { UnpreparedTag() }
                                }
                            }
                            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .background(s.name == selectedName ? ink.selection : .clear,
                                        in: RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if model.sessions.isEmpty {
                        Text("No sessions yet. Prepare one for your next meeting.").font(VT.Font.callout).foregroundStyle(ink.tertiary)
                            .padding(.horizontal, 10)
                    }
                }
            }
        }
        .frame(width: 236).padding(.leading, 18).padding(.top, 22)
    }
}

/// "Unprepared": a call that started without a prepared session. A neutral fill, like every tag on the window glass.
struct UnpreparedTag: View {
    @Environment(\.homeInk) private var ink
    var body: some View {
        Text("Unprepared").font(VT.Font.caption).foregroundStyle(ink.secondary)
            .padding(.horizontal, 6).frame(height: 16)
            .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous))
            .fixedSize()
    }
}
