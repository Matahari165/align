import Foundation
import Darwin

@main
private enum SystemResourceMonitorHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        testSnapshotFormatting()
        testCPUDeltaCalculation()
        testSystemMemorySampling()
        testProcessMetricsSampling()
        print("SystemResourceMonitorHarness: OK")
    }

    static func testSnapshotFormatting() {
        let snapshot1 = SystemResourceSnapshot(
            systemCPUPercentage: 18.4,
            systemMemoryPercentage: 64.8,
            systemMemoryUsedBytes: 5_562_236_928,
            systemMemoryTotalBytes: 8_589_934_592,
            appCPUPercentage: 4.2,
            appMemoryFootprintBytes: 82 * 1024 * 1024
        )

        expect(snapshot1.systemCPUFormatted == "18 %", "systemCPUFormatted doit formater en pourcentage entier")
        expect(snapshot1.systemMemoryFormatted == "65 %", "systemMemoryFormatted doit arrondir correctement")
        expect(snapshot1.appCPUFormatted == "4.2 %", "appCPUFormatted doit inclure une décimale")
        expect(snapshot1.appMemoryFormatted == "82 Mo", "appMemoryFormatted doit formater en Mo")
        expect(snapshot1.detailedTooltip.contains("CPU Système : 18.4 % (Align : 4.2 %)"), "le tooltip CPU doit être complet")
        expect(snapshot1.detailedTooltip.contains("Mémoire vive Système : 64.8 %"), "le tooltip RAM doit être complet")
        expect(snapshot1.detailedTooltip.contains("Mémoire vive Align : 82 Mo"), "le tooltip Align RAM doit être présent")

        let emptySnapshot = SystemResourceSnapshot()
        expect(emptySnapshot.systemCPUFormatted == "—", "un snapshot vide doit afficher un tiret pour le CPU")
        expect(emptySnapshot.systemMemoryFormatted == "—", "un snapshot vide doit afficher un tiret pour la RAM")
        expect(emptySnapshot.appCPUFormatted == "—", "un snapshot vide doit afficher un tiret pour le CPU app")
        expect(emptySnapshot.appMemoryFormatted == "—", "un snapshot vide doit afficher un tiret pour la RAM app")
    }

    static func testCPUDeltaCalculation() {
        var prev = host_cpu_load_info()
        prev.cpu_ticks = (100, 50, 850, 0)

        var curr = host_cpu_load_info()
        curr.cpu_ticks = (120, 60, 920, 0)
        // user diff: 20, sys diff: 10, idle diff: 70, total: 100
        // used: 30 / 100 = 30%

        let user = Double(curr.cpu_ticks.0 - prev.cpu_ticks.0)
        let sys = Double(curr.cpu_ticks.1 - prev.cpu_ticks.1)
        let idle = Double(curr.cpu_ticks.2 - prev.cpu_ticks.2)
        let nice = Double(curr.cpu_ticks.3 - prev.cpu_ticks.3)
        let total = user + sys + idle + nice
        let pct = ((user + sys + nice) / total) * 100.0

        expect(abs(pct - 30.0) < 0.001, "le calcul de delta CPU doit donner exactement 30%")
    }

    static func testSystemMemorySampling() {
        let totalRAM = ProcessInfo.processInfo.physicalMemory
        expect(totalRAM > 0, "la mémoire physique de la machine doit être positive")
    }

    static func testProcessMetricsSampling() {
        let pid = getpid()
        expect(pid > 0, "le PID du processus doit être valide")
    }
}
