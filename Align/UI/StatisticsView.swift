import SwiftUI

struct StatisticsView: View {
    @ObservedObject var history: PostureHistoryController
    let onClose: () -> Void
    @State private var period: PostureHistoryPeriod = .day
    @State private var selectedDate = Date()
    @State private var selectedSignal: PostureObservationSignalID = .shoulderSlope
    @State private var showsMethod = false
    @State private var confirmsErase = false
    @State private var compactDetailsExpanded = false
    @FocusState private var closeFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 10) {
                header
                Picker("Période", selection: $period) {
                    Text("Jour").tag(PostureHistoryPeriod.day)
                    Text("Semaine").tag(PostureHistoryPeriod.week)
                    Text("Mois").tag(PostureHistoryPeriod.month)
                }.pickerStyle(.segmented)
                navigation
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        coverage
                        if case .loading = viewState.state {
                            loadingState
                        } else if case .content = viewState.state {
                            if proxy.size.width < 620 {
                                VStack(alignment: .leading, spacing: 12) { insights(limit: 2); chart }
                            } else {
                                HStack(alignment: .top, spacing: 20) {
                                    insights(limit: 3).frame(maxWidth: .infinity, alignment: .topLeading)
                                    chart.frame(maxWidth: .infinity)
                                }
                            }
                            observations(compact: proxy.size.width < 620)
                        } else { emptyState }
                        Button("Comprendre les données…") { showsMethod = true }.buttonStyle(.link)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(proxy.size.width < 620 ? 14 : 20)
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 430, idealHeight: 560)
        .background(AlignTheme.canvas)
        .task { await history.loadIfNeeded() }
        .onAppear { closeFocused = true }
        .sheet(isPresented: $showsMethod) { methodSheet }
        .confirmationDialog(
            "Effacer l’historique local ?",
            isPresented: $confirmsErase,
            titleVisibility: .visible
        ) {
            Button("Effacer l’historique", role: .destructive) {
                Task { await history.erase() }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Cette action supprime les statistiques enregistrées sur ce Mac.")
        }
    }

    private var viewState: StatisticsViewState {
        StatisticsPresenter.make(loadResult: history.loadResult, database: history.database, period: period, date: selectedDate, selectedSignal: selectedSignal)
    }

    private var header: some View {
        HStack {
            Text("Statistiques").font(.title2.weight(.semibold)); Spacer()
            Menu("Données…") {
                Button("Effacer l’historique local…", role: .destructive) {
                    confirmsErase = true
                }
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(AlignTheme.ivory)
            Button("Fermer", action: onClose).keyboardShortcut(.cancelAction).focused($closeFocused)
        }
    }

    private var navigation: some View {
        HStack {
            Button { move(-1) } label: { Label("Période précédente", systemImage: "chevron.left").labelStyle(.iconOnly) }
            Text(viewState.periodLabel).font(.headline).frame(maxWidth: .infinity)
            Button { move(1) } label: { Label("Période suivante", systemImage: "chevron.right").labelStyle(.iconOnly) }
                .disabled(selectedDate >= Calendar.current.startOfDay(for: Date()))
        }.controlSize(.small)
    }

    private var coverage: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Couverture fiable")
                    .font(.headline)
                    .foregroundStyle(AlignTheme.ivory)
                Spacer(minLength: 12)
                Text(viewState.coverageTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AlignTheme.accentSoft)
                    .multilineTextAlignment(.trailing)
            }
            Text(viewState.coverageDetail)
                .font(.caption)
                .foregroundStyle(AlignTheme.quiet)

            HStack(spacing: 14) {
                ForEach(viewState.coverageMetrics) { metric in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric.value)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(AlignTheme.ivory)
                        Text(metric.title)
                            .font(.caption2)
                            .foregroundStyle(AlignTheme.quiet)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 6)
        }
        .padding(12)
        .background(AlignTheme.elevated.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(AlignTheme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(viewState.coverageAccessibilityLabel)
    }

    private func insights(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Ce qui ressort")
                .font(.headline)
                .foregroundStyle(AlignTheme.ivory)
            ForEach(viewState.insights.prefix(limit)) { item in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(AlignTheme.accent)
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(AlignTheme.ivory)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(AlignTheme.quiet)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if viewState.insights.isEmpty {
                Label("Pas assez de périodes comparables pour dégager une tendance.", systemImage: "minus.circle")
                    .font(.callout)
                    .foregroundStyle(AlignTheme.quiet)
            }
        }
        .padding(12)
        .background(AlignTheme.elevated.opacity(0.24), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(AlignTheme.hairline, lineWidth: 1)
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Évolution")
                        .font(.headline)
                        .foregroundStyle(AlignTheme.ivory)
                    Text(StatisticsPresenter.title(selectedSignal))
                        .font(.caption)
                        .foregroundStyle(AlignTheme.quiet)
                }
                Spacer()
                Picker("Signal", selection: $selectedSignal) {
                    Text("Proximité").tag(PostureObservationSignalID.proximity)
                    Text("Torse").tag(PostureObservationSignalID.torsoInclination)
                    Text("Épaules relevées").tag(PostureObservationSignalID.raisedShoulders)
                    Text("Inclinaison épaules").tag(PostureObservationSignalID.shoulderSlope)
                    Text("Tête–épaules").tag(PostureObservationSignalID.closedShoulders)
                    Text("Tête penchée").tag(PostureObservationSignalID.headTilt)
                    Text("Clignements").tag(PostureObservationSignalID.estimatedBlinks)
                    Text("Main sur le visage").tag(PostureObservationSignalID.handOnFace)
                }
                .labelsHidden()
                .frame(maxWidth: 170)
            }
            Text(chartSubtitle)
                .font(.caption)
                .foregroundStyle(AlignTheme.quiet)

            if hasChartData {
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        Rectangle()
                            .fill(AlignTheme.hairline)
                            .frame(height: 1)
                        HStack(alignment: .bottom, spacing: 3) {
                            ForEach(viewState.series) { point in
                                Group {
                                    if let value = point.value, value.isFinite {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(AlignTheme.accent)
                                            .frame(height: chartBarHeight(for: value))
                                    } else {
                                        Capsule()
                                            .fill(AlignTheme.quiet.opacity(0.28))
                                            .frame(height: 6)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .bottom)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(chartPointLabel(point))
                            }
                        }
                    }
                    .frame(height: 82, alignment: .bottom)

                    HStack(spacing: 3) {
                        ForEach(Array(viewState.series.enumerated()), id: \.element.id) { index, point in
                            Text(shouldShowChartLabel(at: index) ? point.label : " ")
                                .font(.system(size: 8, weight: .medium, design: .rounded))
                                .foregroundStyle(AlignTheme.quiet)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: 105, alignment: .bottom)
            } else {
                chartEmptyState
            }
        }
        .padding(12)
        .background(AlignTheme.elevated.opacity(0.24), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(AlignTheme.hairline, lineWidth: 1)
        }
    }

    private var chartSubtitle: String {
        switch period {
        case .day: "24 heures · taux par heure observée"
        case .week: "7 jours · taux par heure observée"
        case .month: "Semaines du mois · taux par heure observée"
        }
    }

    private var hasChartData: Bool {
        viewState.series.contains { point in
            guard let value = point.value else { return false }
            return value.isFinite
        }
    }

    private var chartMaximum: Double {
        max(viewState.series.compactMap(\.value).filter(\.isFinite).max() ?? 1, 1)
    }

    private func chartBarHeight(for value: Double) -> CGFloat {
        let ratio = max(0, min(1, value / chartMaximum))
        return CGFloat(8 + (68 * ratio))
    }

    private func shouldShowChartLabel(at index: Int) -> Bool {
        switch period {
        case .day: index.isMultiple(of: 3) || index == viewState.series.count - 1
        case .week, .month: true
        }
    }

    private var chartEmptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title3)
                .foregroundStyle(AlignTheme.accent)
            Text("Pas encore de données fiables")
                .font(.callout.weight(.semibold))
                .foregroundStyle(AlignTheme.ivory)
            Text("Les périodes sans observation restent vides : elles ne sont pas comptées comme zéro.")
                .font(.caption)
                .foregroundStyle(AlignTheme.quiet)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
        }
        .frame(maxWidth: .infinity, minHeight: 105)
        .accessibilityElement(children: .combine)
    }

    private func chartPointLabel(_ point: StatisticsSeriesPoint) -> String {
        guard let value = point.value else { return "\(point.label), Données insuffisantes" }
        if selectedSignal == .estimatedBlinks {
            return String(format: "%@, %.1f clignements estimés par minute", point.label, value)
        }
        return String(format: "%@, %.1f variation par heure observée", point.label, value)
    }

    private func observations(compact: Bool) -> some View {
        DisclosureGroup(
            compact ? "Détail des huit observations" : "Observations",
            isExpanded: compact ? $compactDetailsExpanded : .constant(true)
        ) {
            VStack(spacing: 0) {
                ForEach(viewState.rows) { row in
                    Divider()
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(AlignTheme.accent.opacity(0.13))
                            Image(systemName: symbolName(for: row.id))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AlignTheme.accentSoft)
                        }
                        .frame(width: 27, height: 27)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(AlignTheme.ivory)
                            Text(row.primary)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(AlignTheme.accentSoft)
                            if row.id == .estimatedBlinks {
                                Text(viewState.blinkDetail)
                                    .font(.caption2)
                                    .foregroundStyle(AlignTheme.accent)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(row.secondary)
                            .font(.caption2)
                            .foregroundStyle(AlignTheme.quiet)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.accessibilityLabel)
                }
            }.padding(.top, 4)
        }
        .padding(12)
        .background(AlignTheme.elevated.opacity(0.24), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(AlignTheme.hairline, lineWidth: 1)
        }
        .tint(AlignTheme.accent)
    }

    private func symbolName(for id: PostureObservationSignalID) -> String {
        switch id {
        case .proximity: "viewfinder"
        case .torsoInclination: "figure.stand"
        case .raisedShoulders: "arrow.up.and.down"
        case .shoulderSlope: "line.diagonal"
        case .estimatedBlinks: "eye"
        case .closedShoulders: "arrow.left.and.right"
        case .headTilt: "arrow.turn.up.right"
        case .handOnFace: "hand.raised"
        }
    }

    private var emptyState: some View {
        let message: String = switch viewState.state {
        case .empty(let value), .insufficient(let value), .corrupt(let value), .unavailable(let value): value
        case .content, .loading: ""
        }
        let title: String = switch viewState.state {
        case .corrupt: "Historique illisible"
        case .unavailable: "Historique indisponible"
        case .loading: "Chargement des statistiques…"
        default: "Données insuffisantes"
        }
        return ContentUnavailableView(title, systemImage: "chart.xyaxis.line", description: Text(message))
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Chargement des statistiques…")
            Text("Chargement des statistiques…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
    }

    private var methodSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comprendre les données").font(.title2.weight(.semibold))
            Text("Les taux utilisent uniquement le temps réellement observé. Les trous ne sont ni interpolés ni comptés comme zéro.")
            Text("Clignements estimés").font(.headline)
            Text("Cette estimation utilise seulement les périodes où le visage et les deux yeux sont fiables. Ce n’est pas une mesure médicale.")
            HStack { Spacer(); Button("Fermer") { showsMethod = false }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 460)
    }

    private func move(_ value: Int) {
        let component: Calendar.Component = period == .day ? .day : (period == .week ? .weekOfYear : .month)
        if let next = Calendar.current.date(byAdding: component, value: value, to: selectedDate), next <= Date() { selectedDate = next }
    }
}
