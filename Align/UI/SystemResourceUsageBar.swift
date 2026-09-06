import SwiftUI

struct SystemResourceUsageBar: View {
    @ObservedObject var monitor: SystemResourceMonitor

    var body: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 8)

            // CPU
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                    .font(.caption2)
                    .foregroundStyle(AlignTheme.accent)
                Text("CPU")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AlignTheme.quiet)
                Text(monitor.snapshot.systemCPUFormatted)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(cpuValueColor)
                Text("(Align \(monitor.snapshot.appCPUFormatted))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AlignTheme.quiet.opacity(0.85))
            }

            Text("•")
                .font(.caption2)
                .foregroundStyle(AlignTheme.hairline)

            // RAM
            HStack(spacing: 5) {
                Image(systemName: "memorychip")
                    .font(.caption2)
                    .foregroundStyle(AlignTheme.accent)
                Text("RAM")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AlignTheme.quiet)
                Text(monitor.snapshot.systemMemoryFormatted)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(memoryValueColor)
                Text("(Align \(monitor.snapshot.appMemoryFormatted))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AlignTheme.quiet.opacity(0.85))
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: 28)
        .background(AlignTheme.canvas)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AlignTheme.hairline)
                .frame(height: 1)
        }
        .help(monitor.snapshot.detailedTooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ressources système. CPU \(monitor.snapshot.systemCPUFormatted), Align \(monitor.snapshot.appCPUFormatted). Mémoire vive \(monitor.snapshot.systemMemoryFormatted), Align \(monitor.snapshot.appMemoryFormatted).")
    }

    private var cpuValueColor: Color {
        guard let cpu = monitor.snapshot.systemCPUPercentage else { return AlignTheme.ivory }
        return cpu >= 85.0 ? AlignTheme.attention : AlignTheme.ivory
    }

    private var memoryValueColor: Color {
        guard let ram = monitor.snapshot.systemMemoryPercentage else { return AlignTheme.ivory }
        return ram >= 85.0 ? AlignTheme.attention : AlignTheme.ivory
    }
}
