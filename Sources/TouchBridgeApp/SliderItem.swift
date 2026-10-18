import AppKit

/// Menüeintrag mit Beschriftung, Schieberegler und Prozentanzeige.
final class SliderItemView: NSView {
    let slider: NSSlider
    private let label = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    var onChange: ((Int) -> Void)?

    init(title: String, symbol: String, value: Int, enabled: Bool = true) {
        slider = NSSlider(value: Double(value), minValue: 0, maxValue: 100, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 270, height: 46))
        label.stringValue = title
        label.font = .menuFont(ofSize: 0)
        label.textColor = enabled ? .labelColor : .disabledControlTextColor
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        slider.isContinuous = true
        slider.isEnabled = enabled
        slider.target = self
        slider.action = #selector(changed)
        let icon = NSImageView()
        if #available(macOS 11.0, *) { icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        icon.contentTintColor = .secondaryLabelColor
        for v in [label, valueLabel, slider, icon] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            valueLabel.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            slider.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            slider.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
        ])
        update(value)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ v: Int) {
        slider.integerValue = v
        valueLabel.stringValue = "\(v) %"
    }

    @objc private func changed() {
        valueLabel.stringValue = "\(slider.integerValue) %"
        onChange?(slider.integerValue)
    }
}
