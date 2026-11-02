//
//  SystemLanguageModel.swift
//  swiftpy-llm
//

import Foundation
import SwiftPy
import FoundationModels

/// Apple Intelligence: the on-device model, Private Cloud Compute, or
/// whichever of the two is available.
@Scriptable(base: .LanguageModel)
@MainActor
public final class SystemLanguageModel {
    /// Where the model runs.
    public let location: SystemModelLocation

    // Once a request could not reach Private Cloud Compute, agents started
    // soon after go on-device instead of each failing the same way first; a
    // later one tries again, so a dropped connection is not the whole day.
    private static var privateCloudComputeFailedAt: Date?
    private static let privateCloudComputeRetryInterval: TimeInterval = 5 * 60

    private static var privateCloudComputeFailedRecently: Bool {
        guard let failedAt = privateCloudComputeFailedAt else { return false }
        return Date().timeIntervalSince(failedAt) < privateCloudComputeRetryInterval
    }

    /// A system model.
    ///
    /// location: Where the model runs. Defaults to None, ``agents/SystemModelLocation.AUTOMATIC``: Private Cloud Compute when it is available, the on-device model otherwise.
    public init(location: SystemModelLocation? = nil) {
        self.location = location ?? .automatic
    }

    /// The on-device model. It doesn't reason, so ``agents/Agent.respond`` ignores `reasoning` on it.
    public static func onDevice() -> SystemLanguageModel {
        SystemLanguageModel(location: .onDevice)
    }

    /// Private Cloud Compute, with no fall back to the on-device model.
    public static func privateCloudCompute() -> SystemLanguageModel {
        SystemLanguageModel(location: .privateCloudCompute)
    }

    /// Private Cloud Compute when it is available, the on-device model otherwise.
    public static func automatic() -> SystemLanguageModel {
        SystemLanguageModel(location: .automatic)
    }
}

extension SystemLanguageModel: CustomStringConvertible {
    public nonisolated var description: String {
        "<SystemLanguageModel location=SystemModelLocation.\(location.memberName)>"
    }
}

extension SystemLanguageModel: ModelProvider {
    package func resolve() throws(PythonError) -> (model: any FoundationModels.LanguageModel, name: String, reasons: Bool) {
        if location != .onDevice {
            let cloud = PrivateCloudComputeLanguageModel()
            if location == .privateCloudCompute {
                guard cloud.isAvailable else {
                    throw .RuntimeError("Private Cloud Compute is not available.")
                }
                return (cloud, "Private Cloud Compute", true)
            }
            if !Self.privateCloudComputeFailedRecently, cloud.isAvailable {
                return (cloud, "Private Cloud Compute", true)
            }
        }

        let onDevice = FoundationModels.SystemLanguageModel.default
        if case let .unavailable(reason) = onDevice.availability {
            throw .RuntimeError(Self.message(for: reason))
        }
        return (onDevice, "On-device", false)
    }

    package func fallback(
        after error: any Error,
        on model: any FoundationModels.LanguageModel
    ) -> (model: any FoundationModels.LanguageModel, name: String)? {
        guard location == .automatic,
              model is PrivateCloudComputeLanguageModel,
              Self.canRetryOnDevice(error) else { return nil }

        // No network, daily quota reached, the service down, or the app
        // not yet entitled. Said on stderr: the on-device answer reads
        // differently, and nothing else shows which model answered.
        Self.privateCloudComputeFailedAt = Date()
        _ = try? py.module("sys")?.throwing.stderr.write(
            "Private Cloud Compute did not answer (\(Self.describe(error))); continuing on the on-device model.\n"
        )
        return (FoundationModels.SystemLanguageModel.default, "On-device")
    }

    private static func message(for reason: FoundationModels.SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is not enabled."
        case .deviceNotEligible:
            "This device does not support Apple Intelligence."
        case .modelNotReady:
            "The model is not ready yet."
        @unknown default:
            "The model is unavailable."
        }
    }

    /// The innermost error: the ones around it say "error -1" and little
    /// else, the inner one carries the code that names the cause.
    private static func describe(_ error: any Error) -> String {
        var inner = error as NSError
        while let next = inner.underlyingErrors.first as NSError? {
            inner = next
        }
        return "\(inner.domain) \(inner.code)"
    }

    /// Whether a failure is about reaching the model rather than about what
    /// was asked: the on-device model gives the same answer to the latter.
    private static func canRetryOnDevice(_ error: any Error) -> Bool {
        if error is GeneratedContent.ParsingError {
            return false
        }
        guard let modelError = error as? LanguageModelError else {
            return true
        }
        switch modelError {
        case .guardrailViolation, .refusal, .contextSizeExceeded,
             .unsupportedGenerationGuide, .unsupportedLanguageOrLocale:
            return false
        default:
            return true
        }
    }
}

/// Where a ``agents.SystemLanguageModel`` runs, as the `agents.SystemModelLocation`
/// enum defined in `agents.py`.
public enum SystemModelLocation: String, Sendable {
    case automatic
    case onDevice = "on-device"
    case privateCloudCompute = "private-cloud-compute"

    nonisolated var memberName: String {
        switch self {
        case .automatic: "AUTOMATIC"
        case .onDevice: "ON_DEVICE"
        case .privateCloudCompute: "PRIVATE_CLOUD_COMPUTE"
        }
    }
}

@MainActor
extension SystemModelLocation: PythonConvertible {
    // Looked up once `agents` has defined it; the module keeps the type alive.
    private static var enumType: PyObject? {
        py.module("agents")?.SystemModelLocation
    }

    public static var pyType: PyType {
        enumType.flatMap { PyType($0) } ?? .object
    }

    public static func isConvertible(_ reference: PyRef) -> Bool {
        enumType != nil && pyType.isInstance(reference)
    }

    public static func fromPython(_ reference: PyRef) -> SystemModelLocation {
        let value: String? = PyObject(retaining: reference).value
        return value.flatMap(SystemModelLocation.init(rawValue:)) ?? .automatic
    }

    public func toPython() throws(PythonError) -> PyObject {
        guard let enumType = Self.enumType else {
            throw .ImportError("agents.SystemModelLocation is not defined")
        }
        return try enumType(rawValue)
    }
}
