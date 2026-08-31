import SwiftUI

struct StatisticsView: View {
    @ObservedObject var history: PostureHistoryController
    let onClose: () -> Void
    @State private var period: PostureHistoryPeriod = .day
    @State private var selectedDate = Date()
    @State private var selectedSignal: PostureObservationSignalID = .torsoInclination
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
            Text("Couverture fiable").font(.headline)
            Text(viewState.coverageTitle).font(.title3.weight(.medium))
            Text(viewState.coverageDetail).font(.callout).foregroundStyle(.secondary)
            Rectangle().fill(AlignTheme.copper.opacity(0.48)).frame(height: 3)
        }.accessibilityElement(children: .ignore).accessibilityLabel(viewState.coverageAccessibilityLabel)
    }

    private func insights(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Ce qui ressort").font(.headline)
            ForEach(viewState.insights.prefix(limit)) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.callout.weight(.semibold))
                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
            }
            if viewState.insights.isEmpty {
                Text("Pas assez de périodes comparables pour dégager une tendance.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Évolution").font(.headline)
                Spacer()
                Picker("Signal", selection: $selectedSignal) {
                    Text("Proximité").tag(PostureObservationSignalID.proximity)
                    Text("Torse").tag(PostureObservationSignalID.torsoInclination)
                    Text("Épaules relevées").tag(PostureObservationSignalID.raisedShoulders)
                    Text("Inclinaison épaules").tag(PostureObservationSignalID.shoulderSlope)
                    Text("Épaules refermées").tag(PostureObservationSignalID.closedShoulders)
                    Text("Clignements").tag(PostureObservationSignalID.estimatedBlinks)
                }
                .labelsHidden()
                .frame(maxWidth: 170)
            }
            Text(period == .day ? "Par heure observée" : period == .week ? "Sept jours" : "Par semaine").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(viewState.series) { point in
                    VStack(spacing: 3) {
                        if let value = point.value {
                            RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(height: max(4, min(78, value * 12)))
                        } else {
                            Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 2])).foregroundStyle(.secondary).frame(height: 12)
                        }
                        Text(point.label).font(.system(size: 8)).lineLimit(1)
                    }.frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(chartPointLabel(point))
                }
            }.frame(height: 105, alignment: .bottom)
        }
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
            compact ? "Détail des six observations" : "Observations",
            isExpanded: compact ? $compactDetailsExpanded : .constant(true)
        ) {
            VStack(spacing: 0) {
                ForEach(viewState.rows) { row in
                    Divider()
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) { Text(row.title).font(.callout.weight(.semibold)); if row.experimental { Text("Expérimental").font(.caption2).foregroundStyle(AlignTheme.copper) } }
                            Text(row.primary).font(.caption)
                            if row.id == .estimatedBlinks {
                                Text(viewState.blinkDetail)
                                    .font(.caption2)
                                    .foregroundStyle(AlignTheme.copper)
                            }
                        }
                        Spacer(); Text(row.secondary).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }.padding(.vertical, 6).accessibilityElement(children: .ignore).accessibilityLabel(row.accessibilityLabel)
                }
            }.padding(.top, 4)
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
