import SwiftUI

/// The column/row of professional parameter cards (ISO, shutter, WB, focus, aperture).
struct ParameterCards: View {
    @Bindable var model: CameraViewModel
    var compact: Bool

    var body: some View {
        let t = model.telemetry
        Group {
            ParameterCard(title: "ISO", value: "\(Int(model.isoAuto ? t.iso : model.isoValue))", isAuto: model.isoAuto,
                          isActive: model.activePanel == .iso, compact: compact,
                          onToggleAuto: { model.isoAuto.toggle(); if !model.isoAuto { model.isoValue = t.iso }; model.reapplyExposure() },
                          onTap: { toggle(.iso) })
            ParameterCard(title: "SHUTTER", value: shutterValue, isAuto: model.shutterAuto,
                          isActive: model.activePanel == .shutter,
                          badge: model.priorityIsEmulated ? "EMUL" : nil, compact: compact,
                          onToggleAuto: { model.shutterAuto.toggle(); if !model.shutterAuto { model.shutterSeconds = t.exposureSeconds }; model.reapplyExposure() },
                          onTap: { toggle(.shutter) })
            if let range = model.format?.lensApertureRange {
                ParameterCard(title: "APERTURE", value: String(format: "f/%.1f", model.apertureAuto ? t.aperture : model.apertureValue),
                              isAuto: model.apertureAuto, isActive: model.activePanel == .aperture, compact: compact,
                              onToggleAuto: { model.apertureAuto.toggle(); if !model.apertureAuto { model.apertureValue = max(range.lowerBound, t.aperture) }; model.applyAperture() },
                              onTap: { toggle(.aperture) })
            } else {
                // Fixed-aperture lens: shown read-only, never presented as adjustable.
                ParameterCard(title: "APERTURE", value: String(format: "f/%.2g", t.aperture > 0 ? t.aperture : (model.camera?.fixedAperture ?? 0)),
                              isAuto: false, badge: "FIXA", compact: compact, onToggleAuto: {}, onTap: {})
                    .opacity(0.75)
            }
            ParameterCard(title: "WB", value: "\(Int(model.wbAuto ? t.kelvin : model.kelvin))K", isAuto: model.wbAuto,
                          isActive: model.activePanel == .whiteBalance, compact: compact,
                          onToggleAuto: { model.wbAuto.toggle(); if !model.wbAuto { model.kelvin = (t.kelvin / 100).rounded() * 100 }; model.applyWhiteBalance() },
                          onTap: { toggle(.whiteBalance) })
            ParameterCard(title: "FOCUS", value: model.focusAuto ? (t.isAdjustingFocus ? "···" : "AF") : String(format: "%.2f", model.focusPosition),
                          isAuto: model.focusAuto, isActive: model.activePanel == .focus, compact: compact,
                          onToggleAuto: { model.focusAuto.toggle(); if !model.focusAuto { model.focusPosition = t.lensPosition }; model.applyFocus() },
                          onTap: { toggle(.focus) })
            ParameterCard(title: "EV", value: String(format: "%+.1f", model.exposureBias), isAuto: !model.aeLocked,
                          isActive: model.activePanel == .exposureBias, badge: model.aeLocked ? "AE-L" : nil, compact: compact,
                          onToggleAuto: { model.aeLocked.toggle(); model.engine.setAutoExposureLock(model.aeLocked) },
                          onTap: { toggle(.exposureBias) })
        }
    }

    private var shutterValue: String {
        let seconds = model.shutterAuto ? model.telemetry.exposureSeconds : model.shutterSeconds
        if model.showShutterAsAngle {
            return ExposureMath.angleLabel(ExposureMath.shutterAngle(exposure: seconds, fps: model.configuration.frameRate))
        }
        return ExposureMath.shutterLabel(seconds)
    }

    private func toggle(_ panel: ParameterPanel) {
        withAnimation(.snappy) { model.activePanel = model.activePanel == panel ? nil : panel }
    }
}

