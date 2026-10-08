import Fluent
import Vapor

/// The latest shared forecast for one subject/tracker pair in a nest.
///
/// The prediction is calculated by an entitled client using the nest's shared
/// event history, then stored here so every member sees the same result. The
/// server treats the payload as the canonical, nest-scoped presentation of
/// that forecast; private learning feedback never leaves the device.
final class NestForecast: Model, Content, @unchecked Sendable {
    static let schema = "nest_forecasts"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "nest_id")
    var nest: Nest

    @Parent(key: "entity_id")
    var entity: Entity

    @Parent(key: "action_id")
    var action: TrackableAction

    @OptionalParent(key: "generated_by_user_id")
    var generatedByUser: User?

    @Field(key: "predicted_at")
    var predictedAt: Date

    @Field(key: "baseline_predicted_at")
    var baselinePredictedAt: Date

    @OptionalField(key: "contextual_predicted_at")
    var contextualPredictedAt: Date?

    @Field(key: "model")
    var model: String

    @Field(key: "interval_hours")
    var intervalHours: Double

    @Field(key: "confidence")
    var confidence: Double

    @Field(key: "sample_count")
    var sampleCount: Int

    @Field(key: "validation_sample_count")
    var validationSampleCount: Int

    @OptionalField(key: "expected_error_hours")
    var expectedErrorHours: Double?

    @Field(key: "prediction_window_hours")
    var predictionWindowHours: Double

    @OptionalField(key: "target_names_json")
    var targetNamesJSON: String?

    @OptionalField(key: "input_names_json")
    var inputNamesJSON: String?

    @Field(key: "last_event_at")
    var lastEventAt: Date

    @Field(key: "computed_at")
    var computedAt: Date

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(nestID: UUID, entityID: UUID, actionID: UUID, generatedByUserID: UUID?,
         predictedAt: Date, baselinePredictedAt: Date, contextualPredictedAt: Date?,
         model: String, intervalHours: Double, confidence: Double, sampleCount: Int,
         validationSampleCount: Int, expectedErrorHours: Double?, predictionWindowHours: Double,
         targetNamesJSON: String?, inputNamesJSON: String?, lastEventAt: Date, computedAt: Date) {
        self.$nest.id = nestID
        self.$entity.id = entityID
        self.$action.id = actionID
        self.$generatedByUser.id = generatedByUserID
        self.predictedAt = predictedAt
        self.baselinePredictedAt = baselinePredictedAt
        self.contextualPredictedAt = contextualPredictedAt
        self.model = model
        self.intervalHours = intervalHours
        self.confidence = confidence
        self.sampleCount = sampleCount
        self.validationSampleCount = validationSampleCount
        self.expectedErrorHours = expectedErrorHours
        self.predictionWindowHours = predictionWindowHours
        self.targetNamesJSON = targetNamesJSON
        self.inputNamesJSON = inputNamesJSON
        self.lastEventAt = lastEventAt
        self.computedAt = computedAt
    }
}
