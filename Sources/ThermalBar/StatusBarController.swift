import AppKit
import Foundation

class StatusBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var interval: TimeInterval = 5

    private let hid = IOHIDThermalReader()   // Apple Silicon (M-series)
    private let smc = SMCReader()            // Intel fallback
    private let cpu = CPUMonitor()
    private let gpu = GPUMonitor()

    private var useHID = false

    private var tempItem: NSMenuItem!
    private var cpuItem:  NSMenuItem!
    private var gpuItem:  NSMenuItem!

    // Six fixed-position labels: one header + one value per column
    private var tempHeader: NSTextField?
    private var cpuHeader:  NSTextField?
    private var gpuHeader:  NSTextField?
    private var tempValue:  NSTextField?
    private var cpuValue:   NSTextField?
    private var gpuValue:   NSTextField?

    init() {
        // Try Apple Silicon IOHIDEventSystem first; fall back to Intel SMC
        useHID = hid.setup()
        if !useHID { _ = smc.open() }
        buildMenu()
        setupButtonView()
        refresh()
        startTimer()
    }

    func stop() {
        timer?.invalidate()
        if useHID { hid.close() } else { smc.close() }
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()

        menu.addItem(sectionHeader("Temperature"))
        tempItem = detail("–")
        menu.addItem(tempItem)
        menu.addItem(.separator())

        menu.addItem(sectionHeader("CPU"))
        cpuItem = detail("–")
        menu.addItem(cpuItem)
        menu.addItem(.separator())

        menu.addItem(sectionHeader("GPU"))
        gpuItem = detail("–")
        menu.addItem(gpuItem)
        menu.addItem(.separator())

        menu.addItem(sectionHeader("Refresh"))
        for s in [1, 2, 5, 10, 30] {
            let item = NSMenuItem(
                title: "Every \(s)s",
                action: #selector(setInterval(_:)),
                keyEquivalent: "")
            item.tag    = s
            item.target = self
            item.state  = (TimeInterval(s) == interval) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func sectionHeader(_ t: String) -> NSMenuItem {
        let item = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func detail(_ t: String) -> NSMenuItem {
        let item = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        statusItem.menu?.items.forEach { if $0.tag > 0 { $0.state = .off } }
        sender.state = .on
        interval = TimeInterval(sender.tag)
        startTimer()
    }

    // MARK: - Timer

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Refresh

    private func refresh() {
        let temp   = useHID ? hid.cpuTemperature() : smc.cpuTemperature()
        let cpuPct = cpu.usage()
        let gpuPct = gpu.usage()
        DispatchQueue.main.async { [weak self] in
            self?.updateButton(temp: temp, cpuPct: cpuPct, gpuPct: gpuPct)
            self?.updateMenuItems(temp: temp, cpuPct: cpuPct, gpuPct: gpuPct)
        }
    }

    // MARK: - Button: two-row, three-column layout
    //
    //   TEMP    CPU    GPU     ← 7pt secondary color, each in its own fixed column
    //   72°     34%    18%     ← 11pt monospaced; temp in heat color

    private static let colWidth:    CGFloat = 32   // px per column
    private static let buttonWidth: CGFloat = colWidth * 3   // = 96

    private func setupButtonView() {
        guard let button = statusItem.button else { return }
        button.title = ""
        statusItem.length = Self.buttonWidth

        let cw = Self.colWidth
        let headerFont = NSFont.monospacedSystemFont(ofSize: 7, weight: .regular)
        let valueFont  = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

        func makeLabel(title: String, font: NSFont, color: NSColor, x: CGFloat, y: CGFloat, h: CGFloat) -> NSTextField {
            let f = NSTextField(labelWithString: title)
            f.font      = font
            f.textColor = color
            f.alignment = .center
            f.frame     = NSRect(x: x, y: y, width: cw, height: h)
            return f
        }

        // Flipped coords: y=1 → near top, y=11 → below
        let th = makeLabel(title: "TEMP", font: headerFont, color: .secondaryLabelColor, x: 0,    y: 1,  h: 9)
        let ch = makeLabel(title: "CPU",  font: headerFont, color: .secondaryLabelColor, x: cw,   y: 1,  h: 9)
        let gh = makeLabel(title: "GPU",  font: headerFont, color: .secondaryLabelColor, x: cw*2, y: 1,  h: 9)
        let tv = makeLabel(title: "--",   font: valueFont,  color: .labelColor,          x: 0,    y: 11, h: 11)
        let cv = makeLabel(title: "--",   font: valueFont,  color: .labelColor,          x: cw,   y: 11, h: 11)
        let gv = makeLabel(title: "--",   font: valueFont,  color: .labelColor,          x: cw*2, y: 11, h: 11)

        for v in [th, ch, gh, tv, cv, gv] { button.addSubview(v) }
        tempHeader = th; cpuHeader = ch; gpuHeader = gh
        tempValue  = tv; cpuValue  = cv; gpuValue  = gv
    }

    private func updateButton(temp: Double?, cpuPct: Double, gpuPct: Double?) {
        let tempStr = temp.map { "\(Int($0.rounded()))°" } ?? "--"
        let cpuStr  = "\(Int(cpuPct.rounded()))%"
        let gpuStr  = gpuPct.map { "\(Int($0.rounded()))%" } ?? "--"

        tempValue?.stringValue = tempStr
        tempValue?.textColor   = temp.map { heatColor($0) } ?? .labelColor
        cpuValue?.stringValue  = cpuStr
        gpuValue?.stringValue  = gpuStr
    }

    private func updateMenuItems(temp: Double?, cpuPct: Double, gpuPct: Double?) {
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        func row(_ label: String, _ value: String, _ progress: String) -> NSAttributedString {
            NSAttributedString(string: "\(label)  \(value)  \(progress)", attributes: [.font: mono])
        }

        if let t = temp {
            tempItem.attributedTitle = row(
                "CPU Die", String(format: "%.1f°C", t), bar(t, lo: 40, hi: 100))
        } else {
            tempItem.attributedTitle = row("CPU Die", "n/a", "─────")
        }

        cpuItem.attributedTitle = row(
            "Total  ", "\(Int(cpuPct.rounded()))%   ", bar(cpuPct, lo: 0, hi: 100))

        if let g = gpuPct {
            gpuItem.attributedTitle = row(
                "Render ", "\(Int(g.rounded()))%   ", bar(g, lo: 0, hi: 100))
        } else {
            gpuItem.attributedTitle = row("Render ", "n/a", "─────")
        }
    }

    // MARK: - Helpers

    private func bar(_ value: Double, lo: Double, hi: Double) -> String {
        let ratio  = max(0, min(1, (value - lo) / (hi - lo)))
        let filled = Int((ratio * 5).rounded())
        return String(repeating: "█", count: filled)
             + String(repeating: "░", count: 5 - filled)
    }

    /// Cool (50°C) → warm (70°C) → hot (90°C)
    /// Below 50°C:  white/label color (no blue tint)
    /// 50–70°C:     white → orange
    /// 70–90°C:     orange → red
    private func heatColor(_ temp: Double) -> NSColor {
        switch temp {
        case ..<50:
            return .labelColor
        case 50..<70:
            let t = (temp - 50) / 20   // 0→1
            return NSColor(red: 1, green: CGFloat(1 - t * 0.5), blue: CGFloat(1 - t), alpha: 1)
        default:
            let t = max(0, min(1, (temp - 70) / 20))  // 0→1
            return NSColor(red: 1, green: CGFloat(0.5 - t * 0.5), blue: 0, alpha: 1)
        }
    }
}
