//
//  NodesView.swift
//  OnYourMarks
//
//  The other phones and how well their clocks are known. The first
//  measuring instrument of the synchronization: every number is the one
//  the estimator works with.
//

import SwiftUI

struct NodesView: View {
    @Environment(NodeSession.self) private var session
    @State private var name = ""

    var body: some View {
        ZStack {
            TrackBackground()
            Form {
                thisPhone

                Section("Paired phones") {
                    let paired = session.sortedPeers.filter { $0.isPaired }

                    if paired.isEmpty {
                        Text("No paired phones.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(paired) { peer in
                        PeerRow(peer: peer)
                            .swipeActions {
                                Button("Unpair", role: .destructive) { session.unpair(peer.id) }
                            }
                    }
                }

                Section {
                    let nearby = session.sortedPeers.filter { !$0.isPaired && $0.isReachable }

                    if nearby.isEmpty {
                        Text("No other phones found. They need this screen open with Connect switched on.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(nearby) { peer in
                        HStack {
                            PeerTitle(peer: peer)
                            Spacer()
                            Button("Pair") { session.pair(peer.id) }
                                .accessibilityIdentifier("pairButton")
                        }
                    }

                    if session.incompatibleCount > 0 {
                        Text("Phones with another app version: \(session.incompatibleCount)")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Nearby phones")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Phones")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = session.identity.name }
    }

    private var thisPhone: some View {
        Section {
            TextField("Name", text: $name)
                .onSubmit { session.update(name: name, role: session.identity.role) }

            Picker("Role", selection: Binding(get: { session.identity.role }, set: { session.update(name: name, role: $0) })) {
                ForEach(NodeRole.allCases, id: \.self) { role in
                    Text(role.displayName).tag(role)
                }
            }

            LabeledContent("Code", value: session.identity.id.shortCode)

            Toggle("Connect to other phones", isOn: Binding(get: { session.isRunning }, set: { $0 ? session.start() : session.stop() }))
                .accessibilityIdentifier("connectPhonesToggle")

            if case .failed(let reason) = session.transportState {
                Text(reason)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("This phone")
        } footer: {
            Text("The other phones show this code next to this phone's name. Paired phones synchronize their clocks ten times a second.")
        }
    }
}

private struct PeerTitle: View {
    let peer: NodePeer

    var body: some View {
        VStack(alignment: .leading) {
            Text(peer.name)
            Text("\(peer.id.shortCode) · \(peer.role?.displayName ?? String(localized: "Unknown"))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PeerRow: View {
    @Environment(NodeSession.self) private var session
    let peer: NodePeer

    /// The interval ages between exchanges; shown twice a second so its
    /// width is the one that holds now.
    private static let refresh: TimeInterval = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                PeerTitle(peer: peer)
                Spacer()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TimelineView(.periodic(from: .now, by: Self.refresh)) { _ in
                LabeledContent("Offset interval", value: Self.milliseconds(session.offset(for: peer.id)?.width))
            }

            LabeledContent("Round trip (last, min, median)", value: roundTrips)

            if let rate = peer.estimator.rate {
                LabeledContent("Rate", value: "\(Self.ppm(rate.best)) (\(Self.ppm(rate.lower)) … \(Self.ppm(rate.upper)))")
            }

            LabeledContent("Exchanges (sent, lost)", value: "\(peer.counts.sent), \(peer.counts.lost)")

            if let lead = Self.median(peer.kernelLeads) {
                LabeledContent("Kernel lead", value: Self.milliseconds(lead))
            }

            if peer.violationCount > 0 {
                LabeledContent("Assumptions violated", value: "\(peer.violationCount)")
                    .foregroundStyle(.red)
            }

            if peer.restartCount > 0 {
                LabeledContent("Clock restarts", value: "\(peer.restartCount)")
            }
        }
        .font(.callout)
        .monospacedDigit()
    }

    private var status: String {
        if !peer.isReachable {
            String(localized: "Not reachable")
        } else if session.mapping(for: peer.id) != nil {
            String(localized: "Synchronized")
        } else if peer.violationCount > 0 {
            String(localized: "Clock not trusted")
        } else {
            String(localized: "Waiting for its clock")
        }
    }

    private var roundTrips: String {
        [peer.roundTrips.last, peer.roundTrips.min(), Self.median(peer.roundTrips)]
            .map { Self.milliseconds($0) }
            .joined(separator: ", ")
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval? {
        values.isEmpty ? nil : values.sorted()[values.count / 2]
    }

    private static func milliseconds(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "–" }
        return (seconds * 1_000).formatted(.number.precision(.fractionLength(3))) + " ms"
    }

    private static func ppm(_ rate: Double) -> String {
        (rate * 1e6).formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())) + " ppm"
    }
}

extension NodeRole {
    var displayName: String {
        switch self {
        case .controller: String(localized: "Controller")
        case .camera: String(localized: "Camera")
        case .speaker: String(localized: "Speaker")
        }
    }
}