/// Fine adjustment panel shown above the preview for the selected parameter.
struct ParameterAdjustPanel: View {
    @Bindable var model: CameraViewModel
    let panel: ParameterPanel
    @State private var index = 0
    @State private var focusA: Float?
    @State private var focusB: Float?
    @State private var zoomSpeed: Float = 2

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(Theme.label(11)).foregroundStyle(Theme.textSecondary)
                Spacer()
                accessory
                Button { withAnimation(.snappy) { model.activePanel = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.card))
                }.buttonStyle(.plain)
            }
            dial
            extra
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Color.black.opacity(0.85)))
        .onAppear(perform: syncIndex)
        .onChange(of: model.showShutterAsAngle) { syncIndex() }
    }

    private var title: String {
        switch panel {
        case .iso: "ISO \(Int(model.isoRange.lowerBound))–\(Int(model.isoRange.upperBound))"
        case .shutter: model.showShutterAsAngle ? "SHUTTER ANGLE @ \(FrameRateFormatter.string(model.configuration.frameRate)) FPS" : "SHUTTER SPEED"
        case .whiteBalance: "WHITE BALANCE"
        case .focus: "FOCUS — 0 perto · 1 longe"
        case .aperture: "APERTURE"
        case .exposureBias: "EXPOSURE COMPENSATION"
        case .zoom: "ZOOM"
        }
    }

    @ViewBuilder private var accessory: some View {
        switch panel {
        case .shutter:
            ChipButton(title: model.showShutterAsAngle ? "ANGLE" : "SPEED", isOn: true) { model.showShutterAsAngle.toggle() }
        case .exposureBias:
            ChipButton(title: "AE LOCK", isOn: model.aeLocked) { model.aeLocked.toggle(); model.engine.setAutoExposureLock(model.aeLocked) }
        case .focus:
            ChipButton(title: "PEAKING", isOn: model.monitoring.peakingEnabled) { model.monitoring.peakingEnabled.toggle() }
        default: EmptyView()
        }
    }

    private var dialValues: [String] {
        switch panel {
        case .iso: model.isoSteps.map { "\(Int($0))" }
        case .shutter: model.showShutterAsAngle ? model.angleSteps.map(ExposureMath.angleLabel) : model.shutterSteps.map(ExposureMath.shutterLabel)
        case .whiteBalance: ExposureMath.kelvinSteps.map { "\(Int($0))K" }
        case .focus: (0...100).map { String(format: "%.2f", Double($0) / 100) }
        case .aperture: apertureStops.map { String(format: "f/%.1f", $0) }
        case .exposureBias: biasSteps.map { String(format: "%+.1f", $0) }
        case .zoom: zoomSteps.map { String(format: "%.1f×", $0 * (model.camera?.displayZoomMultiplier ?? 1)) }
        }
    }

    private var dial: some View {
        let values = dialValues
        return StepDial(count: max(values.count, 1), index: $index, label: { values.indices.contains($0) ? values[$0] : "—" })
            .onChange(of: index) { _, new in apply(new) }
    }

    @ViewBuilder private var extra: some View {
        switch panel {
        case .whiteBalance:
            HStack(spacing: 8) {
                ForEach([(Float(3200), "lightbulb"), (4000, "light.panel"), (5600, "sun.max"), (6500, "cloud"), (7500, "building")], id: \.0) { k, icon in
                    Button { model.kelvin = k; model.wbAuto = false; model.applyWhiteBalance(); syncIndex() } label: {
                        Image(systemName: icon).frame(width: 36, height: 36)
                            .background(Circle().fill(!model.wbAuto && model.kelvin == k ? Theme.accent : Theme.card))
                            .foregroundStyle(!model.wbAuto && model.kelvin == k ? .black : .white)
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("TINT").font(Theme.label(9)).foregroundStyle(Theme.textSecondary)
                Slider(value: $model.tint, in: -50...50, step: 1) { _ in model.wbAuto = false; model.applyWhiteBalance() }
                    .frame(maxWidth: 120).tint(Theme.accent)
            }
        case .focus:
            HStack(spacing: 8) {
                ChipButton(title: focusA.map { String(format: "A %.2f", $0) } ?? "SET A") { focusA = model.focusPosition }
                ChipButton(title: focusB.map { String(format: "B %.2f", $0) } ?? "SET B") { focusB = model.focusPosition }
                Spacer()
                ChipButton(title: "RACK", systemImage: "arrow.left.arrow.right") {
                    guard let a = focusA, let b = focusB else { return }
                    let target = abs(model.focusPosition - a) < abs(model.focusPosition - b) ? b : a
                    model.focusAuto = false
                    model.focusPosition = target
                    model.applyFocus(rackDuration: 1.5)
                    syncIndex()
                }
            }
        case .zoom:
            HStack {
                Text("VELOCIDADE").font(Theme.label(9)).foregroundStyle(Theme.textSecondary)
                Slider(value: $zoomSpeed, in: 0.5...8).tint(Theme.accent)
            }
        default: EmptyView()
        }
    }

    private var apertureStops: [Float] {
        guard let range = model.format?.lensApertureRange else { return [] }
        let stops = model.format?.recommendedApertureStops ?? []
        if !stops.isEmpty { return stops.sorted() }
        return stride(from: range.lowerBound, through: range.upperBound, by: 0.1).map { $0 }
    }

    private var biasSteps: [Float] { stride(from: Float(-3), through: 3, by: 1.0 / 3).map { ($0 * 10).rounded() / 10 } }

    private var zoomSteps: [Double] {
        let maxZ = min(model.camera?.maxZoom ?? 10, 15 * (model.camera?.minZoom ?? 1))
        return stride(from: model.camera?.minZoom ?? 1, through: maxZ, by: 0.1).map { $0 }
    }

    private func syncIndex() {
        func nearest<T: BinaryFloatingPoint>(_ list: [T], _ v: T) -> Int {
            list.indices.min { abs(list[$0] - v) < abs(list[$1] - v) } ?? 0
        }
        let t = model.telemetry
        switch panel {
        case .iso: index = nearest(model.isoSteps, model.isoAuto ? t.iso : model.isoValue)
        case .shutter:
            let s = model.shutterAuto ? t.exposureSeconds : model.shutterSeconds
            index = model.showShutterAsAngle
                ? nearest(model.angleSteps, ExposureMath.shutterAngle(exposure: s, fps: model.configuration.frameRate))
                : nearest(model.shutterSteps, s)
        case .whiteBalance: index = nearest(ExposureMath.kelvinSteps, model.wbAuto ? t.kelvin : model.kelvin)
        case .focus: index = Int(((model.focusAuto ? t.lensPosition : model.focusPosition) * 100).rounded())
        case .aperture: index = nearest(apertureStops, model.apertureAuto ? t.aperture : model.apertureValue)
        case .exposureBias: index = nearest(biasSteps, model.exposureBias)
        case .zoom: index = nearest(zoomSteps, t.zoom)
        }
    }

    private func apply(_ i: Int) {
        switch panel {
        case .iso:
            guard model.isoSteps.indices.contains(i) else { return }
            model.isoValue = model.isoSteps[i]; model.isoAuto = false; model.reapplyExposure()
        case .shutter:
            if model.showShutterAsAngle {
                guard model.angleSteps.indices.contains(i) else { return }
                model.setShutterAngle(model.angleSteps[i])
            } else {
                guard model.shutterSteps.indices.contains(i) else { return }
                model.shutterSeconds = model.shutterSteps[i]; model.shutterAuto = false; model.reapplyExposure()
            }
        case .whiteBalance:
            model.kelvin = ExposureMath.kelvinSteps[min(i, ExposureMath.kelvinSteps.count - 1)]; model.wbAuto = false; model.applyWhiteBalance()
        case .focus:
            model.focusPosition = Float(i) / 100; model.focusAuto = false; model.applyFocus()
        case .aperture:
            guard apertureStops.indices.contains(i) else { return }
            model.apertureValue = apertureStops[i]; model.apertureAuto = false; model.applyAperture()
        case .exposureBias:
            guard biasSteps.indices.contains(i) else { return }
            model.exposureBias = biasSteps[i]; model.engine.setExposureBias(model.exposureBias)
        case .zoom:
            guard zoomSteps.indices.contains(i) else { return }
            model.engine.setZoom(zoomSteps[i], rate: zoomSpeed)
        }
    }
}
