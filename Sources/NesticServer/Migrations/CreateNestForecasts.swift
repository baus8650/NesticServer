import Fluent

struct CreateNestForecasts: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("nest_forecasts")
            .id()
            .field("nest_id", .uuid, .required, .references("nests", "id", onDelete: .cascade))
            .field("entity_id", .uuid, .required, .references("entities", "id", onDelete: .cascade))
            .field("action_id", .uuid, .required, .references("trackable_actions", "id", onDelete: .cascade))
            .field("generated_by_user_id", .uuid, .references("users", "id", onDelete: .setNull))
            .field("predicted_at", .datetime, .required)
            .field("baseline_predicted_at", .datetime, .required)
            .field("contextual_predicted_at", .datetime)
            .field("model", .string, .required)
            .field("interval_hours", .double, .required)
            .field("confidence", .double, .required)
            .field("sample_count", .int, .required)
            .field("validation_sample_count", .int, .required)
            .field("expected_error_hours", .double)
            .field("prediction_window_hours", .double, .required)
            .field("target_names_json", .string)
            .field("input_names_json", .string)
            .field("last_event_at", .datetime, .required)
            .field("computed_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "nest_id", "entity_id", "action_id")
            .create()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("nest_forecasts").delete()
    }
}
