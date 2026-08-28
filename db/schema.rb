# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2026_08_28_062000) do
  create_schema "agent_transport"
  create_schema "evolution_api"
  create_schema "mastra_agent"

  # These extensions should be enabled to support this database
  enable_extension "pg_stat_statements"
  enable_extension "pg_trgm"
  enable_extension "pgcrypto"
  enable_extension "plpgsql"
  enable_extension "vector"

  create_table "access_tokens", force: :cascade do |t|
    t.string "owner_type"
    t.bigint "owner_id"
    t.string "token"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_type", "owner_id"], name: "index_access_tokens_on_owner_type_and_owner_id"
    t.index ["token"], name: "index_access_tokens_on_token", unique: true
  end

  create_table "account_saml_settings", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "sso_url"
    t.text "certificate"
    t.string "sp_entity_id"
    t.string "idp_entity_id"
    t.json "role_mappings", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_account_saml_settings_on_account_id"
  end

  create_table "account_user_lifecycle_snapshots", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "user_id", null: false
    t.bigint "deactivated_by_id"
    t.string "role", null: false
    t.string "availability", null: false
    t.boolean "auto_offline", default: true, null: false
    t.bigint "custom_role_id"
    t.bigint "agent_capacity_policy_id"
    t.jsonb "team_ids", default: [], null: false
    t.jsonb "inbox_ids", default: [], null: false
    t.datetime "deactivated_at", null: false
    t.datetime "reactivated_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "user_id"], name: "index_account_user_lifecycle_snapshots_active", unique: true, where: "(reactivated_at IS NULL)"
    t.index ["account_id"], name: "index_account_user_lifecycle_snapshots_on_account_id"
    t.index ["deactivated_at"], name: "index_account_user_lifecycle_snapshots_on_deactivated_at"
    t.index ["deactivated_by_id"], name: "index_account_user_lifecycle_snapshots_on_deactivated_by_id"
    t.index ["user_id"], name: "index_account_user_lifecycle_snapshots_on_user_id"
  end

  create_table "account_users", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "user_id"
    t.integer "role", default: 0
    t.bigint "inviter_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "active_at", precision: nil
    t.integer "availability", default: 0, null: false
    t.boolean "auto_offline", default: true, null: false
    t.bigint "custom_role_id"
    t.bigint "agent_capacity_policy_id"
    t.index ["account_id", "user_id"], name: "uniq_user_id_per_account_id", unique: true
    t.index ["account_id"], name: "index_account_users_on_account_id"
    t.index ["agent_capacity_policy_id"], name: "index_account_users_on_agent_capacity_policy_id"
    t.index ["custom_role_id"], name: "index_account_users_on_custom_role_id"
    t.index ["user_id"], name: "index_account_users_on_user_id"
  end

  create_table "accounts", id: :serial, force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "locale", default: 0
    t.string "domain", limit: 100
    t.string "support_email", limit: 100
    t.bigint "feature_flags", default: 0, null: false
    t.integer "auto_resolve_duration"
    t.jsonb "limits", default: {}
    t.jsonb "custom_attributes", default: {}
    t.integer "status", default: 0
    t.jsonb "internal_attributes", default: {}, null: false
    t.jsonb "settings", default: {}
    t.jsonb "feature_flags_overflow", default: [], null: false
    t.index ["status"], name: "index_accounts_on_status"
  end

  create_table "action_mailbox_inbound_emails", force: :cascade do |t|
    t.integer "status", default: 0, null: false
    t.string "message_id", null: false
    t.string "message_checksum", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id", "message_checksum"], name: "index_action_mailbox_inbound_emails_uniqueness", unique: true
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", precision: nil, null: false
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "agent_bot_inboxes", force: :cascade do |t|
    t.integer "inbox_id"
    t.integer "agent_bot_id"
    t.integer "status", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "account_id"
  end

  create_table "agent_bots", force: :cascade do |t|
    t.string "name"
    t.string "description"
    t.string "outgoing_url"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "account_id"
    t.integer "bot_type", default: 0
    t.jsonb "bot_config", default: {}
    t.string "secret"
    t.index ["account_id"], name: "index_agent_bots_on_account_id"
  end

  create_table "agent_capacity_policies", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "name", limit: 255, null: false
    t.text "description"
    t.jsonb "exclusion_rules", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_agent_capacity_policies_on_account_id"
  end

  create_table "applied_slas", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "sla_policy_id", null: false
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "sla_status", default: 0
    t.index ["account_id", "sla_policy_id", "conversation_id"], name: "index_applied_slas_on_account_sla_policy_conversation", unique: true
    t.index ["account_id"], name: "index_applied_slas_on_account_id"
    t.index ["conversation_id"], name: "index_applied_slas_on_conversation_id"
    t.index ["sla_policy_id"], name: "index_applied_slas_on_sla_policy_id"
  end

  create_table "article_embeddings", force: :cascade do |t|
    t.bigint "article_id", null: false
    t.text "term", null: false
    t.vector "embedding", limit: 1536
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["embedding"], name: "index_article_embeddings_on_embedding", using: :ivfflat
  end

  create_table "articles", force: :cascade do |t|
    t.integer "account_id", null: false
    t.integer "portal_id", null: false
    t.integer "category_id"
    t.integer "folder_id"
    t.string "title"
    t.text "description"
    t.text "content"
    t.integer "status"
    t.integer "views"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "author_id"
    t.bigint "associated_article_id"
    t.jsonb "meta", default: {}
    t.string "slug", null: false
    t.integer "position"
    t.string "locale", default: "en", null: false
    t.index ["account_id"], name: "index_articles_on_account_id"
    t.index ["associated_article_id"], name: "index_articles_on_associated_article_id"
    t.index ["author_id"], name: "index_articles_on_author_id"
    t.index ["portal_id"], name: "index_articles_on_portal_id"
    t.index ["slug"], name: "index_articles_on_slug", unique: true
    t.index ["status"], name: "index_articles_on_status"
    t.index ["views"], name: "index_articles_on_views"
  end

  create_table "assignment_client_ownerships", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "contact_id", null: false
    t.bigint "user_id", null: false
    t.bigint "assignment_policy_id"
    t.datetime "last_assigned_at", null: false
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "contact_id"], name: "idx_assignment_ownerships_account_contact", unique: true
    t.index ["account_id", "user_id"], name: "idx_assignment_ownerships_account_user"
    t.index ["account_id"], name: "index_assignment_client_ownerships_on_account_id"
    t.index ["assignment_policy_id"], name: "index_assignment_ownerships_on_policy_id"
    t.index ["contact_id"], name: "index_assignment_client_ownerships_on_contact_id"
    t.index ["expires_at"], name: "index_assignment_client_ownerships_on_expires_at"
    t.index ["user_id"], name: "index_assignment_client_ownerships_on_user_id"
  end

  create_table "assignment_decision_logs", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "inbox_id", null: false
    t.bigint "conversation_id", null: false
    t.bigint "assignment_policy_id"
    t.bigint "assigned_user_id"
    t.integer "outcome", default: 0, null: false
    t.jsonb "reasons", default: [], null: false
    t.jsonb "candidate_summaries", default: [], null: false
    t.jsonb "decision_metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "created_at"], name: "idx_assignment_decision_logs_account_created_at"
    t.index ["account_id"], name: "index_assignment_decision_logs_on_account_id"
    t.index ["assigned_user_id"], name: "index_assignment_decision_logs_on_assigned_user_id"
    t.index ["assignment_policy_id"], name: "index_assignment_decision_logs_on_policy_id"
    t.index ["conversation_id", "created_at"], name: "idx_assignment_decision_logs_conversation_created_at"
    t.index ["conversation_id"], name: "index_assignment_decision_logs_on_conversation_id"
    t.index ["inbox_id", "outcome", "created_at"], name: "idx_assignment_decision_logs_inbox_outcome_created_at"
    t.index ["inbox_id"], name: "index_assignment_decision_logs_on_inbox_id"
  end

  create_table "assignment_policies", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "name", limit: 255, null: false
    t.text "description"
    t.integer "assignment_order", default: 0, null: false
    t.integer "conversation_priority", default: 0, null: false
    t.integer "fair_distribution_limit", default: 100, null: false
    t.integer "fair_distribution_window", default: 3600, null: false
    t.boolean "enabled", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "assignment_delay_minutes", default: 0, null: false
    t.integer "max_open_conversations"
    t.integer "monthly_new_client_quota"
    t.boolean "sticky_owner_enabled", default: false, null: false
    t.integer "sticky_owner_duration_days", default: 30, null: false
    t.jsonb "exclusion_rules", default: {}, null: false
    t.boolean "assign_pending_conversations", default: false, null: false
    t.boolean "assign_online_only", default: true, null: false
    t.index ["account_id", "name"], name: "index_assignment_policies_on_account_id_and_name", unique: true
    t.index ["account_id"], name: "index_assignment_policies_on_account_id"
    t.index ["enabled"], name: "index_assignment_policies_on_enabled"
  end

  create_table "assignment_quota_usages", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "user_id", null: false
    t.bigint "contact_id", null: false
    t.bigint "conversation_id"
    t.bigint "assignment_policy_id"
    t.date "period_start", null: false
    t.date "period_end", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "user_id", "contact_id", "period_start"], name: "idx_assignment_quota_usages_unique_contact_period", unique: true
    t.index ["account_id", "user_id", "period_start"], name: "idx_assignment_quota_usages_account_user_period"
    t.index ["account_id"], name: "index_assignment_quota_usages_on_account_id"
    t.index ["assignment_policy_id"], name: "index_assignment_quota_usages_on_policy_id"
    t.index ["contact_id"], name: "index_assignment_quota_usages_on_contact_id"
    t.index ["conversation_id"], name: "index_assignment_quota_usages_on_conversation_id"
    t.index ["user_id"], name: "index_assignment_quota_usages_on_user_id"
  end

  create_table "attachments", id: :serial, force: :cascade do |t|
    t.integer "file_type", default: 0
    t.string "external_url"
    t.float "coordinates_lat", default: 0.0
    t.float "coordinates_long", default: 0.0
    t.integer "message_id", null: false
    t.integer "account_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "fallback_title"
    t.string "extension"
    t.jsonb "meta", default: {}
    t.index ["account_id"], name: "index_attachments_on_account_id"
    t.index ["message_id"], name: "index_attachments_on_message_id"
  end

  create_table "audits", force: :cascade do |t|
    t.bigint "auditable_id"
    t.string "auditable_type"
    t.bigint "associated_id"
    t.string "associated_type"
    t.bigint "user_id"
    t.string "user_type"
    t.string "username"
    t.string "action"
    t.jsonb "audited_changes"
    t.integer "version", default: 0
    t.string "comment"
    t.string "remote_address"
    t.string "request_uuid"
    t.datetime "created_at", precision: nil
    t.index ["associated_type", "associated_id"], name: "associated_index"
    t.index ["auditable_type", "auditable_id", "version"], name: "auditable_index"
    t.index ["created_at"], name: "index_audits_on_created_at"
    t.index ["request_uuid"], name: "index_audits_on_request_uuid"
    t.index ["user_id", "user_type"], name: "user_index"
  end

  create_table "automation_rules", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "name", null: false
    t.text "description"
    t.string "event_name", null: false
    t.jsonb "conditions", default: "{}", null: false
    t.jsonb "actions", default: "{}", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "active", default: true, null: false
    t.index ["account_id"], name: "index_automation_rules_on_account_id"
  end

  create_table "bulk_action_runs", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "user_id", null: false
    t.string "resource_type", null: false
    t.string "action_name", null: false
    t.integer "status", default: 0, null: false
    t.integer "total_count", default: 0, null: false
    t.integer "processed_count", default: 0, null: false
    t.integer "failed_count", default: 0, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "started_at"
    t.datetime "completed_at"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "resource_type", "created_at"], name: "idx_bulk_action_runs_on_account_resource_created"
    t.index ["account_id", "user_id", "created_at"], name: "idx_bulk_action_runs_on_account_user_created"
    t.index ["account_id"], name: "index_bulk_action_runs_on_account_id"
    t.index ["user_id"], name: "index_bulk_action_runs_on_user_id"
  end

  create_table "calls", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "inbox_id", null: false
    t.bigint "conversation_id", null: false
    t.bigint "contact_id", null: false
    t.bigint "message_id"
    t.bigint "accepted_by_agent_id"
    t.string "provider_call_id", null: false
    t.integer "provider", default: 0, null: false
    t.integer "direction", null: false
    t.string "status", default: "ringing", null: false
    t.datetime "started_at"
    t.integer "duration_seconds"
    t.string "end_reason"
    t.jsonb "meta", default: {}
    t.text "transcript"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "media_session_id"
    t.index ["accepted_by_agent_id", "status"], name: "index_calls_on_accepted_by_agent_id_and_status"
    t.index ["account_id", "contact_id"], name: "index_calls_on_account_id_and_contact_id"
    t.index ["account_id", "conversation_id"], name: "index_calls_on_account_id_and_conversation_id"
    t.index ["media_session_id"], name: "index_calls_on_media_session_id", unique: true
    t.index ["message_id"], name: "index_calls_on_message_id"
    t.index ["provider", "provider_call_id"], name: "index_calls_on_provider_and_provider_call_id", unique: true
  end

  create_table "campaign_audience_imports", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "inbox_id", null: false
    t.bigint "created_by_id"
    t.string "token", null: false
    t.string "source_filename", null: false
    t.string "default_country", null: false
    t.integer "status", default: 0, null: false
    t.string "processing_error"
    t.integer "total_rows", default: 0, null: false
    t.integer "recipient_count", default: 0, null: false
    t.integer "created_count", default: 0, null: false
    t.integer "existing_count", default: 0, null: false
    t.integer "duplicate_count", default: 0, null: false
    t.integer "invalid_count", default: 0, null: false
    t.integer "conflict_count", default: 0, null: false
    t.jsonb "error_samples", default: [], null: false
    t.datetime "expires_at", null: false
    t.datetime "claimed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "expires_at"], name: "index_campaign_audience_imports_on_account_id_and_expires_at"
    t.index ["account_id", "status"], name: "index_campaign_audience_imports_on_account_id_and_status"
    t.index ["account_id"], name: "index_campaign_audience_imports_on_account_id"
    t.index ["created_by_id"], name: "index_campaign_audience_imports_on_created_by_id"
    t.index ["inbox_id"], name: "index_campaign_audience_imports_on_inbox_id"
    t.index ["token"], name: "index_campaign_audience_imports_on_token", unique: true
  end

  create_table "campaign_audience_recipients", force: :cascade do |t|
    t.bigint "campaign_audience_import_id", null: false
    t.bigint "account_id", null: false
    t.bigint "contact_id"
    t.string "normalized_phone_number", null: false
    t.integer "source_row", null: false
    t.boolean "contact_created", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_campaign_audience_recipients_on_account_id"
    t.index ["campaign_audience_import_id", "contact_id"], name: "idx_campaign_audience_recipients_import_contact", unique: true
    t.index ["campaign_audience_import_id", "normalized_phone_number"], name: "idx_campaign_audience_recipients_import_phone", unique: true
    t.index ["campaign_audience_import_id"], name: "idx_campaign_audience_recipients_on_import"
    t.index ["contact_id"], name: "index_campaign_audience_recipients_on_contact_id"
  end

  create_table "campaign_deliveries", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "campaign_id", null: false
    t.bigint "inbox_id", null: false
    t.bigint "contact_id", null: false
    t.integer "status", default: 0, null: false
    t.string "provider", null: false
    t.string "target_identifier"
    t.string "provider_message_id"
    t.text "error_message"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "last_status_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "campaign_run_id"
    t.index ["account_id"], name: "index_campaign_deliveries_on_account_id"
    t.index ["campaign_id", "contact_id"], name: "index_campaign_deliveries_on_campaign_id_and_contact_id"
    t.index ["campaign_id"], name: "index_campaign_deliveries_on_campaign_id"
    t.index ["campaign_run_id", "contact_id"], name: "index_campaign_deliveries_on_campaign_run_id_and_contact_id", unique: true, where: "(campaign_run_id IS NOT NULL)"
    t.index ["campaign_run_id"], name: "index_campaign_deliveries_on_campaign_run_id"
    t.index ["contact_id"], name: "index_campaign_deliveries_on_contact_id"
    t.index ["inbox_id"], name: "index_campaign_deliveries_on_inbox_id"
    t.index ["provider_message_id"], name: "index_campaign_deliveries_on_provider_message_id"
  end

  create_table "campaign_runs", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "campaign_id", null: false
    t.bigint "inbox_id", null: false
    t.integer "status", default: 0, null: false
    t.integer "total_count", default: 0, null: false
    t.integer "processed_count", default: 0, null: false
    t.integer "successful_count", default: 0, null: false
    t.integer "failed_count", default: 0, null: false
    t.integer "skipped_count", default: 0, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "started_at"
    t.datetime "completed_at"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "created_at"], name: "index_campaign_runs_on_account_id_and_created_at"
    t.index ["account_id"], name: "index_campaign_runs_on_account_id"
    t.index ["campaign_id", "created_at"], name: "index_campaign_runs_on_campaign_id_and_created_at"
    t.index ["campaign_id"], name: "index_campaign_runs_on_campaign_id"
    t.index ["inbox_id"], name: "index_campaign_runs_on_inbox_id"
  end

  create_table "campaigns", force: :cascade do |t|
    t.integer "display_id", null: false
    t.string "title", null: false
    t.text "description"
    t.text "message", null: false
    t.integer "sender_id"
    t.boolean "enabled", default: true
    t.bigint "account_id", null: false
    t.bigint "inbox_id", null: false
    t.jsonb "trigger_rules", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "campaign_type", default: 0, null: false
    t.integer "campaign_status", default: 0, null: false
    t.jsonb "audience", default: []
    t.datetime "scheduled_at", precision: nil
    t.boolean "trigger_only_during_business_hours", default: false
    t.jsonb "template_params"
    t.integer "text_mode", default: 0, null: false
    t.text "instructions"
    t.bigint "captain_assistant_id"
    t.string "idempotency_key"
    t.datetime "launch_requested_at"
    t.string "idempotency_fingerprint"
    t.bigint "campaign_audience_import_id"
    t.index ["account_id", "idempotency_key"], name: "index_campaigns_on_account_id_and_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["account_id"], name: "index_campaigns_on_account_id"
    t.index ["campaign_audience_import_id"], name: "idx_campaigns_on_audience_import", unique: true
    t.index ["campaign_status"], name: "index_campaigns_on_campaign_status"
    t.index ["campaign_type"], name: "index_campaigns_on_campaign_type"
    t.index ["captain_assistant_id"], name: "index_campaigns_on_captain_assistant_id"
    t.index ["inbox_id"], name: "index_campaigns_on_inbox_id"
    t.index ["launch_requested_at"], name: "index_campaigns_on_launch_requested_at"
    t.index ["scheduled_at"], name: "index_campaigns_on_scheduled_at"
  end

  create_table "canned_responses", id: :serial, force: :cascade do |t|
    t.integer "account_id", null: false
    t.string "short_code"
    t.text "content"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "captain_assistant_responses", force: :cascade do |t|
    t.string "question", null: false
    t.text "answer", null: false
    t.vector "embedding", limit: 1536
    t.bigint "assistant_id"
    t.bigint "documentable_id"
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "status", default: 1, null: false
    t.string "documentable_type"
    t.boolean "edited", default: false, null: false
    t.bigint "document_chunk_id"
    t.integer "visibility", default: 0, null: false
    t.index ["account_id", "visibility"], name: "idx_captain_responses_account_visibility"
    t.index ["account_id"], name: "index_captain_assistant_responses_on_account_id"
    t.index ["assistant_id"], name: "index_captain_assistant_responses_on_assistant_id"
    t.index ["document_chunk_id"], name: "index_captain_assistant_responses_on_document_chunk_id"
    t.index ["documentable_id", "documentable_type"], name: "idx_cap_asst_resp_on_documentable"
    t.index ["embedding"], name: "vector_idx_knowledge_entries_embedding", using: :ivfflat
    t.index ["status"], name: "index_captain_assistant_responses_on_status"
  end

  create_table "captain_assistants", force: :cascade do |t|
    t.string "name", null: false
    t.bigint "account_id", null: false
    t.string "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "config", default: {}, null: false
    t.jsonb "response_guidelines", default: []
    t.jsonb "guardrails", default: []
    t.string "usage_mode", default: "external_agent", null: false
    t.index ["account_id"], name: "index_captain_assistants_on_account_id"
    t.index ["usage_mode"], name: "index_captain_assistants_on_usage_mode"
  end

  create_table "captain_custom_tools", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "slug", null: false
    t.string "title", null: false
    t.text "description"
    t.string "http_method", default: "GET", null: false
    t.text "endpoint_url", null: false
    t.text "request_template"
    t.text "response_template"
    t.string "auth_type", default: "none"
    t.jsonb "auth_config", default: {}
    t.jsonb "param_schema", default: []
    t.boolean "enabled", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "group_name"
    t.boolean "allow_file_artifacts", default: true, null: false
    t.string "request_body_type", default: "json", null: false
    t.jsonb "http_options", default: {}, null: false
    t.index ["account_id", "group_name"], name: "index_captain_custom_tools_on_account_id_and_group_name"
    t.index ["account_id", "slug"], name: "index_captain_custom_tools_on_account_id_and_slug", unique: true
    t.index ["account_id"], name: "index_captain_custom_tools_on_account_id"
  end

  create_table "captain_document_chunks", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "assistant_id"
    t.bigint "document_id", null: false
    t.integer "chunk_index", null: false
    t.text "content", null: false
    t.string "content_sha256", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.vector "embedding", limit: 1536
    t.integer "embedding_status", default: 0, null: false
    t.text "embedding_error"
    t.datetime "embedding_updated_at"
    t.index ["account_id"], name: "index_captain_document_chunks_on_account_id"
    t.index ["assistant_id"], name: "index_captain_document_chunks_on_assistant_id"
    t.index ["content_sha256"], name: "index_captain_document_chunks_on_content_sha256"
    t.index ["document_id", "chunk_index"], name: "index_captain_document_chunks_on_document_id_and_chunk_index", unique: true
    t.index ["document_id"], name: "index_captain_document_chunks_on_document_id"
    t.index ["embedding"], name: "vector_idx_captain_document_chunks_embedding", using: :ivfflat
    t.index ["embedding_status"], name: "index_captain_document_chunks_on_embedding_status"
  end

  create_table "captain_documents", force: :cascade do |t|
    t.string "name"
    t.string "external_link", null: false
    t.text "content"
    t.bigint "assistant_id"
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "status", default: 0, null: false
    t.jsonb "metadata", default: {}
    t.text "source_text"
    t.boolean "faq_generation_enabled", default: true, null: false
    t.integer "visibility", default: 0, null: false
    t.index ["account_id", "external_link"], name: "index_captain_documents_on_account_id_and_external_link", unique: true
    t.index ["account_id", "visibility"], name: "idx_captain_documents_account_visibility"
    t.index ["account_id"], name: "index_captain_documents_on_account_id"
    t.index ["assistant_id"], name: "index_captain_documents_on_assistant_id"
    t.index ["status"], name: "index_captain_documents_on_status"
  end

  create_table "captain_inboxes", force: :cascade do |t|
    t.bigint "captain_assistant_id", null: false
    t.bigint "inbox_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "auto_reply_mode", default: "always", null: false
    t.boolean "reply_to_open_conversations", default: false, null: false
    t.index ["captain_assistant_id", "inbox_id"], name: "index_captain_inboxes_on_captain_assistant_id_and_inbox_id", unique: true
    t.index ["captain_assistant_id"], name: "index_captain_inboxes_on_captain_assistant_id"
    t.index ["inbox_id"], name: "index_captain_inboxes_on_inbox_id"
  end

  create_table "captain_knowledge_answer_cache_entries", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "assistant_id"
    t.text "query", null: false
    t.string "query_sha256", null: false
    t.vector "embedding", limit: 1536
    t.jsonb "payload", default: {}, null: false
    t.string "source_fingerprint", null: false
    t.integer "hit_count", default: 0, null: false
    t.datetime "last_hit_at"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "assistant_id", "query_sha256", "source_fingerprint"], name: "idx_captain_answer_cache_exact", unique: true
    t.index ["account_id"], name: "index_captain_knowledge_answer_cache_entries_on_account_id"
    t.index ["assistant_id"], name: "index_captain_knowledge_answer_cache_entries_on_assistant_id"
    t.index ["embedding"], name: "vector_idx_captain_answer_cache_embedding", using: :ivfflat
    t.index ["expires_at"], name: "idx_captain_answer_cache_expires_at"
  end

  create_table "captain_mcp_servers", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.text "description"
    t.string "transport_type", null: false
    t.jsonb "server_config", default: {}, null: false
    t.jsonb "allowed_scopes", default: [], null: false
    t.integer "request_timeout", default: 30, null: false
    t.boolean "enabled", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "oauth_token_data"
    t.text "oauth_client_info_data"
    t.text "oauth_server_metadata_data"
    t.text "oauth_pkce_data"
    t.text "oauth_resource_metadata_data"
    t.string "oauth_state_param"
    t.datetime "oauth_state_expires_at"
    t.text "oauth_return_url"
    t.datetime "oauth_last_authorized_at"
    t.index ["account_id", "enabled"], name: "index_captain_mcp_servers_on_account_id_and_enabled"
    t.index ["account_id", "slug"], name: "index_captain_mcp_servers_on_account_id_and_slug", unique: true
    t.index ["account_id"], name: "index_captain_mcp_servers_on_account_id"
    t.index ["oauth_state_param"], name: "index_captain_mcp_servers_on_oauth_state_param", unique: true, where: "(oauth_state_param IS NOT NULL)"
  end

  create_table "captain_scenarios", force: :cascade do |t|
    t.string "title"
    t.text "description"
    t.text "instruction"
    t.jsonb "tools", default: []
    t.boolean "enabled", default: true, null: false
    t.bigint "assistant_id", null: false
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_captain_scenarios_on_account_id"
    t.index ["assistant_id", "enabled"], name: "index_captain_scenarios_on_assistant_id_and_enabled"
    t.index ["assistant_id"], name: "index_captain_scenarios_on_assistant_id"
    t.index ["enabled"], name: "index_captain_scenarios_on_enabled"
  end

  create_table "captain_skills", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "slug", null: false
    t.string "name", null: false
    t.string "group_name"
    t.text "description", null: false
    t.text "content", null: false
    t.string "source_url"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "slug"], name: "index_captain_skills_on_account_id_and_slug", unique: true
    t.index ["account_id"], name: "index_captain_skills_on_account_id"
  end

  create_table "categories", force: :cascade do |t|
    t.integer "account_id", null: false
    t.integer "portal_id", null: false
    t.string "name"
    t.text "description"
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "locale", default: "en"
    t.string "slug", null: false
    t.bigint "parent_category_id"
    t.bigint "associated_category_id"
    t.string "icon", default: ""
    t.index ["associated_category_id"], name: "index_categories_on_associated_category_id"
    t.index ["locale", "account_id"], name: "index_categories_on_locale_and_account_id"
    t.index ["locale"], name: "index_categories_on_locale"
    t.index ["parent_category_id"], name: "index_categories_on_parent_category_id"
    t.index ["slug", "locale", "portal_id"], name: "index_categories_on_slug_and_locale_and_portal_id", unique: true
  end

  create_table "channel_api", force: :cascade do |t|
    t.integer "account_id", null: false
    t.string "webhook_url"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "identifier"
    t.string "hmac_token"
    t.boolean "hmac_mandatory", default: false
    t.jsonb "additional_attributes", default: {}
    t.string "secret"
    t.index ["hmac_token"], name: "index_channel_api_on_hmac_token", unique: true
    t.index ["identifier"], name: "index_channel_api_on_identifier", unique: true
  end

  create_table "channel_email", force: :cascade do |t|
    t.integer "account_id", null: false
    t.string "email", null: false
    t.string "forward_to_email", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "imap_enabled", default: false
    t.string "imap_address", default: ""
    t.integer "imap_port", default: 0
    t.string "imap_login", default: ""
    t.string "imap_password", default: ""
    t.boolean "imap_enable_ssl", default: true
    t.boolean "smtp_enabled", default: false
    t.string "smtp_address", default: ""
    t.integer "smtp_port", default: 0
    t.string "smtp_login", default: ""
    t.string "smtp_password", default: ""
    t.string "smtp_domain", default: ""
    t.boolean "smtp_enable_starttls_auto", default: true
    t.string "smtp_authentication", default: "login"
    t.string "smtp_openssl_verify_mode", default: "none"
    t.boolean "smtp_enable_ssl_tls", default: false
    t.jsonb "provider_config", default: {}
    t.string "provider"
    t.boolean "verified_for_sending", default: false, null: false
    t.string "imap_authentication", default: "plain"
    t.index ["email"], name: "index_channel_email_on_email", unique: true
    t.index ["forward_to_email"], name: "index_channel_email_on_forward_to_email", unique: true
  end

  create_table "channel_facebook_pages", id: :serial, force: :cascade do |t|
    t.string "page_id", null: false
    t.string "user_access_token", null: false
    t.string "page_access_token", null: false
    t.integer "account_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "instagram_id"
    t.index ["page_id", "account_id"], name: "index_channel_facebook_pages_on_page_id_and_account_id", unique: true
    t.index ["page_id"], name: "index_channel_facebook_pages_on_page_id"
  end

  create_table "channel_instagram", force: :cascade do |t|
    t.string "access_token", null: false
    t.datetime "expires_at", null: false
    t.integer "account_id", null: false
    t.string "instagram_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["instagram_id"], name: "index_channel_instagram_on_instagram_id", unique: true
  end

  create_table "channel_line", force: :cascade do |t|
    t.integer "account_id", null: false
    t.string "line_channel_id", null: false
    t.string "line_channel_secret", null: false
    t.string "line_channel_token", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["line_channel_id"], name: "index_channel_line_on_line_channel_id", unique: true
  end

  create_table "channel_linkedin_personal", force: :cascade do |t|
    t.integer "account_id", null: false
    t.string "profile_urn", null: false
    t.string "display_name"
    t.text "li_at"
    t.text "jsessionid"
    t.text "csrf_token"
    t.text "x_li_track"
    t.string "connection_state", default: "disconnected", null: false
    t.string "lifecycle_state", default: "pending_auth", null: false
    t.text "last_error"
    t.datetime "last_synced_at"
    t.string "webhook_identifier", null: false
    t.string "webhook_secret", null: false
    t.jsonb "runtime_state", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "profile_urn"], name: "index_channel_linkedin_personal_on_account_id_and_profile_urn", unique: true
    t.index ["account_id"], name: "index_channel_linkedin_personal_on_account_id"
    t.index ["webhook_identifier"], name: "index_channel_linkedin_personal_on_webhook_identifier", unique: true
  end

  create_table "channel_sms", force: :cascade do |t|
    t.integer "account_id", null: false
    t.string "phone_number", null: false
    t.string "provider", default: "default"
    t.jsonb "provider_config", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["phone_number"], name: "index_channel_sms_on_phone_number", unique: true
  end

  create_table "channel_telegram", force: :cascade do |t|
    t.string "bot_name"
    t.integer "account_id", null: false
    t.string "bot_token", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bot_token"], name: "index_channel_telegram_on_bot_token", unique: true
  end

  create_table "channel_telegram_personal", force: :cascade do |t|
    t.integer "account_id", null: false
    t.integer "api_id", null: false
    t.string "api_hash"
    t.string "phone_number", null: false
    t.text "string_session"
    t.string "connection_state", default: "disconnected", null: false
    t.string "lifecycle_state", default: "pending_auth", null: false
    t.text "last_error"
    t.datetime "last_synced_at"
    t.string "webhook_identifier", null: false
    t.string "webhook_secret", null: false
    t.jsonb "runtime_state", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "phone_number"], name: "index_channel_telegram_personal_on_account_phone", unique: true
    t.index ["account_id"], name: "index_channel_telegram_personal_on_account_id"
    t.index ["webhook_identifier"], name: "index_channel_telegram_personal_on_webhook_identifier", unique: true
  end

  create_table "channel_tiktok", force: :cascade do |t|
    t.integer "account_id", null: false
    t.string "business_id", null: false
    t.string "access_token", null: false
    t.datetime "expires_at", null: false
    t.string "refresh_token", null: false
    t.datetime "refresh_token_expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["business_id"], name: "index_channel_tiktok_on_business_id", unique: true
  end

  create_table "channel_twilio_sms", force: :cascade do |t|
    t.string "phone_number"
    t.string "auth_token", null: false
    t.string "account_sid", null: false
    t.integer "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "medium", default: 0
    t.string "messaging_service_sid"
    t.string "api_key_sid"
    t.jsonb "content_templates", default: {}
    t.datetime "content_templates_last_updated"
    t.index ["account_sid", "phone_number"], name: "index_channel_twilio_sms_on_account_sid_and_phone_number", unique: true
    t.index ["messaging_service_sid"], name: "index_channel_twilio_sms_on_messaging_service_sid", unique: true
    t.index ["phone_number"], name: "index_channel_twilio_sms_on_phone_number", unique: true
  end

  create_table "channel_twitter_profiles", force: :cascade do |t|
    t.string "profile_id", null: false
    t.string "twitter_access_token", null: false
    t.string "twitter_access_token_secret", null: false
    t.integer "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "tweets_enabled", default: true
    t.index ["account_id", "profile_id"], name: "index_channel_twitter_profiles_on_account_id_and_profile_id", unique: true
  end

  create_table "channel_vk_community", force: :cascade do |t|
    t.integer "account_id", null: false
    t.bigint "group_id", null: false
    t.string "access_token"
    t.string "secret"
    t.string "confirmation_token"
    t.string "api_version", default: "5.199", null: false
    t.string "callback_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["callback_id"], name: "index_channel_vk_community_on_callback_id", unique: true
    t.index ["group_id"], name: "index_channel_vk_community_on_group_id", unique: true
  end

  create_table "channel_voice", force: :cascade do |t|
    t.string "phone_number", null: false
    t.string "provider", default: "twilio", null: false
    t.jsonb "provider_config", null: false
    t.integer "account_id", null: false
    t.jsonb "additional_attributes", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_channel_voice_on_account_id"
    t.index ["phone_number"], name: "index_channel_voice_on_phone_number", unique: true
  end

  create_table "channel_web_widgets", id: :serial, force: :cascade do |t|
    t.string "website_url"
    t.integer "account_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "website_token"
    t.string "widget_color", default: "#1A1A1A"
    t.string "welcome_title"
    t.string "welcome_tagline"
    t.integer "feature_flags", default: 7, null: false
    t.integer "reply_time", default: 0
    t.string "hmac_token"
    t.boolean "pre_chat_form_enabled", default: false
    t.jsonb "pre_chat_form_options", default: {}
    t.boolean "hmac_mandatory", default: false
    t.boolean "continuity_via_email", default: true, null: false
    t.text "allowed_domains", default: ""
    t.index ["hmac_token"], name: "index_channel_web_widgets_on_hmac_token", unique: true
    t.index ["website_token"], name: "index_channel_web_widgets_on_website_token", unique: true
  end

  create_table "channel_weixins", force: :cascade do |t|
    t.integer "account_id", null: false
    t.text "ilink_token"
    t.string "token_fingerprint"
    t.string "provider_account_id"
    t.string "display_name"
    t.text "context_token"
    t.string "connection_state", default: "disconnected", null: false
    t.string "lifecycle_state", default: "pending_auth", null: false
    t.text "last_error"
    t.datetime "last_synced_at"
    t.jsonb "runtime_state", default: {}, null: false
    t.string "webhook_identifier", null: false
    t.string "webhook_secret", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "context_tokens", default: {}, null: false
    t.index ["account_id", "provider_account_id"], name: "index_channel_weixins_on_account_id_and_provider_account_id", unique: true, where: "(provider_account_id IS NOT NULL)"
    t.index ["account_id", "token_fingerprint"], name: "index_channel_weixins_on_account_id_and_token_fingerprint", unique: true
    t.index ["account_id"], name: "index_channel_weixins_on_account_id"
    t.index ["webhook_identifier"], name: "index_channel_weixins_on_webhook_identifier", unique: true
  end

  create_table "channel_whatsapp", force: :cascade do |t|
    t.integer "account_id", null: false
    t.string "phone_number", null: false
    t.string "provider", default: "default"
    t.jsonb "provider_config", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "message_templates", default: {}
    t.datetime "message_templates_last_updated", precision: nil
    t.index ["phone_number"], name: "index_channel_whatsapp_on_phone_number", unique: true
  end

  create_table "channel_whatsapp_web", force: :cascade do |t|
    t.integer "account_id", null: false
    t.string "phone_number", null: false
    t.string "provider", default: "evolution", null: false
    t.jsonb "provider_config", default: {}, null: false
    t.string "instance_name", null: false
    t.string "lifecycle_state", default: "creating", null: false
    t.string "connection_state", default: "close", null: false
    t.text "last_error"
    t.datetime "last_synced_at"
    t.jsonb "qr_code", default: {}, null: false
    t.string "webhook_identifier", null: false
    t.string "webhook_secret", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "sync_state", default: {}, null: false
    t.boolean "conversation_pending", default: false, null: false
    t.integer "history_lookback_days", default: 0, null: false
    t.jsonb "ignore_jids", default: [], null: false
    t.boolean "sign_messages", default: false, null: false
    t.string "sign_delimiter", default: "\\n", null: false
    t.boolean "import_contacts", default: true, null: false
    t.boolean "import_messages", default: true, null: false
    t.boolean "sync_labels", default: true, null: false
    t.index ["instance_name"], name: "index_channel_whatsapp_web_on_instance_name", unique: true
    t.index ["webhook_identifier"], name: "index_channel_whatsapp_web_on_webhook_identifier", unique: true
  end

  create_table "communication_thread_conversations", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "communication_thread_id", null: false
    t.bigint "conversation_id", null: false
    t.bigint "inbox_id", null: false
    t.bigint "contact_inbox_id"
    t.boolean "primary", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "conversation_id"], name: "idx_ctc_account_conversation_unique", unique: true
    t.index ["account_id"], name: "index_communication_thread_conversations_on_account_id"
    t.index ["communication_thread_id", "inbox_id"], name: "idx_ctc_thread_inbox"
    t.index ["communication_thread_id"], name: "idx_ctc_on_thread_id"
    t.index ["contact_inbox_id"], name: "index_communication_thread_conversations_on_contact_inbox_id"
    t.index ["conversation_id"], name: "index_communication_thread_conversations_on_conversation_id"
    t.index ["inbox_id"], name: "index_communication_thread_conversations_on_inbox_id"
  end

  create_table "communication_threads", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "contact_id", null: false
    t.bigint "display_id", null: false
    t.integer "status", default: 0, null: false
    t.integer "priority"
    t.bigint "assignee_id"
    t.bigint "team_id"
    t.datetime "last_activity_at"
    t.integer "unread_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "contact_id", "status"], name: "idx_communication_threads_account_contact_status"
    t.index ["account_id", "display_id"], name: "idx_communication_threads_account_display", unique: true
    t.index ["account_id", "last_activity_at"], name: "idx_communication_threads_account_activity"
    t.index ["account_id"], name: "index_communication_threads_on_account_id"
    t.index ["assignee_id"], name: "index_communication_threads_on_assignee_id"
    t.index ["contact_id"], name: "index_communication_threads_on_contact_id"
    t.index ["team_id"], name: "index_communication_threads_on_team_id"
  end

  create_table "companies", force: :cascade do |t|
    t.string "name", null: false
    t.string "domain"
    t.text "description"
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "contacts_count"
    t.jsonb "additional_attributes", default: {}, null: false
    t.jsonb "custom_attributes", default: {}, null: false
    t.datetime "last_activity_at"
    t.index ["account_id", "domain"], name: "index_companies_on_account_and_domain", unique: true, where: "(domain IS NOT NULL)"
    t.index ["account_id"], name: "index_companies_on_account_id"
    t.index ["name", "account_id"], name: "index_companies_on_name_and_account_id"
  end

  create_table "confirmation_requests", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "conversation_id"
    t.bigint "contact_id"
    t.bigint "inbox_id"
    t.bigint "requested_by_id"
    t.bigint "resolved_by_id"
    t.bigint "resolved_message_id"
    t.bigint "delivery_message_id"
    t.string "subject_type"
    t.bigint "subject_id"
    t.string "status", default: "pending", null: false
    t.string "token", null: false
    t.string "delivery_strategy"
    t.string "title", null: false
    t.text "body", null: false
    t.datetime "expires_at"
    t.datetime "resolved_at"
    t.string "resolution_source"
    t.float "resolution_confidence"
    t.jsonb "metadata", default: {}, null: false
    t.jsonb "resolution_metadata", default: {}, null: false
    t.string "idempotency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "reminder_id"
    t.index ["account_id", "idempotency_key"], name: "index_confirmation_requests_on_account_id_and_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["account_id", "status", "conversation_id"], name: "idx_on_account_id_status_conversation_id_2babc633ce"
    t.index ["account_id", "subject_type", "subject_id"], name: "idx_confirmation_requests_on_account_subject"
    t.index ["account_id"], name: "index_confirmation_requests_on_account_id"
    t.index ["contact_id"], name: "index_confirmation_requests_on_contact_id"
    t.index ["conversation_id"], name: "index_confirmation_requests_on_conversation_id"
    t.index ["delivery_message_id"], name: "index_confirmation_requests_on_delivery_message_id"
    t.index ["inbox_id"], name: "index_confirmation_requests_on_inbox_id"
    t.index ["reminder_id"], name: "index_confirmation_requests_on_reminder_id", unique: true
    t.index ["requested_by_id"], name: "index_confirmation_requests_on_requested_by_id"
    t.index ["resolved_by_id"], name: "index_confirmation_requests_on_resolved_by_id"
    t.index ["resolved_message_id"], name: "index_confirmation_requests_on_resolved_message_id"
    t.index ["token"], name: "index_confirmation_requests_on_token", unique: true
  end

  create_table "contact_channel_profiles", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "contact_id", null: false
    t.bigint "contact_inbox_id", null: false
    t.bigint "inbox_id", null: false
    t.string "channel_type", null: false
    t.string "provider", null: false
    t.text "source_id", null: false
    t.string "identifier"
    t.string "display_name"
    t.text "avatar_url"
    t.string "username"
    t.string "phone_number"
    t.string "email"
    t.jsonb "profile_data", default: {}, null: false
    t.datetime "last_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "provider", "source_id"], name: "idx_contact_channel_profiles_provider_source"
    t.index ["account_id"], name: "index_contact_channel_profiles_on_account_id"
    t.index ["contact_id", "inbox_id"], name: "idx_contact_channel_profiles_contact_inbox"
    t.index ["contact_id"], name: "index_contact_channel_profiles_on_contact_id"
    t.index ["contact_inbox_id"], name: "idx_contact_channel_profiles_unique_contact_inbox", unique: true
    t.index ["inbox_id"], name: "index_contact_channel_profiles_on_inbox_id"
  end

  create_table "contact_inboxes", force: :cascade do |t|
    t.bigint "contact_id"
    t.bigint "inbox_id"
    t.text "source_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "hmac_verified", default: false
    t.string "pubsub_token"
    t.index ["contact_id"], name: "index_contact_inboxes_on_contact_id"
    t.index ["inbox_id", "source_id"], name: "index_contact_inboxes_on_inbox_id_and_source_id", unique: true
    t.index ["inbox_id"], name: "index_contact_inboxes_on_inbox_id"
    t.index ["pubsub_token"], name: "index_contact_inboxes_on_pubsub_token", unique: true
    t.index ["source_id"], name: "index_contact_inboxes_on_source_id"
  end

  create_table "contacts", id: :serial, force: :cascade do |t|
    t.string "name", default: ""
    t.string "email"
    t.string "phone_number"
    t.integer "account_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.jsonb "additional_attributes", default: {}
    t.string "identifier"
    t.jsonb "custom_attributes", default: {}
    t.datetime "last_activity_at", precision: nil
    t.integer "contact_type", default: 0
    t.string "middle_name", default: ""
    t.string "last_name", default: ""
    t.string "location", default: ""
    t.string "country_code", default: ""
    t.boolean "blocked", default: false, null: false
    t.bigint "company_id"
    t.bigint "owner_id"
    t.index "account_id, ((custom_attributes ->> 'medelement_patient_code'::text))", name: "idx_contacts_account_medelement_patient_code", unique: true, where: "((custom_attributes ->> 'medelement_patient_code'::text) IS NOT NULL)"
    t.index "lower((email)::text), account_id", name: "index_contacts_on_lower_email_account_id"
    t.index ["account_id", "contact_type"], name: "index_contacts_on_account_id_and_contact_type"
    t.index ["account_id", "email", "phone_number", "identifier"], name: "index_contacts_on_nonempty_fields", where: "(((email)::text <> ''::text) OR ((phone_number)::text <> ''::text) OR ((identifier)::text <> ''::text))"
    t.index ["account_id", "last_activity_at"], name: "index_contacts_on_account_id_and_last_activity_at", order: { last_activity_at: "DESC NULLS LAST" }
    t.index ["account_id"], name: "index_contacts_on_account_id"
    t.index ["account_id"], name: "index_resolved_contact_account_id", where: "(((email)::text <> ''::text) OR ((phone_number)::text <> ''::text) OR ((identifier)::text <> ''::text))"
    t.index ["blocked"], name: "index_contacts_on_blocked"
    t.index ["company_id"], name: "index_contacts_on_company_id"
    t.index ["email", "account_id"], name: "uniq_email_per_account_contact", unique: true
    t.index ["identifier", "account_id"], name: "uniq_identifier_per_account_contact", unique: true
    t.index ["name", "email", "phone_number", "identifier"], name: "index_contacts_on_name_email_phone_number_identifier", opclass: :gin_trgm_ops, using: :gin
    t.index ["owner_id"], name: "index_contacts_on_owner_id"
    t.index ["phone_number", "account_id"], name: "index_contacts_on_phone_number_and_account_id"
  end

  create_table "conversation_participants", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "user_id", null: false
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_conversation_participants_on_account_id"
    t.index ["conversation_id"], name: "index_conversation_participants_on_conversation_id"
    t.index ["user_id", "conversation_id"], name: "index_conversation_participants_on_user_id_and_conversation_id", unique: true
    t.index ["user_id"], name: "index_conversation_participants_on_user_id"
  end

  create_table "conversation_status_transitions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "conversation_id", null: false
    t.string "actor_type"
    t.bigint "actor_id"
    t.string "from_status", null: false
    t.string "to_status", null: false
    t.string "reason"
    t.string "source", default: "manual", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "conversation_id", "created_at"], name: "idx_conv_status_transitions_on_account_conversation_created"
    t.index ["account_id", "to_status", "created_at"], name: "idx_conv_status_transitions_on_account_status_created"
    t.index ["account_id"], name: "index_conversation_status_transitions_on_account_id"
    t.index ["actor_type", "actor_id"], name: "index_conversation_status_transitions_on_actor"
    t.index ["conversation_id"], name: "index_conversation_status_transitions_on_conversation_id"
  end

  create_table "conversations", id: :serial, force: :cascade do |t|
    t.integer "account_id", null: false
    t.integer "inbox_id", null: false
    t.integer "status", default: 0, null: false
    t.integer "assignee_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.bigint "contact_id"
    t.integer "display_id", null: false
    t.datetime "contact_last_seen_at", precision: nil
    t.datetime "agent_last_seen_at", precision: nil
    t.jsonb "additional_attributes", default: {}
    t.bigint "contact_inbox_id"
    t.uuid "uuid", default: -> { "gen_random_uuid()" }, null: false
    t.string "identifier"
    t.datetime "last_activity_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.bigint "team_id"
    t.bigint "campaign_id"
    t.datetime "snoozed_until", precision: nil
    t.jsonb "custom_attributes", default: {}
    t.datetime "assignee_last_seen_at", precision: nil
    t.datetime "first_reply_created_at", precision: nil
    t.integer "priority"
    t.bigint "sla_policy_id"
    t.datetime "waiting_since"
    t.text "cached_label_list"
    t.bigint "assignee_agent_bot_id"
    t.index ["account_id", "display_id"], name: "index_conversations_on_account_id_and_display_id", unique: true
    t.index ["account_id", "id"], name: "index_conversations_on_id_and_account_id"
    t.index ["account_id", "inbox_id", "status", "assignee_id"], name: "conv_acid_inbid_stat_asgnid_idx"
    t.index ["account_id"], name: "index_conversations_on_account_id"
    t.index ["assignee_id", "account_id"], name: "index_conversations_on_assignee_id_and_account_id"
    t.index ["campaign_id"], name: "index_conversations_on_campaign_id"
    t.index ["contact_id"], name: "index_conversations_on_contact_id"
    t.index ["contact_inbox_id"], name: "index_conversations_on_contact_inbox_id"
    t.index ["first_reply_created_at"], name: "index_conversations_on_first_reply_created_at"
    t.index ["identifier", "account_id"], name: "index_conversations_on_identifier_and_account_id"
    t.index ["inbox_id"], name: "index_conversations_on_inbox_id"
    t.index ["priority"], name: "index_conversations_on_priority"
    t.index ["status", "account_id"], name: "index_conversations_on_status_and_account_id"
    t.index ["status", "priority"], name: "index_conversations_on_status_and_priority"
    t.index ["team_id"], name: "index_conversations_on_team_id"
    t.index ["uuid"], name: "index_conversations_on_uuid", unique: true
    t.index ["waiting_since"], name: "index_conversations_on_waiting_since"
  end

  create_table "copilot_messages", force: :cascade do |t|
    t.bigint "copilot_thread_id", null: false
    t.bigint "account_id", null: false
    t.jsonb "message", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "message_type", default: 0
    t.index ["account_id"], name: "index_copilot_messages_on_account_id"
    t.index ["copilot_thread_id"], name: "index_copilot_messages_on_copilot_thread_id"
  end

  create_table "copilot_threads", force: :cascade do |t|
    t.string "title", null: false
    t.bigint "user_id", null: false
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "assistant_id"
    t.index ["account_id"], name: "index_copilot_threads_on_account_id"
    t.index ["assistant_id"], name: "index_copilot_threads_on_assistant_id"
    t.index ["user_id"], name: "index_copilot_threads_on_user_id"
  end

  create_table "crm_comments", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "commentable_type", null: false
    t.bigint "commentable_id", null: false
    t.bigint "user_id", null: false
    t.text "body", null: false
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "commentable_type", "commentable_id", "created_at"], name: "index_crm_comments_on_account_and_commentable_created_at"
    t.index ["account_id"], name: "index_crm_comments_on_account_id"
    t.index ["user_id"], name: "index_crm_comments_on_user_id"
  end

  create_table "crm_deal_contacts", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "deal_id", null: false
    t.bigint "contact_id", null: false
    t.boolean "primary", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "contact_id"], name: "index_crm_deal_contacts_on_account_contact"
    t.index ["account_id"], name: "index_crm_deal_contacts_on_account_id"
    t.index ["contact_id"], name: "index_crm_deal_contacts_on_contact_id"
    t.index ["deal_id", "contact_id"], name: "index_crm_deal_contacts_on_deal_contact", unique: true
    t.index ["deal_id"], name: "index_crm_deal_contacts_on_deal_id"
    t.index ["deal_id"], name: "index_crm_deal_contacts_on_primary_contact", unique: true, where: "(\"primary\" = true)"
  end

  create_table "crm_deals", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "pipeline_id", null: false
    t.bigint "stage_id", null: false
    t.bigint "owner_id"
    t.bigint "creator_id"
    t.bigint "team_id"
    t.bigint "company_id"
    t.bigint "originating_conversation_id"
    t.string "title", null: false
    t.text "description"
    t.bigint "amount_minor"
    t.string "currency"
    t.date "expected_close_on"
    t.datetime "closed_at"
    t.integer "win_probability"
    t.string "external_ref"
    t.string "idempotency_key"
    t.integer "lock_version", default: 0, null: false
    t.jsonb "custom_attributes", default: {}, null: false
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "position", default: 0, null: false
    t.bigint "originating_communication_thread_id"
    t.jsonb "closing_reasons", default: [], null: false
    t.index ["account_id", "company_id"], name: "index_crm_deals_on_account_company"
    t.index ["account_id", "expected_close_on", "updated_at", "id"], name: "index_crm_deals_on_active_ordering", order: { updated_at: :desc, id: :desc }, where: "(archived_at IS NULL)"
    t.index ["account_id", "external_ref"], name: "index_crm_deals_on_account_external_ref", unique: true, where: "(external_ref IS NOT NULL)"
    t.index ["account_id", "idempotency_key"], name: "index_crm_deals_on_account_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["account_id", "originating_communication_thread_id"], name: "index_crm_deals_on_account_originating_thread"
    t.index ["account_id", "originating_conversation_id"], name: "index_crm_deals_on_account_originating_conversation"
    t.index ["account_id", "pipeline_id", "stage_id", "owner_id", "expected_close_on"], name: "index_crm_deals_on_active_list_dimensions", where: "(archived_at IS NULL)"
    t.index ["account_id", "stage_id", "position", "id"], name: "index_crm_deals_on_account_stage_position"
    t.index ["account_id", "team_id"], name: "index_crm_deals_on_account_team"
    t.index ["account_id"], name: "index_crm_deals_on_account_id"
    t.index ["company_id"], name: "index_crm_deals_on_company_id"
    t.index ["creator_id"], name: "index_crm_deals_on_creator_id"
    t.index ["custom_attributes"], name: "index_crm_deals_on_custom_attributes", using: :gin
    t.index ["originating_communication_thread_id"], name: "index_crm_deals_on_originating_communication_thread_id"
    t.index ["originating_conversation_id"], name: "index_crm_deals_on_originating_conversation_id"
    t.index ["owner_id"], name: "index_crm_deals_on_owner_id"
    t.index ["pipeline_id"], name: "index_crm_deals_on_pipeline_id"
    t.index ["stage_id"], name: "index_crm_deals_on_stage_id"
    t.index ["team_id"], name: "index_crm_deals_on_team_id"
  end

  create_table "crm_events", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "eventable_type", null: false
    t.bigint "eventable_id", null: false
    t.bigint "actor_id"
    t.string "event_type", null: false
    t.jsonb "meta", default: {}, null: false
    t.datetime "created_at", null: false
    t.index ["account_id", "eventable_type", "eventable_id", "created_at"], name: "index_crm_events_on_account_eventable_created_at"
    t.index ["account_id"], name: "index_crm_events_on_account_id"
    t.index ["actor_id"], name: "index_crm_events_on_actor_id"
  end

  create_table "crm_field_definitions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "entity_kind", null: false
    t.string "key", null: false
    t.string "label", null: false
    t.text "description"
    t.string "field_type", null: false
    t.boolean "required", default: false, null: false
    t.boolean "active", default: true, null: false
    t.integer "position", default: 0, null: false
    t.jsonb "default_value"
    t.jsonb "options", default: [], null: false
    t.jsonb "rules", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "entity_kind", "active", "position"], name: "index_crm_field_definitions_on_account_entity_active_position"
    t.index ["account_id", "entity_kind", "key"], name: "index_crm_field_defs_on_account_kind_key", unique: true
    t.index ["account_id"], name: "index_crm_field_definitions_on_account_id"
  end

  create_table "crm_pipelines", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "name", null: false
    t.string "code", null: false
    t.integer "position", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.boolean "default", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "auto_create_deal_on_channel_contact", default: false, null: false
    t.index ["account_id", "code"], name: "index_crm_pipelines_on_account_id_and_code", unique: true
    t.index ["account_id"], name: "index_crm_pipelines_on_account_default_active", unique: true, where: "((\"default\" = true) AND (active = true))"
    t.index ["account_id"], name: "index_crm_pipelines_on_account_id"
  end

  create_table "crm_stages", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "pipeline_id", null: false
    t.string "name", null: false
    t.string "code", null: false
    t.integer "position", default: 0, null: false
    t.string "outcome", default: "open", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "color", default: "#E11D48", null: false
    t.boolean "default", default: false, null: false
    t.jsonb "closing_reason_options", default: [], null: false
    t.boolean "closing_reason_required", default: false, null: false
    t.jsonb "transition_reason_options", default: [], null: false
    t.boolean "transition_reason_required", default: false, null: false
    t.index ["account_id", "pipeline_id", "position"], name: "index_crm_stages_on_account_pipeline_position"
    t.index ["account_id"], name: "index_crm_stages_on_account_id"
    t.index ["pipeline_id", "code"], name: "index_crm_stages_on_pipeline_id_and_code", unique: true
    t.index ["pipeline_id"], name: "index_crm_stages_on_pipeline_default_active", unique: true, where: "((\"default\" = true) AND (active = true))"
    t.index ["pipeline_id"], name: "index_crm_stages_on_pipeline_id"
  end

  create_table "crm_task_statuses", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "name", null: false
    t.string "code", null: false
    t.integer "position", default: 0, null: false
    t.string "category", default: "open", null: false
    t.boolean "active", default: true, null: false
    t.boolean "default", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "color", default: "#F0F0F3", null: false
    t.index ["account_id", "code"], name: "index_crm_task_statuses_on_account_id_and_code", unique: true
    t.index ["account_id"], name: "index_crm_task_statuses_on_account_default_open", unique: true, where: "((\"default\" = true) AND ((category)::text = 'open'::text))"
    t.index ["account_id"], name: "index_crm_task_statuses_on_account_id"
  end

  create_table "crm_tasks", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "deal_id"
    t.bigint "status_id", null: false
    t.bigint "assignee_id"
    t.bigint "creator_id"
    t.bigint "team_id"
    t.string "title", null: false
    t.text "description"
    t.string "priority", default: "medium", null: false
    t.datetime "start_at"
    t.datetime "due_at"
    t.datetime "completed_at"
    t.string "external_ref"
    t.string "idempotency_key"
    t.integer "lock_version", default: 0, null: false
    t.jsonb "custom_attributes", default: {}, null: false
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "originating_conversation_id"
    t.integer "position", default: 0, null: false
    t.string "activity_type", default: "task", null: false
    t.string "outcome"
    t.text "outcome_note"
    t.index ["account_id", "activity_type", "due_at"], name: "index_crm_tasks_on_account_activity_type_due_at"
    t.index ["account_id", "deal_id", "activity_type"], name: "index_crm_tasks_on_account_deal_activity_type"
    t.index ["account_id", "deal_id"], name: "index_crm_tasks_on_account_deal"
    t.index ["account_id", "due_at", "updated_at", "id"], name: "index_crm_tasks_on_active_ordering", order: { updated_at: :desc, id: :desc }, where: "(archived_at IS NULL)"
    t.index ["account_id", "external_ref"], name: "index_crm_tasks_on_account_external_ref", unique: true, where: "(external_ref IS NOT NULL)"
    t.index ["account_id", "idempotency_key"], name: "index_crm_tasks_on_account_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["account_id", "originating_conversation_id"], name: "index_crm_tasks_on_account_originating_conversation"
    t.index ["account_id", "status_id", "assignee_id", "due_at"], name: "index_crm_tasks_on_active_list_dimensions", where: "(archived_at IS NULL)"
    t.index ["account_id", "status_id", "position", "id"], name: "index_crm_tasks_on_account_status_position"
    t.index ["account_id", "team_id"], name: "index_crm_tasks_on_account_team"
    t.index ["account_id"], name: "index_crm_tasks_on_account_id"
    t.index ["assignee_id"], name: "index_crm_tasks_on_assignee_id"
    t.index ["creator_id"], name: "index_crm_tasks_on_creator_id"
    t.index ["custom_attributes"], name: "index_crm_tasks_on_custom_attributes", using: :gin
    t.index ["deal_id"], name: "index_crm_tasks_on_deal_id"
    t.index ["originating_conversation_id"], name: "index_crm_tasks_on_originating_conversation_id"
    t.index ["status_id"], name: "index_crm_tasks_on_status_id"
    t.index ["team_id"], name: "index_crm_tasks_on_team_id"
  end

  create_table "csat_survey_responses", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "conversation_id", null: false
    t.bigint "message_id", null: false
    t.integer "rating", null: false
    t.text "feedback_message"
    t.bigint "contact_id", null: false
    t.bigint "assigned_agent_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "csat_review_notes"
    t.datetime "review_notes_updated_at"
    t.bigint "review_notes_updated_by_id"
    t.index ["account_id"], name: "index_csat_survey_responses_on_account_id"
    t.index ["assigned_agent_id"], name: "index_csat_survey_responses_on_assigned_agent_id"
    t.index ["contact_id"], name: "index_csat_survey_responses_on_contact_id"
    t.index ["conversation_id"], name: "index_csat_survey_responses_on_conversation_id"
    t.index ["message_id"], name: "index_csat_survey_responses_on_message_id", unique: true
    t.index ["review_notes_updated_by_id"], name: "index_csat_survey_responses_on_review_notes_updated_by_id"
  end

  create_table "custom_attribute_definitions", force: :cascade do |t|
    t.string "attribute_display_name"
    t.string "attribute_key"
    t.integer "attribute_display_type", default: 0
    t.integer "default_value"
    t.integer "attribute_model", default: 0
    t.bigint "account_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "attribute_description"
    t.jsonb "attribute_values", default: []
    t.string "regex_pattern"
    t.string "regex_cue"
    t.index ["account_id"], name: "index_custom_attribute_definitions_on_account_id"
    t.index ["attribute_key", "attribute_model", "account_id"], name: "attribute_key_model_index", unique: true
  end

  create_table "custom_filters", force: :cascade do |t|
    t.string "name", null: false
    t.integer "filter_type", default: 0, null: false
    t.jsonb "query", default: "{}", null: false
    t.bigint "account_id", null: false
    t.bigint "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_custom_filters_on_account_id"
    t.index ["user_id"], name: "index_custom_filters_on_user_id"
  end

  create_table "custom_roles", force: :cascade do |t|
    t.string "name"
    t.string "description"
    t.bigint "account_id", null: false
    t.text "permissions", default: [], array: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_custom_roles_on_account_id"
  end

  create_table "dashboard_apps", force: :cascade do |t|
    t.string "title", null: false
    t.jsonb "content", default: []
    t.bigint "account_id", null: false
    t.bigint "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_dashboard_apps_on_account_id"
    t.index ["user_id"], name: "index_dashboard_apps_on_user_id"
  end

  create_table "data_imports", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "data_type", null: false
    t.integer "status", default: 0, null: false
    t.text "processing_errors"
    t.integer "total_records"
    t.integer "processed_records"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_data_imports_on_account_id"
  end

  create_table "email_templates", force: :cascade do |t|
    t.string "name", null: false
    t.text "body", null: false
    t.integer "account_id"
    t.integer "template_type", default: 1
    t.integer "locale", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name", "account_id"], name: "index_email_templates_on_name_and_account_id", unique: true
  end

  create_table "folders", force: :cascade do |t|
    t.integer "account_id", null: false
    t.integer "category_id", null: false
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "inbox_assignment_policies", force: :cascade do |t|
    t.bigint "inbox_id", null: false
    t.bigint "assignment_policy_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["assignment_policy_id"], name: "index_inbox_assignment_policies_on_assignment_policy_id"
    t.index ["inbox_id"], name: "index_inbox_assignment_policies_on_inbox_id", unique: true
  end

  create_table "inbox_capacity_limits", force: :cascade do |t|
    t.bigint "agent_capacity_policy_id", null: false
    t.bigint "inbox_id", null: false
    t.integer "conversation_limit", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_capacity_policy_id", "inbox_id"], name: "idx_on_agent_capacity_policy_id_inbox_id_71c7ec4caf", unique: true
    t.index ["agent_capacity_policy_id"], name: "index_inbox_capacity_limits_on_agent_capacity_policy_id"
    t.index ["inbox_id"], name: "index_inbox_capacity_limits_on_inbox_id"
  end

  create_table "inbox_members", id: :serial, force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "inbox_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["inbox_id", "user_id"], name: "index_inbox_members_on_inbox_id_and_user_id", unique: true
    t.index ["inbox_id"], name: "index_inbox_members_on_inbox_id"
  end

  create_table "inboxes", id: :serial, force: :cascade do |t|
    t.integer "channel_id", null: false
    t.integer "account_id", null: false
    t.string "name", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "channel_type"
    t.boolean "enable_auto_assignment", default: true
    t.boolean "greeting_enabled", default: false
    t.string "greeting_message"
    t.string "email_address"
    t.boolean "working_hours_enabled", default: false
    t.string "out_of_office_message"
    t.string "timezone", default: "Asia/Almaty"
    t.boolean "enable_email_collect", default: true
    t.boolean "csat_survey_enabled", default: false
    t.boolean "allow_messages_after_resolved", default: true
    t.jsonb "auto_assignment_config", default: {}
    t.boolean "lock_to_single_conversation", default: false, null: false
    t.bigint "portal_id"
    t.integer "sender_name_type", default: 0, null: false
    t.string "business_name"
    t.jsonb "csat_config", default: {}, null: false
    t.datetime "deleting_at"
    t.index ["account_id", "deleting_at"], name: "index_inboxes_on_account_id_and_deleting_at"
    t.index ["account_id"], name: "index_inboxes_on_account_id"
    t.index ["channel_id", "channel_type"], name: "index_inboxes_on_channel_id_and_channel_type"
    t.index ["portal_id"], name: "index_inboxes_on_portal_id"
  end

  create_table "installation_configs", force: :cascade do |t|
    t.string "name", null: false
    t.jsonb "serialized_value", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "locked", default: true, null: false
    t.index ["name", "created_at"], name: "index_installation_configs_on_name_and_created_at", unique: true
    t.index ["name"], name: "index_installation_configs_on_name", unique: true
  end

  create_table "integrations_hooks", force: :cascade do |t|
    t.integer "status", default: 1
    t.integer "inbox_id"
    t.integer "account_id"
    t.string "app_id"
    t.integer "hook_type", default: 0
    t.string "reference_id"
    t.string "access_token"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "settings", default: {}
    t.check_constraint "app_id::text <> 'postiz'::text", name: "integrations_hooks_app_id_not_postiz"
  end

  create_table "kaspi_pay_payments", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "integration_hook_id", null: false
    t.string "source_type"
    t.bigint "source_id"
    t.string "payment_type", null: false
    t.integer "amount", null: false
    t.string "currency", default: "KZT", null: false
    t.string "kaspi_operation_id"
    t.string "kaspi_order_number"
    t.string "status", default: "pending", null: false
    t.string "status_description"
    t.text "qr_token"
    t.string "receipt_url"
    t.datetime "expires_at"
    t.datetime "paid_at"
    t.datetime "failed_at"
    t.string "idempotency_key"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "qr_original_token"
    t.index ["account_id", "idempotency_key"], name: "index_kaspi_pay_payments_on_account_id_and_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["account_id", "kaspi_operation_id"], name: "index_kaspi_pay_payments_on_account_id_and_kaspi_operation_id", unique: true, where: "(kaspi_operation_id IS NOT NULL)"
    t.index ["account_id", "status"], name: "index_kaspi_pay_payments_on_account_id_and_status"
    t.index ["account_id"], name: "index_kaspi_pay_payments_on_account_id"
    t.index ["integration_hook_id"], name: "index_kaspi_pay_payments_on_integration_hook_id"
    t.index ["source_type", "source_id"], name: "index_kaspi_pay_payments_on_source"
  end

  create_table "labels", force: :cascade do |t|
    t.string "title"
    t.text "description"
    t.string "color", default: "#1f93ff", null: false
    t.boolean "show_on_sidebar"
    t.bigint "account_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "display_title"
    t.string "marker_type", default: "color", null: false
    t.string "emoji"
    t.index ["account_id"], name: "index_labels_on_account_id"
    t.index ["title", "account_id"], name: "index_labels_on_title_and_account_id", unique: true
  end

  create_table "lead_forms", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "inbox_id"
    t.string "name", null: false
    t.text "description"
    t.string "source_kind", null: false
    t.string "status", default: "active", null: false
    t.string "external_ref"
    t.string "public_token", null: false
    t.jsonb "field_schema", default: [], null: false
    t.jsonb "settings", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "source_kind", "external_ref"], name: "idx_on_account_id_source_kind_external_ref_7153b85ff3", unique: true, where: "(external_ref IS NOT NULL)"
    t.index ["account_id", "source_kind", "status"], name: "index_lead_forms_on_account_id_and_source_kind_and_status"
    t.index ["account_id"], name: "index_lead_forms_on_account_id"
    t.index ["inbox_id"], name: "index_lead_forms_on_inbox_id"
    t.index ["public_token"], name: "index_lead_forms_on_public_token", unique: true
    t.index ["settings"], name: "index_lead_forms_on_settings", using: :gin
  end

  create_table "lead_submissions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "lead_form_id", null: false
    t.bigint "inbox_id"
    t.bigint "contact_id"
    t.bigint "contact_inbox_id"
    t.bigint "conversation_id"
    t.bigint "crm_deal_id"
    t.string "source_kind", null: false
    t.string "status", default: "received", null: false
    t.string "external_ref"
    t.string "idempotency_key"
    t.jsonb "field_values", default: {}, null: false
    t.jsonb "utm", default: {}, null: false
    t.jsonb "payload", default: {}, null: false
    t.jsonb "processing_errors", default: {}, null: false
    t.datetime "processed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "lead_form_id", "external_ref"], name: "idx_lead_submissions_form_external_ref", unique: true, where: "(external_ref IS NOT NULL)"
    t.index ["account_id", "lead_form_id", "idempotency_key"], name: "idx_lead_submissions_form_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["account_id", "source_kind", "created_at"], name: "idx_on_account_id_source_kind_created_at_6919889fce"
    t.index ["account_id"], name: "index_lead_submissions_on_account_id"
    t.index ["contact_id"], name: "index_lead_submissions_on_contact_id"
    t.index ["contact_inbox_id"], name: "index_lead_submissions_on_contact_inbox_id"
    t.index ["conversation_id"], name: "index_lead_submissions_on_conversation_id"
    t.index ["crm_deal_id"], name: "index_lead_submissions_on_crm_deal_id"
    t.index ["field_values"], name: "index_lead_submissions_on_field_values", using: :gin
    t.index ["inbox_id"], name: "index_lead_submissions_on_inbox_id"
    t.index ["lead_form_id"], name: "index_lead_submissions_on_lead_form_id"
    t.index ["payload"], name: "index_lead_submissions_on_payload", using: :gin
  end

  create_table "leaves", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "user_id", null: false
    t.date "start_date", null: false
    t.date "end_date", null: false
    t.integer "leave_type", default: 0, null: false
    t.integer "status", default: 0, null: false
    t.text "reason"
    t.bigint "approved_by_id"
    t.datetime "approved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "status"], name: "index_leaves_on_account_id_and_status"
    t.index ["account_id"], name: "index_leaves_on_account_id"
    t.index ["approved_by_id"], name: "index_leaves_on_approved_by_id"
    t.index ["user_id"], name: "index_leaves_on_user_id"
  end

  create_table "llm_budget_policies", force: :cascade do |t|
    t.integer "account_id"
    t.string "scope_type", default: "account", null: false
    t.string "feature"
    t.boolean "active", default: true, null: false
    t.boolean "hard_stop", default: false, null: false
    t.decimal "daily_budget", precision: 14, scale: 8
    t.decimal "monthly_budget", precision: 14, scale: 8
    t.decimal "warning_threshold", precision: 5, scale: 4, default: "0.8"
    t.string "fallback_profile"
    t.jsonb "per_feature_caps", default: {}, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "feature", "active"], name: "idx_llm_budget_policies_account_feature_active"
    t.index ["scope_type", "active"], name: "idx_llm_budget_policies_scope_active"
  end

  create_table "llm_embedding_model_profiles", force: :cascade do |t|
    t.string "provider_platform", null: false
    t.string "model_id", null: false
    t.integer "default_dimensions"
    t.jsonb "supported_dimensions", default: [], null: false
    t.integer "min_dimensions"
    t.integer "max_dimensions"
    t.boolean "supports_dimension_override", default: false, null: false
    t.boolean "supports_input_type", default: false, null: false
    t.boolean "supports_text_input", default: false, null: false
    t.boolean "supports_image_input", default: false, null: false
    t.string "probe_status"
    t.text "probe_error"
    t.datetime "probed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["provider_platform", "model_id"], name: "idx_llm_embedding_profiles_provider_model", unique: true
    t.index ["provider_platform", "probe_status"], name: "idx_llm_embedding_profiles_provider_status"
  end

  create_table "llm_eval_runs", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "user_id"
    t.string "status", default: "queued", null: false
    t.string "mode", default: "evals", null: false
    t.jsonb "pack_ids", default: [], null: false
    t.integer "requested_budget_cents", default: 0, null: false
    t.integer "max_cases"
    t.jsonb "result", default: {}, null: false
    t.jsonb "metadata", default: {}, null: false
    t.text "error_message"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "created_at"], name: "index_llm_eval_runs_on_account_id_and_created_at"
    t.index ["account_id", "status"], name: "index_llm_eval_runs_on_account_id_and_status"
    t.index ["account_id"], name: "index_llm_eval_runs_on_account_id"
    t.index ["account_id"], name: "index_llm_eval_runs_one_active_live_per_account", unique: true, where: "(((status)::text = ANY (ARRAY[('queued'::character varying)::text, ('running'::character varying)::text])) AND ((metadata ->> 'queued_llm_model_run'::text) = 'true'::text))"
    t.index ["user_id"], name: "index_llm_eval_runs_on_user_id"
  end

  create_table "llm_event_annotations", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "llm_event_id", null: false
    t.bigint "user_id", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "llm_event_id", "created_at"], name: "index_llm_event_annotations_on_account_event_created_at"
    t.index ["account_id"], name: "index_llm_event_annotations_on_account_id"
    t.index ["llm_event_id"], name: "index_llm_event_annotations_on_llm_event_id"
    t.index ["user_id"], name: "index_llm_event_annotations_on_user_id"
  end

  create_table "llm_events", force: :cascade do |t|
    t.integer "account_id"
    t.bigint "assistant_id"
    t.bigint "conversation_id"
    t.integer "conversation_display_id"
    t.bigint "copilot_thread_id"
    t.string "event_name", null: false
    t.string "feature"
    t.string "runtime_mode"
    t.string "status"
    t.string "reason"
    t.string "provider"
    t.string "model"
    t.string "tool_name"
    t.string "schema_name"
    t.string "current_agent"
    t.string "channel_type"
    t.string "source"
    t.string "session_id"
    t.integer "prompt_tokens"
    t.integer "completion_tokens"
    t.integer "total_tokens"
    t.integer "duration_ms"
    t.integer "credit_multiplier"
    t.decimal "estimated_cost", precision: 12, scale: 8
    t.boolean "blocked", default: false, null: false
    t.boolean "moderation_skipped", default: false, null: false
    t.boolean "schema_invalid", default: false, null: false
    t.boolean "tool_failure", default: false, null: false
    t.boolean "error", default: false, null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "trace_id"
    t.string "request_id"
    t.string "project_case_id"
    t.string "error_code"
    t.integer "queue_wait_ms"
    t.integer "thinking_tokens"
    t.integer "payload_bytes"
    t.boolean "payload_truncated", default: false, null: false
    t.integer "retry_count"
    t.integer "tool_calls_count"
    t.integer "schema_invalid_count"
    t.index ["account_id", "created_at"], name: "index_llm_events_on_account_created_at"
    t.index ["account_id", "error_code", "created_at"], name: "index_llm_events_on_account_error_code_created_at", where: "(error_code IS NOT NULL)"
    t.index ["account_id", "feature", "created_at"], name: "index_llm_events_on_account_feature_created_at"
    t.index ["account_id", "model", "created_at"], name: "index_llm_events_on_account_model_created_at"
    t.index ["account_id", "project_case_id", "created_at"], name: "index_llm_events_on_account_project_case_created_at", where: "(project_case_id IS NOT NULL)"
    t.index ["account_id", "request_id", "created_at"], name: "index_llm_events_on_account_request_created_at", where: "(request_id IS NOT NULL)"
    t.index ["account_id", "session_id", "created_at"], name: "index_llm_events_on_account_session_created_at", where: "(session_id IS NOT NULL)"
    t.index ["account_id", "trace_id", "created_at"], name: "index_llm_events_on_account_trace_created_at", where: "(trace_id IS NOT NULL)"
    t.index ["assistant_id", "created_at"], name: "index_llm_events_on_assistant_created_at"
    t.index ["conversation_id", "created_at"], name: "index_llm_events_on_conversation_created_at"
    t.index ["event_name", "created_at"], name: "index_llm_events_on_event_name_created_at"
  end

  create_table "llm_model_catalog_entries", force: :cascade do |t|
    t.string "provider_platform", null: false
    t.string "model_id", null: false
    t.string "canonical_slug"
    t.string "display_name", null: false
    t.string "model_type", null: false
    t.jsonb "input_modalities", default: [], null: false
    t.jsonb "output_modalities", default: [], null: false
    t.jsonb "supported_parameters", default: [], null: false
    t.jsonb "capabilities", default: [], null: false
    t.integer "context_length"
    t.integer "max_output_tokens"
    t.jsonb "pricing", default: {}, null: false
    t.jsonb "top_provider", default: {}, null: false
    t.string "knowledge_cutoff"
    t.text "description"
    t.jsonb "raw_payload", default: {}, null: false
    t.string "source", default: "openrouter_api", null: false
    t.datetime "fetched_at", null: false
    t.datetime "stale_at"
    t.datetime "disabled_at"
    t.string "checksum"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["provider_platform", "disabled_at"], name: "idx_llm_model_catalog_provider_disabled"
    t.index ["provider_platform", "model_id"], name: "idx_llm_model_catalog_provider_model", unique: true
    t.index ["provider_platform", "model_type"], name: "idx_llm_model_catalog_provider_type"
    t.index ["provider_platform", "stale_at"], name: "idx_llm_model_catalog_provider_stale"
  end

  create_table "llm_model_endpoint_entries", force: :cascade do |t|
    t.string "provider_platform", null: false
    t.string "model_id", null: false
    t.string "endpoint_slug", null: false
    t.string "endpoint_provider_name"
    t.string "endpoint_provider_key"
    t.jsonb "supported_parameters", default: [], null: false
    t.jsonb "capabilities", default: [], null: false
    t.integer "context_length"
    t.integer "max_prompt_tokens"
    t.integer "max_completion_tokens"
    t.jsonb "pricing", default: {}, null: false
    t.integer "latency_ms"
    t.decimal "throughput_tokens_per_second", precision: 12, scale: 4
    t.decimal "uptime_last_30m", precision: 5, scale: 2
    t.string "quantization"
    t.string "data_collection"
    t.boolean "zdr"
    t.jsonb "raw_payload", default: {}, null: false
    t.datetime "fetched_at", null: false
    t.datetime "stale_at"
    t.string "checksum"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["provider_platform", "endpoint_provider_key"], name: "idx_llm_endpoint_provider_key"
    t.index ["provider_platform", "model_id", "endpoint_provider_key", "endpoint_slug"], name: "idx_llm_endpoint_provider_model_key_slug", unique: true
    t.index ["provider_platform", "model_id"], name: "idx_llm_endpoint_provider_model"
    t.index ["provider_platform", "stale_at"], name: "idx_llm_endpoint_provider_stale"
  end

  create_table "llm_usage_events", force: :cascade do |t|
    t.integer "account_id"
    t.bigint "llm_event_id", null: false
    t.datetime "occurred_at", null: false
    t.string "event_name", null: false
    t.string "feature"
    t.string "provider"
    t.string "actual_provider"
    t.string "requested_model"
    t.string "actual_model"
    t.string "routing_profile"
    t.string "status"
    t.string "error_code"
    t.integer "prompt_tokens"
    t.integer "completion_tokens"
    t.integer "reasoning_tokens"
    t.integer "cached_tokens"
    t.integer "total_tokens"
    t.decimal "estimated_cost", precision: 14, scale: 8
    t.integer "duration_ms"
    t.string "generation_id"
    t.string "trace_id"
    t.string "session_id"
    t.string "request_id"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "feature", "occurred_at"], name: "idx_llm_usage_events_account_feature_occurred"
    t.index ["account_id", "generation_id"], name: "idx_llm_usage_events_account_generation", where: "(generation_id IS NOT NULL)"
    t.index ["account_id", "occurred_at"], name: "idx_llm_usage_events_account_occurred"
    t.index ["llm_event_id"], name: "index_llm_usage_events_on_llm_event_id", unique: true
    t.index ["provider", "occurred_at"], name: "idx_llm_usage_events_provider_occurred"
  end

  create_table "macros", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "name", null: false
    t.integer "visibility", default: 0
    t.bigint "created_by_id"
    t.bigint "updated_by_id"
    t.jsonb "actions", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_macros_on_account_id"
  end

  create_table "medelement_provider_commands", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "hook_id"
    t.bigint "appointment_id"
    t.bigint "contact_id"
    t.bigint "confirmation_request_id"
    t.bigint "requested_by_id"
    t.string "operation", null: false
    t.string "status", default: "awaiting_confirmation", null: false
    t.string "idempotency_key", null: false
    t.string "provider_patient_code"
    t.string "provider_reception_code"
    t.string "company_cabinet_code"
    t.datetime "desired_starts_at"
    t.datetime "desired_ends_at"
    t.jsonb "execution_state", default: {}, null: false
    t.integer "attempt_count", default: 0, null: false
    t.string "last_error_code"
    t.integer "last_error_status"
    t.datetime "confirmed_at"
    t.datetime "executed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "appointment_id"], name: "idx_medelement_commands_unfinished_appointment", unique: true, where: "((appointment_id IS NOT NULL) AND ((status)::text = ANY ((ARRAY['awaiting_confirmation'::character varying, 'awaiting_patient_selection'::character varying, 'awaiting_patient_creation'::character varying, 'awaiting_phone_refresh'::character varying, 'queued'::character varying, 'processing'::character varying, 'reconciliation_required'::character varying, 'v2_awaiting_confirmation'::character varying, 'v2_awaiting_patient_selection'::character varying, 'v2_awaiting_patient_creation'::character varying, 'v2_awaiting_phone_refresh'::character varying, 'v2_queued'::character varying, 'v2_processing'::character varying, 'v2_reconciliation_required'::character varying])::text[])))"
    t.index ["account_id", "contact_id"], name: "idx_medelement_commands_unfinished_patient_identity", unique: true, where: "((contact_id IS NOT NULL) AND (((operation)::text = ANY ((ARRAY['create_patient'::character varying, 'update_patient'::character varying])::text[])) OR (((operation)::text = 'create_reception'::text) AND ((provider_patient_code IS NULL) OR ((provider_patient_code)::text = ''::text)))) AND ((status)::text = ANY ((ARRAY['awaiting_confirmation'::character varying, 'awaiting_patient_selection'::character varying, 'awaiting_patient_creation'::character varying, 'awaiting_phone_refresh'::character varying, 'queued'::character varying, 'processing'::character varying, 'reconciliation_required'::character varying, 'v2_awaiting_confirmation'::character varying, 'v2_awaiting_patient_selection'::character varying, 'v2_awaiting_patient_creation'::character varying, 'v2_awaiting_phone_refresh'::character varying, 'v2_queued'::character varying, 'v2_processing'::character varying, 'v2_reconciliation_required'::character varying])::text[])))"
    t.index ["account_id", "idempotency_key"], name: "idx_medelement_commands_account_idempotency", unique: true
    t.index ["account_id"], name: "index_medelement_provider_commands_on_account_id"
    t.index ["appointment_id", "status"], name: "idx_medelement_commands_appointment_status"
    t.index ["appointment_id"], name: "index_medelement_provider_commands_on_appointment_id"
    t.index ["confirmation_request_id"], name: "index_medelement_provider_commands_on_confirmation_request_id"
    t.index ["contact_id"], name: "index_medelement_provider_commands_on_contact_id"
    t.index ["hook_id", "status"], name: "idx_medelement_commands_hook_status"
    t.index ["hook_id"], name: "index_medelement_provider_commands_on_hook_id"
    t.index ["requested_by_id"], name: "index_medelement_provider_commands_on_requested_by_id"
  end

  create_table "medelement_sync_conflicts", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "hook_id"
    t.bigint "first_sync_run_id"
    t.bigint "last_sync_run_id"
    t.bigint "resolved_by_id"
    t.string "phase", null: false
    t.string "entity_type", null: false
    t.string "conflict_type", null: false
    t.string "fingerprint", null: false
    t.string "entity_key_digest", null: false
    t.string "severity", default: "warning", null: false
    t.string "status", default: "open", null: false
    t.jsonb "details", default: {}, null: false
    t.integer "occurrences", default: 1, null: false
    t.datetime "first_seen_at", null: false
    t.datetime "last_seen_at", null: false
    t.datetime "resolved_at"
    t.text "resolution_note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "fingerprint"], name: "idx_medelement_sync_conflicts_account_fingerprint", unique: true
    t.index ["account_id", "status", "last_seen_at"], name: "idx_medelement_sync_conflicts_account_status"
    t.index ["account_id"], name: "index_medelement_sync_conflicts_on_account_id"
    t.index ["first_sync_run_id"], name: "index_medelement_sync_conflicts_on_first_sync_run_id"
    t.index ["hook_id", "phase", "status"], name: "idx_medelement_sync_conflicts_hook_phase_status"
    t.index ["hook_id"], name: "index_medelement_sync_conflicts_on_hook_id"
    t.index ["last_sync_run_id"], name: "index_medelement_sync_conflicts_on_last_sync_run_id"
    t.index ["resolved_by_id"], name: "index_medelement_sync_conflicts_on_resolved_by_id"
  end

  create_table "medelement_sync_runs", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "hook_id"
    t.bigint "requested_by_id"
    t.string "trigger", default: "scheduled", null: false
    t.string "status", default: "queued", null: false
    t.string "current_phase"
    t.jsonb "requested_phases", default: [], null: false
    t.jsonb "phase_results", default: {}, null: false
    t.jsonb "summary", default: {}, null: false
    t.string "error_code"
    t.text "error_message"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "status"], name: "idx_medelement_sync_runs_account_status"
    t.index ["account_id"], name: "index_medelement_sync_runs_on_account_id"
    t.index ["hook_id", "created_at"], name: "idx_medelement_sync_runs_hook_created"
    t.index ["hook_id"], name: "idx_medelement_sync_runs_one_active_hook", unique: true, where: "((hook_id IS NOT NULL) AND ((status)::text = ANY ((ARRAY['queued'::character varying, 'running'::character varying, 'retrying'::character varying])::text[])))"
    t.index ["hook_id"], name: "index_medelement_sync_runs_on_hook_id"
    t.index ["requested_by_id"], name: "index_medelement_sync_runs_on_requested_by_id"
  end

  create_table "mentions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "conversation_id", null: false
    t.bigint "account_id", null: false
    t.datetime "mentioned_at", precision: nil, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_mentions_on_account_id"
    t.index ["conversation_id"], name: "index_mentions_on_conversation_id"
    t.index ["user_id", "conversation_id"], name: "index_mentions_on_user_id_and_conversation_id", unique: true
    t.index ["user_id"], name: "index_mentions_on_user_id"
  end

  create_table "messages", id: :serial, force: :cascade do |t|
    t.text "content"
    t.integer "account_id", null: false
    t.integer "inbox_id", null: false
    t.integer "conversation_id", null: false
    t.integer "message_type", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.boolean "private", default: false, null: false
    t.integer "status", default: 0
    t.text "source_id"
    t.integer "content_type", default: 0, null: false
    t.json "content_attributes", default: {}
    t.string "sender_type"
    t.bigint "sender_id"
    t.jsonb "external_source_ids", default: {}
    t.jsonb "additional_attributes", default: {}
    t.text "processed_message_content"
    t.jsonb "sentiment", default: {}
    t.index "((additional_attributes -> 'campaign_id'::text))", name: "index_messages_on_additional_attributes_campaign_id", using: :gin
    t.index ["account_id", "content_type", "created_at"], name: "idx_messages_account_content_created"
    t.index ["account_id", "created_at", "message_type"], name: "index_messages_on_account_created_type"
    t.index ["account_id", "inbox_id"], name: "index_messages_on_account_id_and_inbox_id"
    t.index ["account_id"], name: "index_messages_on_account_id"
    t.index ["content"], name: "index_messages_on_content", opclass: :gin_trgm_ops, using: :gin
    t.index ["conversation_id", "account_id", "message_type", "created_at"], name: "index_messages_on_conversation_account_type_created"
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
    t.index ["created_at"], name: "index_messages_on_created_at"
    t.index ["inbox_id", "source_id"], name: "idx_messages_unique_inbox_source_id", unique: true, where: "(source_id IS NOT NULL)"
    t.index ["inbox_id"], name: "index_messages_on_inbox_id"
    t.index ["sender_type", "sender_id"], name: "index_messages_on_sender_type_and_sender_id"
    t.index ["source_id"], name: "index_messages_on_source_id"
  end

  create_table "meta_ad_referrals", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "inbox_id", null: false
    t.bigint "contact_id"
    t.bigint "conversation_id"
    t.bigint "communication_thread_id"
    t.bigint "message_id"
    t.string "provider", null: false
    t.string "provider_message_id", null: false
    t.string "attribution_type"
    t.string "source"
    t.string "source_type"
    t.string "source_id"
    t.text "source_url"
    t.string "ad_id"
    t.string "ctwa_clid"
    t.string "ref"
    t.string "referral_type"
    t.string "headline"
    t.text "body"
    t.string "media_type"
    t.text "image_url"
    t.text "video_url"
    t.text "thumbnail_url"
    t.string "post_id"
    t.string "product_id"
    t.string "flow_id"
    t.jsonb "raw_referral", default: {}, null: false
    t.datetime "received_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "ad_id"], name: "idx_meta_ad_referrals_account_ad", where: "(ad_id IS NOT NULL)"
    t.index ["account_id", "communication_thread_id"], name: "idx_meta_ad_referrals_account_thread"
    t.index ["account_id", "conversation_id"], name: "idx_meta_ad_referrals_account_conversation"
    t.index ["account_id", "ctwa_clid"], name: "idx_meta_ad_referrals_account_ctwa", where: "(ctwa_clid IS NOT NULL)"
    t.index ["account_id", "source_id"], name: "idx_meta_ad_referrals_account_source", where: "(source_id IS NOT NULL)"
    t.index ["account_id"], name: "index_meta_ad_referrals_on_account_id"
    t.index ["communication_thread_id"], name: "index_meta_ad_referrals_on_communication_thread_id"
    t.index ["contact_id"], name: "index_meta_ad_referrals_on_contact_id"
    t.index ["conversation_id"], name: "index_meta_ad_referrals_on_conversation_id"
    t.index ["inbox_id"], name: "index_meta_ad_referrals_on_inbox_id"
    t.index ["message_id"], name: "index_meta_ad_referrals_on_message_id"
    t.index ["provider", "inbox_id", "provider_message_id"], name: "idx_meta_ad_referrals_provider_message", unique: true
  end

  create_table "meta_channel_credential_healths", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "channel_type", null: false
    t.bigint "channel_id", null: false
    t.string "status", default: "unknown", null: false
    t.string "reason"
    t.integer "provider_code"
    t.integer "provider_subcode"
    t.string "provider_type"
    t.string "provider_trace_id"
    t.datetime "expires_at"
    t.datetime "data_access_expires_at"
    t.datetime "checked_at"
    t.datetime "last_healthy_at"
    t.datetime "last_failed_at"
    t.integer "consecutive_failures", default: 0, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "status"], name: "index_meta_channel_credential_healths_on_account_status"
    t.index ["account_id"], name: "index_meta_channel_credential_healths_on_account_id"
    t.index ["channel_type", "channel_id"], name: "index_meta_channel_credential_healths_on_channel", unique: true
  end

  create_table "notes", force: :cascade do |t|
    t.text "content", null: false
    t.bigint "account_id", null: false
    t.bigint "contact_id", null: false
    t.bigint "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_notes_on_account_id"
    t.index ["contact_id"], name: "index_notes_on_contact_id"
    t.index ["user_id"], name: "index_notes_on_user_id"
  end

  create_table "notification_settings", force: :cascade do |t|
    t.integer "account_id"
    t.integer "user_id"
    t.integer "email_flags", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "push_flags", default: 0, null: false
    t.integer "inbox_flags", default: 0, null: false
    t.integer "telegram_flags", default: 0, null: false
    t.index ["account_id", "user_id"], name: "by_account_user", unique: true
  end

  create_table "notification_subscriptions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.integer "subscription_type", null: false
    t.jsonb "subscription_attributes", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "identifier"
    t.index ["identifier"], name: "index_notification_subscriptions_on_identifier", unique: true
    t.index ["user_id"], name: "index_notification_subscriptions_on_user_id"
  end

  create_table "notifications", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "user_id", null: false
    t.integer "notification_type", null: false
    t.string "primary_actor_type", null: false
    t.bigint "primary_actor_id", null: false
    t.string "secondary_actor_type"
    t.bigint "secondary_actor_id"
    t.datetime "read_at", precision: nil
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "snoozed_until"
    t.datetime "last_activity_at", default: -> { "CURRENT_TIMESTAMP" }
    t.jsonb "meta", default: {}
    t.index ["account_id"], name: "index_notifications_on_account_id"
    t.index ["last_activity_at"], name: "index_notifications_on_last_activity_at"
    t.index ["primary_actor_type", "primary_actor_id"], name: "uniq_primary_actor_per_account_notifications"
    t.index ["secondary_actor_type", "secondary_actor_id"], name: "uniq_secondary_actor_per_account_notifications"
    t.index ["user_id", "account_id", "snoozed_until", "read_at"], name: "idx_notifications_performance"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "platform_app_permissibles", force: :cascade do |t|
    t.bigint "platform_app_id", null: false
    t.string "permissible_type", null: false
    t.bigint "permissible_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["permissible_type", "permissible_id"], name: "index_platform_app_permissibles_on_permissibles"
    t.index ["platform_app_id", "permissible_id", "permissible_type"], name: "unique_permissibles_index", unique: true
    t.index ["platform_app_id"], name: "index_platform_app_permissibles_on_platform_app_id"
  end

  create_table "platform_apps", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "platform_banners", force: :cascade do |t|
    t.text "banner_message", null: false
    t.integer "banner_type", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "portals", force: :cascade do |t|
    t.integer "account_id", null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.string "custom_domain"
    t.string "color"
    t.string "homepage_link"
    t.string "page_title"
    t.text "header_text"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "config", default: {"allowed_locales" => ["en"]}
    t.boolean "archived", default: false
    t.bigint "channel_web_widget_id"
    t.jsonb "ssl_settings", default: {}, null: false
    t.index ["channel_web_widget_id"], name: "index_portals_on_channel_web_widget_id"
    t.index ["custom_domain"], name: "index_portals_on_custom_domain", unique: true
    t.index ["slug"], name: "index_portals_on_slug", unique: true
  end

  create_table "portals_members", id: false, force: :cascade do |t|
    t.bigint "portal_id", null: false
    t.bigint "user_id", null: false
    t.index ["portal_id", "user_id"], name: "index_portals_members_on_portal_id_and_user_id", unique: true
    t.index ["portal_id"], name: "index_portals_members_on_portal_id"
    t.index ["user_id"], name: "index_portals_members_on_user_id"
  end

  create_table "related_categories", force: :cascade do |t|
    t.bigint "category_id"
    t.bigint "related_category_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category_id", "related_category_id"], name: "index_related_categories_on_category_id_and_related_category_id", unique: true
    t.index ["related_category_id", "category_id"], name: "index_related_categories_on_related_category_id_and_category_id", unique: true
  end

  create_table "reminder_groups", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "creator_id"
    t.string "name", null: false
    t.text "description"
    t.jsonb "entity_kinds", default: [], null: false
    t.jsonb "touches", default: [], null: false
    t.boolean "active", default: true, null: false
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "assistant_id"
    t.index ["account_id", "active", "created_at"], name: "idx_reminder_groups_on_account_active_created"
    t.index ["account_id"], name: "index_reminder_groups_on_account_id"
    t.index ["assistant_id"], name: "index_reminder_groups_on_assistant_id"
    t.index ["creator_id"], name: "index_reminder_groups_on_creator_id"
  end

  create_table "reminders", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "creator_id"
    t.bigint "owner_id"
    t.bigint "conversation_id"
    t.bigint "target_inbox_id"
    t.bigint "target_contact_id"
    t.bigint "target_contact_inbox_id"
    t.bigint "target_conversation_id"
    t.bigint "reminder_group_id"
    t.string "remindable_type"
    t.bigint "remindable_id"
    t.integer "status", default: 0, null: false
    t.integer "action_type", default: 0, null: false
    t.integer "content_kind", default: 0, null: false
    t.integer "text_mode", default: 0, null: false
    t.integer "timing_mode", default: 0, null: false
    t.string "relative_anchor"
    t.integer "relative_offset_seconds", default: 0, null: false
    t.datetime "scheduled_at"
    t.string "timezone", default: "UTC", null: false
    t.text "body"
    t.text "instructions"
    t.jsonb "attachments", default: [], null: false
    t.jsonb "template_params", default: {}, null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "fingerprint"
    t.boolean "auto_cancel_on_incoming", default: false, null: false
    t.integer "attempts_count", default: 0, null: false
    t.text "last_error"
    t.datetime "processing_started_at"
    t.datetime "completed_at"
    t.datetime "cancelled_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "repeat_mode", default: 0, null: false
    t.datetime "repeat_until_at"
    t.string "relative_time_mode", default: "inherit_anchor_time", null: false
    t.string "relative_time_of_day"
    t.boolean "manual_schedule_override", default: false, null: false
    t.integer "schedule_revision", default: 0, null: false
    t.datetime "last_materialized_anchor_at"
    t.string "post_delivery_action"
    t.string "response_action"
    t.integer "response_button_index"
    t.index ["account_id", "fingerprint"], name: "idx_reminders_on_account_fingerprint"
    t.index ["account_id", "owner_id", "scheduled_at"], name: "idx_reminders_on_account_owner_scheduled"
    t.index ["account_id", "repeat_mode", "scheduled_at"], name: "idx_reminders_on_account_repeat_scheduled"
    t.index ["account_id", "status", "scheduled_at"], name: "idx_reminders_on_account_status_scheduled"
    t.index ["account_id"], name: "index_reminders_on_account_id"
    t.index ["conversation_id"], name: "index_reminders_on_conversation_id"
    t.index ["creator_id"], name: "index_reminders_on_creator_id"
    t.index ["owner_id"], name: "index_reminders_on_owner_id"
    t.index ["remindable_type", "remindable_id"], name: "index_reminders_on_remindable"
    t.index ["reminder_group_id"], name: "index_reminders_on_reminder_group_id"
    t.index ["target_contact_id"], name: "index_reminders_on_target_contact_id"
    t.index ["target_contact_inbox_id"], name: "index_reminders_on_target_contact_inbox_id"
    t.index ["target_conversation_id"], name: "index_reminders_on_target_conversation_id"
    t.index ["target_inbox_id"], name: "index_reminders_on_target_inbox_id"
    t.check_constraint "post_delivery_action IS NULL OR post_delivery_action::text = 'resolve_conversation'::text AND action_type = 0 AND repeat_mode = 0 AND remindable_type::text = 'Conversation'::text AND remindable_id IS NOT NULL AND conversation_id = remindable_id AND target_conversation_id = remindable_id", name: "reminders_post_delivery_action_supported"
    t.check_constraint "response_action IS NULL AND response_button_index IS NULL OR response_action::text = 'confirm_appointment'::text AND response_button_index = 0 AND action_type = 0 AND content_kind = 1 AND repeat_mode = 0 AND remindable_type::text = 'Scheduling::Appointment'::text AND remindable_id IS NOT NULL", name: "reminders_response_action_supported"
  end

  create_table "reporting_events", force: :cascade do |t|
    t.string "name"
    t.float "value"
    t.integer "account_id"
    t.integer "inbox_id"
    t.integer "user_id"
    t.integer "conversation_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.float "value_in_business_hours"
    t.datetime "event_start_time", precision: nil
    t.datetime "event_end_time", precision: nil
    t.index ["account_id", "name", "created_at"], name: "reporting_events__account_id__name__created_at"
    t.index ["account_id", "name", "inbox_id", "created_at"], name: "index_reporting_events_for_response_distribution"
    t.index ["account_id"], name: "index_reporting_events_on_account_id"
    t.index ["conversation_id"], name: "index_reporting_events_on_conversation_id"
    t.index ["created_at"], name: "index_reporting_events_on_created_at"
    t.index ["inbox_id"], name: "index_reporting_events_on_inbox_id"
    t.index ["name"], name: "index_reporting_events_on_name"
    t.index ["user_id"], name: "index_reporting_events_on_user_id"
  end

  create_table "reporting_events_rollups", force: :cascade do |t|
    t.integer "account_id", null: false
    t.date "date", null: false
    t.string "dimension_type", null: false
    t.bigint "dimension_id", null: false
    t.string "metric", null: false
    t.bigint "count", default: 0, null: false
    t.float "sum_value", default: 0.0, null: false
    t.float "sum_value_business_hours", default: 0.0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "date", "dimension_type", "dimension_id", "metric"], name: "index_rollup_unique_key", unique: true
    t.index ["account_id", "dimension_type", "date"], name: "index_rollup_summary"
    t.index ["account_id", "metric", "date"], name: "index_rollup_timeseries"
  end

  create_table "scheduling_appointments", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "resource_id", null: false
    t.bigint "contact_id"
    t.bigint "service_id"
    t.bigint "company_id"
    t.bigint "conversation_id"
    t.bigint "created_by_id"
    t.string "service_name_snapshot"
    t.string "service_type_snapshot"
    t.integer "service_duration_min_snapshot"
    t.datetime "starts_at", null: false
    t.datetime "ends_at", null: false
    t.integer "duration_min", default: 30, null: false
    t.string "status", default: "scheduled", null: false
    t.string "appointment_type", default: "primary", null: false
    t.string "client_name", null: false
    t.string "client_first_name"
    t.string "client_last_name"
    t.string "client_middle_name"
    t.string "client_phone"
    t.string "client_identifier"
    t.date "client_birth_date"
    t.string "client_gender"
    t.text "client_comment"
    t.string "source", default: "manual", null: false
    t.string "external_ref"
    t.string "idempotency_key"
    t.integer "service_amount", default: 0, null: false
    t.string "compensation_type_snapshot"
    t.integer "compensation_value_snapshot"
    t.integer "prepaid_amount", default: 0, null: false
    t.string "prepaid_payment_method"
    t.integer "settlement_amount", default: 0, null: false
    t.string "settlement_payment_method"
    t.string "payment_status", default: "awaiting_payment", null: false
    t.jsonb "custom_attributes", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "compensation_percent_snapshot", default: 0, null: false
    t.bigint "owner_id"
    t.index ["account_id", "external_ref"], name: "idx_scheduling_appointments_on_account_external_ref", unique: true, where: "(external_ref IS NOT NULL)"
    t.index ["account_id", "idempotency_key"], name: "idx_scheduling_appointments_on_account_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["account_id", "resource_id", "starts_at", "ends_at"], name: "idx_scheduling_appointments_on_account_resource_range"
    t.index ["account_id", "starts_at"], name: "idx_scheduling_appointments_on_account_starts_at"
    t.index ["account_id"], name: "index_scheduling_appointments_on_account_id"
    t.index ["company_id"], name: "index_scheduling_appointments_on_company_id"
    t.index ["contact_id"], name: "index_scheduling_appointments_on_contact_id"
    t.index ["conversation_id"], name: "index_scheduling_appointments_on_conversation_id"
    t.index ["created_by_id"], name: "index_scheduling_appointments_on_created_by_id"
    t.index ["owner_id"], name: "index_scheduling_appointments_on_owner_id"
    t.index ["resource_id"], name: "index_scheduling_appointments_on_resource_id"
    t.index ["service_id"], name: "index_scheduling_appointments_on_service_id"
  end

  create_table "scheduling_break_rules", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "resource_id", null: false
    t.integer "weekday", null: false
    t.integer "start_minute", null: false
    t.integer "end_minute", null: false
    t.string "title"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "resource_id", "weekday", "active"], name: "idx_scheduling_break_rules_on_account_resource_weekday"
    t.index ["account_id"], name: "index_scheduling_break_rules_on_account_id"
    t.index ["resource_id", "weekday", "start_minute", "end_minute"], name: "idx_scheduling_break_rules_on_resource_slot", unique: true
    t.index ["resource_id"], name: "index_scheduling_break_rules_on_resource_id"
  end

  create_table "scheduling_expenses", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "appointment_id", null: false
    t.bigint "resource_id", null: false
    t.bigint "paid_by_id"
    t.integer "amount", default: 0, null: false
    t.string "status", default: "unpaid", null: false
    t.datetime "paid_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "status"], name: "idx_scheduling_expenses_on_account_status"
    t.index ["account_id"], name: "index_scheduling_expenses_on_account_id"
    t.index ["appointment_id"], name: "index_scheduling_expenses_on_appointment_id", unique: true
    t.index ["paid_by_id"], name: "index_scheduling_expenses_on_paid_by_id"
    t.index ["resource_id"], name: "index_scheduling_expenses_on_resource_id"
  end

  create_table "scheduling_holidays", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.date "date", null: false
    t.string "title", null: false
    t.boolean "recurring_yearly", default: false, null: false
    t.boolean "working_day_override", default: false, null: false
    t.jsonb "custom_attributes", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "date"], name: "idx_scheduling_holidays_on_account_date"
    t.index ["account_id"], name: "index_scheduling_holidays_on_account_id"
  end

  create_table "scheduling_payments", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "appointment_id", null: false
    t.bigint "recorded_by_id"
    t.integer "amount", default: 0, null: false
    t.string "payment_method", null: false
    t.string "payment_kind", default: "payment", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "created_at"], name: "idx_scheduling_payments_on_account_created_at"
    t.index ["account_id"], name: "index_scheduling_payments_on_account_id"
    t.index ["appointment_id", "payment_kind"], name: "idx_scheduling_payments_on_appointment_adjustment", unique: true, where: "((payment_kind)::text = 'adjustment'::text)"
    t.index ["appointment_id", "payment_kind"], name: "idx_scheduling_payments_on_appointment_prepaid", unique: true, where: "((payment_kind)::text = 'prepaid'::text)"
    t.index ["appointment_id"], name: "index_scheduling_payments_on_appointment_id"
    t.index ["recorded_by_id"], name: "index_scheduling_payments_on_recorded_by_id"
  end

  create_table "scheduling_resources", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "user_id"
    t.string "name", null: false
    t.string "specialty"
    t.string "photo_url"
    t.text "description"
    t.string "color"
    t.string "timezone", default: "Asia/Almaty", null: false
    t.integer "slot_duration_min", default: 30, null: false
    t.string "compensation_type", default: "percent", null: false
    t.integer "compensation_value", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.jsonb "custom_attributes", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "compensation_percent", default: 0, null: false
    t.index "account_id, ((custom_attributes ->> 'medelement_specialist_code'::text))", name: "idx_scheduling_resources_account_medelement_specialist_code", unique: true, where: "((custom_attributes ->> 'medelement_specialist_code'::text) IS NOT NULL)"
    t.index ["account_id", "active", "name"], name: "idx_scheduling_resources_on_account_active_name"
    t.index ["account_id"], name: "index_scheduling_resources_on_account_id"
    t.index ["user_id"], name: "index_scheduling_resources_on_user_id"
  end

  create_table "scheduling_service_prices", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "service_id", null: false
    t.bigint "resource_id", null: false
    t.integer "price", default: 0, null: false
    t.string "compensation_type", default: "percent", null: false
    t.integer "compensation_value", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "compensation_percent", default: 0, null: false
    t.index ["account_id", "resource_id", "active"], name: "idx_scheduling_service_prices_on_account_resource_active"
    t.index ["account_id"], name: "index_scheduling_service_prices_on_account_id"
    t.index ["resource_id"], name: "index_scheduling_service_prices_on_resource_id"
    t.index ["service_id", "resource_id"], name: "idx_scheduling_service_prices_on_service_resource", unique: true
    t.index ["service_id"], name: "index_scheduling_service_prices_on_service_id"
  end

  create_table "scheduling_services", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "name", null: false
    t.integer "base_price", default: 0, null: false
    t.integer "duration_min", default: 30, null: false
    t.string "category"
    t.string "direction"
    t.string "service_type"
    t.text "description"
    t.boolean "active", default: true, null: false
    t.jsonb "custom_attributes", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "account_id, ((custom_attributes ->> 'medelement_nomenclature_code'::text))", name: "idx_scheduling_services_account_medelement_code_unique", unique: true, where: "(NULLIF(btrim((custom_attributes ->> 'medelement_nomenclature_code'::text)), ''::text) IS NOT NULL)"
    t.index ["account_id", "active", "name"], name: "idx_scheduling_services_on_account_active_name"
    t.index ["account_id"], name: "index_scheduling_services_on_account_id"
  end

  create_table "scheduling_time_offs", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "resource_id"
    t.string "kind", null: false
    t.datetime "starts_at", null: false
    t.datetime "ends_at", null: false
    t.string "title"
    t.text "notes"
    t.jsonb "custom_attributes", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "resource_id", "starts_at", "ends_at"], name: "idx_scheduling_time_offs_on_account_resource_range"
    t.index ["account_id"], name: "index_scheduling_time_offs_on_account_id"
    t.index ["resource_id"], name: "index_scheduling_time_offs_on_resource_id"
  end

  create_table "scheduling_work_rules", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "resource_id", null: false
    t.integer "weekday", null: false
    t.integer "start_minute", null: false
    t.integer "end_minute", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "resource_id", "weekday", "active"], name: "idx_scheduling_work_rules_on_account_resource_weekday"
    t.index ["account_id"], name: "index_scheduling_work_rules_on_account_id"
    t.index ["resource_id", "weekday", "start_minute", "end_minute"], name: "idx_scheduling_work_rules_on_resource_slot", unique: true
    t.index ["resource_id"], name: "index_scheduling_work_rules_on_resource_id"
  end

  create_table "scheduling_workday_overrides", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "resource_id", null: false
    t.date "date", null: false
    t.integer "start_minute", null: false
    t.integer "end_minute", null: false
    t.integer "break_start_minute"
    t.integer "break_end_minute"
    t.string "break_title"
    t.jsonb "custom_attributes", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "date"], name: "idx_scheduling_workday_overrides_on_account_date"
    t.index ["account_id"], name: "index_scheduling_workday_overrides_on_account_id"
    t.index ["resource_id", "date"], name: "idx_scheduling_workday_overrides_on_resource_date", unique: true
    t.index ["resource_id"], name: "index_scheduling_workday_overrides_on_resource_id"
  end

  create_table "sla_events", force: :cascade do |t|
    t.bigint "applied_sla_id", null: false
    t.bigint "conversation_id", null: false
    t.bigint "account_id", null: false
    t.bigint "sla_policy_id", null: false
    t.bigint "inbox_id", null: false
    t.integer "event_type"
    t.jsonb "meta", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_sla_events_on_account_id"
    t.index ["applied_sla_id"], name: "index_sla_events_on_applied_sla_id"
    t.index ["conversation_id"], name: "index_sla_events_on_conversation_id"
    t.index ["inbox_id"], name: "index_sla_events_on_inbox_id"
    t.index ["sla_policy_id"], name: "index_sla_events_on_sla_policy_id"
  end

  create_table "sla_policies", force: :cascade do |t|
    t.string "name", null: false
    t.float "first_response_time_threshold"
    t.float "next_response_time_threshold"
    t.boolean "only_during_business_hours", default: false
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "description"
    t.float "resolution_time_threshold"
    t.index ["account_id"], name: "index_sla_policies_on_account_id"
  end

  create_table "taggings", id: :serial, force: :cascade do |t|
    t.integer "tag_id"
    t.string "taggable_type"
    t.integer "taggable_id"
    t.string "tagger_type"
    t.integer "tagger_id"
    t.string "context", limit: 128
    t.datetime "created_at", precision: nil
    t.index ["context"], name: "index_taggings_on_context"
    t.index ["tag_id", "taggable_id", "taggable_type", "context", "tagger_id", "tagger_type"], name: "taggings_idx", unique: true
    t.index ["tag_id"], name: "index_taggings_on_tag_id"
    t.index ["taggable_id", "taggable_type", "context"], name: "index_taggings_on_taggable_id_and_taggable_type_and_context"
    t.index ["taggable_id", "taggable_type", "tagger_id", "context"], name: "taggings_idy"
    t.index ["taggable_id"], name: "index_taggings_on_taggable_id"
    t.index ["taggable_type"], name: "index_taggings_on_taggable_type"
    t.index ["tagger_id", "tagger_type"], name: "index_taggings_on_tagger_id_and_tagger_type"
    t.index ["tagger_id"], name: "index_taggings_on_tagger_id"
  end

  create_table "tags", id: :serial, force: :cascade do |t|
    t.string "name"
    t.integer "taggings_count", default: 0
    t.index "lower((name)::text) gin_trgm_ops", name: "tags_name_trgm_idx", using: :gin
    t.index ["name"], name: "index_tags_on_name", unique: true
  end

  create_table "team_members", force: :cascade do |t|
    t.bigint "team_id", null: false
    t.bigint "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["team_id", "user_id"], name: "index_team_members_on_team_id_and_user_id", unique: true
    t.index ["team_id"], name: "index_team_members_on_team_id"
    t.index ["user_id"], name: "index_team_members_on_user_id"
  end

  create_table "teams", force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.boolean "allow_auto_assign", default: true
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_teams_on_account_id"
    t.index ["name", "account_id"], name: "index_teams_on_name_and_account_id", unique: true
  end

  create_table "telegram_notification_bindings", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "telegram_user_id"
    t.string "telegram_chat_id"
    t.string "username"
    t.string "first_name"
    t.string "last_name"
    t.datetime "verified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["telegram_user_id"], name: "index_telegram_notification_bindings_on_telegram_user_id", unique: true, where: "(telegram_user_id IS NOT NULL)"
    t.index ["user_id"], name: "index_telegram_notification_bindings_on_user_id", unique: true
  end

  create_table "telephony_agent_bindings", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "user_id", null: false
    t.string "provider", null: false
    t.string "agent_ref", null: false
    t.string "agent_aor"
    t.string "domain_ref"
    t.string "credentials_ref"
    t.boolean "enabled", default: true, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "last_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "agent_ref"], name: "index_telephony_agent_bindings_on_account_agent_ref", unique: true
    t.index ["account_id", "user_id"], name: "index_telephony_agent_bindings_on_account_user", unique: true
    t.index ["account_id"], name: "index_telephony_agent_bindings_on_account_id"
  end

  create_table "telephony_ai_voice_fish_voices", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "created_by_id"
    t.string "provider_model_id", null: false
    t.string "title", null: false
    t.string "state", default: "created", null: false
    t.string "visibility", default: "private", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "created_at"], name: "index_fish_voices_on_account_and_created_at"
    t.index ["account_id"], name: "index_telephony_ai_voice_fish_voices_on_account_id"
    t.index ["created_by_id"], name: "index_telephony_ai_voice_fish_voices_on_created_by_id"
    t.index ["provider_model_id"], name: "index_fish_voices_on_provider_model_id", unique: true
  end

  create_table "telephony_call_sessions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "conversation_id"
    t.bigint "contact_id"
    t.bigint "inbox_id"
    t.bigint "number_binding_id"
    t.bigint "agent_binding_id"
    t.string "provider", null: false
    t.string "external_call_ref", null: false
    t.string "provider_call_sid"
    t.string "status", default: "ringing", null: false
    t.string "direction", default: "outbound", null: false
    t.string "from_number"
    t.string "to_number"
    t.string "recording_ref"
    t.string "transcript_ref"
    t.text "summary"
    t.integer "duration_seconds"
    t.datetime "started_at"
    t.datetime "ended_at"
    t.datetime "last_event_at"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "answered_at"
    t.string "answered_by"
    t.string "ended_by"
    t.string "end_reason"
    t.jsonb "legs", default: [], null: false
    t.index ["account_id", "conversation_id"], name: "index_telephony_call_sessions_on_account_conversation"
    t.index ["account_id", "created_at"], name: "index_telephony_call_sessions_on_account_created_at"
    t.index ["account_id", "external_call_ref"], name: "index_telephony_call_sessions_on_account_call_ref", unique: true
    t.index ["account_id", "provider_call_sid"], name: "index_telephony_call_sessions_on_account_provider_sid", unique: true, where: "(provider_call_sid IS NOT NULL)"
    t.index ["account_id", "status", "direction"], name: "index_telephony_call_sessions_on_account_status_direction"
    t.index ["account_id"], name: "index_telephony_call_sessions_on_account_id"
    t.index ["agent_binding_id"], name: "index_telephony_call_sessions_on_agent_binding_id"
    t.index ["contact_id"], name: "index_telephony_call_sessions_on_contact_id"
    t.index ["conversation_id"], name: "index_telephony_call_sessions_on_conversation_id"
    t.index ["inbox_id"], name: "index_telephony_call_sessions_on_inbox_id"
    t.index ["number_binding_id"], name: "index_telephony_call_sessions_on_number_binding_id"
  end

  create_table "telephony_contact_endpoints", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "contact_id", null: false
    t.bigint "inbox_id"
    t.bigint "number_binding_id"
    t.string "provider", null: false
    t.string "endpoint_type", null: false
    t.string "endpoint_value", null: false
    t.string "main_number"
    t.string "display_name"
    t.string "trunk_ref"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "verified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "contact_id", "provider"], name: "idx_tel_contact_endpoints_account_contact"
    t.index ["account_id", "main_number"], name: "idx_tel_contact_endpoints_account_main_number", where: "(main_number IS NOT NULL)"
    t.index ["account_id", "provider", "inbox_id", "endpoint_type", "endpoint_value"], name: "idx_tel_contact_endpoints_unique_inbox", unique: true, where: "(inbox_id IS NOT NULL)"
    t.index ["account_id", "provider", "number_binding_id", "endpoint_type", "endpoint_value"], name: "idx_tel_contact_endpoints_unique_binding", unique: true, where: "(number_binding_id IS NOT NULL)"
    t.index ["account_id"], name: "index_telephony_contact_endpoints_on_account_id"
    t.index ["contact_id"], name: "index_telephony_contact_endpoints_on_contact_id"
    t.index ["inbox_id"], name: "index_telephony_contact_endpoints_on_inbox_id"
    t.index ["number_binding_id"], name: "index_telephony_contact_endpoints_on_number_binding_id"
  end

  create_table "telephony_events", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "call_session_id"
    t.string "event_key", null: false
    t.string "event_type", null: false
    t.string "status", default: "received", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "processed_at"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "event_key"], name: "index_telephony_events_on_account_event_key", unique: true
    t.index ["account_id", "event_type", "created_at"], name: "index_telephony_events_on_account_event_type_created_at"
    t.index ["account_id"], name: "index_telephony_events_on_account_id"
    t.index ["call_session_id"], name: "index_telephony_events_on_call_session_id"
  end

  create_table "telephony_number_bindings", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "inbox_id", null: false
    t.string "provider", null: false
    t.string "number_ref", null: false
    t.string "phone_number"
    t.string "app_ref"
    t.string "trunk_ref"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "last_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "provider_connection_id"
    t.string "display_phone_number"
    t.string "provider_account_number"
    t.string "ingress_number"
    t.string "fonoster_tel_url"
    t.string "managed_by"
    t.string "ownership_status", default: "legacy_reference", null: false
    t.string "provisioning_status", default: "local_only", null: false
    t.datetime "last_reconciled_at"
    t.datetime "remote_drift_detected_at"
    t.jsonb "remote_drift_summary", default: {}, null: false
    t.index ["account_id", "ingress_number"], name: "idx_tel_number_bindings_account_ingress"
    t.index ["account_id", "number_ref"], name: "index_telephony_number_bindings_on_account_number_ref", unique: true
    t.index ["account_id", "ownership_status"], name: "idx_tel_number_bindings_account_ownership"
    t.index ["account_id", "phone_number"], name: "index_telephony_number_bindings_on_account_phone"
    t.index ["account_id", "provider_connection_id"], name: "idx_tel_number_bindings_account_provider_connection"
    t.index ["account_id", "provisioning_status"], name: "idx_tel_number_bindings_account_provisioning_status"
    t.index ["account_id"], name: "index_telephony_number_bindings_on_account_id"
    t.index ["inbox_id"], name: "index_telephony_number_bindings_on_inbox_id", unique: true
    t.index ["provider_connection_id"], name: "index_telephony_number_bindings_on_provider_connection_id"
  end

  create_table "telephony_provider_connections", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "provider_kind", null: false
    t.string "name", null: false
    t.string "host"
    t.integer "port"
    t.string "transport", default: "udp", null: false
    t.string "username"
    t.string "password_secret_ref"
    t.string "credentials_ref"
    t.string "fonoster_trunk_ref"
    t.string "fonoster_credentials_ref"
    t.string "fonoster_acl_ref"
    t.boolean "send_register", default: false, null: false
    t.string "status", default: "draft", null: false
    t.string "managed_by", default: "onelink", null: false
    t.string "ownership_status", default: "local", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "last_synced_at"
    t.bigint "created_by_id"
    t.bigint "updated_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "provisioning_status", default: "local_only", null: false
    t.datetime "last_reconciled_at"
    t.datetime "remote_drift_detected_at"
    t.jsonb "remote_drift_summary", default: {}, null: false
    t.index ["account_id", "fonoster_trunk_ref"], name: "idx_tel_provider_connections_account_trunk_ref", unique: true, where: "(fonoster_trunk_ref IS NOT NULL)"
    t.index ["account_id", "provider_kind", "name"], name: "idx_tel_provider_connections_account_kind_name", unique: true
    t.index ["account_id", "provisioning_status"], name: "idx_tel_provider_connections_account_provisioning_status"
    t.index ["account_id", "status"], name: "idx_tel_provider_connections_account_status"
    t.index ["account_id"], name: "index_telephony_provider_connections_on_account_id"
    t.index ["created_by_id"], name: "index_telephony_provider_connections_on_created_by_id"
    t.index ["updated_by_id"], name: "index_telephony_provider_connections_on_updated_by_id"
  end

  create_table "telephony_provisioning_runs", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "inbox_id"
    t.bigint "channel_id"
    t.bigint "number_binding_id"
    t.bigint "provider_connection_id"
    t.string "operation", null: false
    t.string "status", default: "pending", null: false
    t.boolean "remote_commit", default: false, null: false
    t.string "idempotency_key", null: false
    t.jsonb "desired_snapshot", default: {}, null: false
    t.jsonb "remote_snapshot", default: {}, null: false
    t.jsonb "planned_operations", default: [], null: false
    t.jsonb "executed_operations", default: [], null: false
    t.string "error_code"
    t.text "error_message"
    t.jsonb "error_details", default: {}, null: false
    t.bigint "requested_by_id"
    t.string "request_id"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "idempotency_key"], name: "idx_tel_provisioning_runs_account_idempotency", unique: true
    t.index ["account_id", "inbox_id", "created_at"], name: "idx_tel_provisioning_runs_account_inbox_created"
    t.index ["account_id", "status", "created_at"], name: "idx_tel_provisioning_runs_account_status_created"
    t.index ["account_id"], name: "index_telephony_provisioning_runs_on_account_id"
    t.index ["inbox_id"], name: "index_telephony_provisioning_runs_on_inbox_id"
    t.index ["number_binding_id"], name: "index_telephony_provisioning_runs_on_number_binding_id"
    t.index ["provider_connection_id"], name: "index_telephony_provisioning_runs_on_provider_connection_id"
    t.index ["requested_by_id"], name: "index_telephony_provisioning_runs_on_requested_by_id"
  end

  create_table "telephony_routing_policies", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "number_binding_id", null: false
    t.string "mode", default: "operator", null: false
    t.boolean "ai_enabled", default: false, null: false
    t.string "ai_app_ref"
    t.string "operator_agent_ref"
    t.string "operator_agent_aor"
    t.string "fallback_mode", default: "reject", null: false
    t.text "fallback_message"
    t.jsonb "business_hours", default: {}, null: false
    t.jsonb "settings", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "ai_deployment_mode", default: "onelink_managed", null: false
    t.string "fonoster_ai_app_ref"
    t.string "onelink_ai_app_ref"
    t.string "fallback_ai_app_ref"
    t.bigint "captain_assistant_id"
    t.jsonb "ai_voice_settings", default: {}, null: false
    t.index ["account_id", "ai_deployment_mode"], name: "index_telephony_routing_policies_on_account_ai_deployment"
    t.index ["account_id", "mode"], name: "index_telephony_routing_policies_on_account_mode"
    t.index ["account_id"], name: "index_telephony_routing_policies_on_account_id"
    t.index ["captain_assistant_id"], name: "index_telephony_routing_policies_on_captain_assistant_id"
    t.index ["number_binding_id"], name: "index_telephony_routing_policies_on_number_binding_id", unique: true
  end

  create_table "telephony_sip_profiles", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "inbox_id"
    t.bigint "user_id"
    t.bigint "provider_connection_id"
    t.string "internal_extension", null: false
    t.string "sip_username"
    t.string "password_secret_ref"
    t.string "sip_host"
    t.string "agent_ref"
    t.string "agent_aor"
    t.string "fonoster_agent_ref"
    t.string "credentials_ref"
    t.string "fonoster_credentials_ref"
    t.boolean "enabled", default: true, null: false
    t.string "availability_mode", default: "external_extension", null: false
    t.string "status", default: "draft", null: false
    t.string "managed_by", default: "onelink", null: false
    t.string "ownership_status", default: "local", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "last_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "sip_password"
    t.string "profile_kind", default: "human_operator", null: false
    t.index ["account_id", "agent_aor"], name: "idx_tel_sip_profiles_account_agent_aor", unique: true, where: "(agent_aor IS NOT NULL)"
    t.index ["account_id", "agent_ref"], name: "idx_tel_sip_profiles_account_agent_ref", unique: true, where: "(agent_ref IS NOT NULL)"
    t.index ["account_id", "inbox_id", "internal_extension"], name: "idx_tel_sip_profiles_account_inbox_ext", unique: true
    t.index ["account_id", "inbox_id"], name: "idx_tel_sip_profiles_one_voice_agent_per_inbox", unique: true, where: "((profile_kind)::text = 'voice_agent'::text)"
    t.index ["account_id", "provider_connection_id"], name: "idx_tel_sip_profiles_account_provider_connection"
    t.index ["account_id"], name: "index_telephony_sip_profiles_on_account_id"
    t.index ["inbox_id"], name: "index_telephony_sip_profiles_on_inbox_id"
    t.index ["provider_connection_id"], name: "index_telephony_sip_profiles_on_provider_connection_id"
    t.index ["user_id"], name: "index_telephony_sip_profiles_on_user_id"
  end

  create_table "touch_occurrence_claims", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "touch_plan_enrollment_id", null: false
    t.bigint "reminder_id"
    t.string "step_key", null: false
    t.string "occurrence_key", null: false
    t.datetime "due_at", null: false
    t.string "status", default: "claimed", null: false
    t.datetime "claimed_at", null: false
    t.datetime "materialized_at"
    t.text "last_error"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_touch_occurrence_claims_on_account_id"
    t.index ["reminder_id"], name: "idx_touch_occurrence_claims_on_unique_reminder", unique: true, where: "(reminder_id IS NOT NULL)"
    t.index ["reminder_id"], name: "index_touch_occurrence_claims_on_reminder_id"
    t.index ["status", "claimed_at"], name: "idx_touch_occurrence_claims_stale"
    t.index ["touch_plan_enrollment_id", "occurrence_key"], name: "idx_touch_occurrence_claims_on_enrollment_occurrence", unique: true
    t.index ["touch_plan_enrollment_id"], name: "index_touch_occurrence_claims_on_touch_plan_enrollment_id"
  end

  create_table "touch_plan_enrollments", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "reminder_group_id"
    t.string "remindable_type"
    t.bigint "remindable_id"
    t.string "status", default: "active", null: false
    t.jsonb "plan_snapshot", default: [], null: false
    t.string "plan_digest", null: false
    t.datetime "next_due_at"
    t.datetime "activated_at", null: false
    t.string "idempotency_key", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "automation_rule_id"
    t.string "source_action_id"
    t.index ["account_id", "automation_rule_id", "source_action_id", "remindable_type", "remindable_id"], name: "idx_touch_plan_enrollments_one_open_action", unique: true, where: "(((status)::text = ANY (ARRAY[('active'::character varying)::text, ('paused'::character varying)::text, ('completed'::character varying)::text])) AND (automation_rule_id IS NOT NULL))"
    t.index ["account_id", "idempotency_key"], name: "idx_touch_plan_enrollments_on_account_idempotency", unique: true
    t.index ["account_id", "reminder_group_id", "remindable_type", "remindable_id"], name: "idx_touch_plan_enrollments_one_open_plan", unique: true, where: "((status)::text = ANY (ARRAY[('active'::character varying)::text, ('paused'::character varying)::text]))"
    t.index ["account_id"], name: "index_touch_plan_enrollments_on_account_id"
    t.index ["automation_rule_id"], name: "index_touch_plan_enrollments_on_automation_rule_id"
    t.index ["remindable_type", "remindable_id", "status"], name: "idx_touch_plan_enrollments_on_remindable_status"
    t.index ["remindable_type", "remindable_id"], name: "index_touch_plan_enrollments_on_remindable"
    t.index ["reminder_group_id"], name: "index_touch_plan_enrollments_on_reminder_group_id"
    t.index ["status", "next_due_at"], name: "idx_touch_plan_enrollments_due"
  end

  create_table "users", id: :serial, force: :cascade do |t|
    t.string "provider", default: "email", null: false
    t.string "uid", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at", precision: nil
    t.datetime "remember_created_at", precision: nil
    t.integer "sign_in_count", default: 0, null: false
    t.datetime "current_sign_in_at", precision: nil
    t.datetime "last_sign_in_at", precision: nil
    t.string "current_sign_in_ip"
    t.string "last_sign_in_ip"
    t.string "confirmation_token"
    t.datetime "confirmed_at", precision: nil
    t.datetime "confirmation_sent_at", precision: nil
    t.string "unconfirmed_email"
    t.string "name", null: false
    t.string "display_name"
    t.string "email"
    t.json "tokens"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "pubsub_token"
    t.integer "availability", default: 0
    t.jsonb "ui_settings", default: {}
    t.jsonb "custom_attributes", default: {}
    t.string "type"
    t.text "message_signature"
    t.string "otp_secret"
    t.integer "consumed_timestep"
    t.boolean "otp_required_for_login", default: false
    t.text "otp_backup_codes"
    t.string "active_auth_client_id"
    t.datetime "active_auth_client_set_at"
    t.string "active_web_desktop_auth_client_id"
    t.datetime "active_web_desktop_auth_client_set_at"
    t.string "active_web_mobile_auth_client_id"
    t.datetime "active_web_mobile_auth_client_set_at"
    t.index ["email"], name: "index_users_on_email"
    t.index ["otp_required_for_login"], name: "index_users_on_otp_required_for_login"
    t.index ["otp_secret"], name: "index_users_on_otp_secret", unique: true
    t.index ["pubsub_token"], name: "index_users_on_pubsub_token", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["uid", "provider"], name: "index_users_on_uid_and_provider", unique: true
  end

  create_table "webhooks", force: :cascade do |t|
    t.integer "account_id"
    t.integer "inbox_id"
    t.text "url"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "webhook_type", default: 0
    t.jsonb "subscriptions", default: ["conversation_status_changed", "conversation_updated", "conversation_created", "contact_created", "contact_updated", "message_created", "message_updated", "webwidget_triggered"]
    t.string "name"
    t.string "secret"
    t.index ["account_id", "url"], name: "index_webhooks_on_account_id_and_url", unique: true
  end

  create_table "whatsapp_coexistence_contact_pending_events", force: :cascade do |t|
    t.integer "account_id", null: false
    t.bigint "channel_id", null: false
    t.string "event_key", null: false
    t.string "reason", null: false
    t.jsonb "entry", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "phone_identity"
    t.index ["account_id", "channel_id", "id"], name: "idx_wa_coex_contact_pending_account_channel"
    t.index ["account_id", "channel_id", "phone_identity", "id"], name: "idx_wa_coex_pending_phone_identity", where: "(phone_identity IS NOT NULL)"
    t.index ["account_id"], name: "idx_on_account_id_f7abdfbcb1"
    t.index ["channel_id", "event_key"], name: "idx_wa_coex_contact_pending_channel_event", unique: true
    t.index ["channel_id"], name: "idx_on_channel_id_d91985ff7a"
  end

  create_table "whatsapp_flow_sessions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "inbox_id", null: false
    t.bigint "whatsapp_flow_id", null: false
    t.bigint "conversation_id"
    t.bigint "message_id"
    t.bigint "response_message_id"
    t.string "token", null: false
    t.string "status", default: "pending", null: false
    t.jsonb "request_payload", default: {}, null: false
    t.jsonb "response_payload", default: {}, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "sent_at"
    t.datetime "submitted_at"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "inbox_id", "status"], name: "idx_whatsapp_flow_sessions_on_account_inbox_status"
    t.index ["conversation_id", "status"], name: "idx_whatsapp_flow_sessions_on_conversation_status"
    t.index ["conversation_id"], name: "index_whatsapp_flow_sessions_on_conversation_id"
    t.index ["inbox_id"], name: "index_whatsapp_flow_sessions_on_inbox_id"
    t.index ["message_id"], name: "index_whatsapp_flow_sessions_on_message_id"
    t.index ["response_message_id"], name: "index_whatsapp_flow_sessions_on_response_message_id"
    t.index ["token"], name: "index_whatsapp_flow_sessions_on_token", unique: true
    t.index ["whatsapp_flow_id"], name: "index_whatsapp_flow_sessions_on_whatsapp_flow_id"
  end

  create_table "whatsapp_flows", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "inbox_id", null: false
    t.string "provider_flow_id"
    t.string "name", null: false
    t.string "title"
    t.string "status", default: "draft", null: false
    t.string "category"
    t.string "mode"
    t.jsonb "flow_json", default: {}, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "last_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "inbox_id", "name"], name: "index_whatsapp_flows_on_account_id_and_inbox_id_and_name", unique: true
    t.index ["account_id", "inbox_id", "provider_flow_id"], name: "idx_whatsapp_flows_on_inbox_provider_flow_id", unique: true, where: "(provider_flow_id IS NOT NULL)"
    t.index ["inbox_id"], name: "index_whatsapp_flows_on_inbox_id"
  end

  create_table "whatsapp_pending_message_mutations", force: :cascade do |t|
    t.integer "account_id", null: false
    t.bigint "inbox_id", null: false
    t.string "event_id", null: false
    t.string "target_source_id", null: false
    t.string "mutation_type", null: false
    t.string "actor_id"
    t.bigint "provider_timestamp", default: 0, null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "status", default: "pending", null: false
    t.integer "attempt_count", default: 0, null: false
    t.datetime "last_attempted_at"
    t.string "terminal_reason"
    t.datetime "terminal_at"
    t.datetime "next_reconciliation_at"
    t.string "reconciliation_token"
    t.datetime "payload_scrubbed_at"
    t.index ["account_id", "inbox_id", "id"], name: "idx_wa_pending_mutations_account_inbox"
    t.index ["account_id"], name: "index_whatsapp_pending_message_mutations_on_account_id"
    t.index ["inbox_id", "event_id"], name: "idx_wa_pending_mutations_inbox_event", unique: true
    t.index ["inbox_id", "target_source_id", "provider_timestamp"], name: "idx_wa_pending_mutations_target_time"
    t.index ["inbox_id"], name: "index_whatsapp_pending_message_mutations_on_inbox_id"
    t.index ["status", "next_reconciliation_at"], name: "idx_wa_pending_mutations_reconciliation"
  end

  create_table "whatsapp_template_media_sources", force: :cascade do |t|
    t.bigint "whatsapp_channel_id", null: false
    t.string "template_name", null: false
    t.string "language", null: false
    t.integer "card_index", null: false
    t.string "media_type", null: false
    t.text "source_url"
    t.string "meta_media_id"
    t.datetime "meta_media_uploaded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["whatsapp_channel_id", "template_name", "language", "card_index"], name: "idx_wa_template_media_source_identity", unique: true
    t.index ["whatsapp_channel_id"], name: "index_whatsapp_template_media_sources_on_whatsapp_channel_id"
  end

  create_table "whatsapp_webhook_routes", force: :cascade do |t|
    t.string "waba_id", null: false
    t.string "phone_number_id", null: false
    t.string "destination", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "registration_token", limit: 36
    t.index ["waba_id", "phone_number_id", "destination"], name: "idx_whatsapp_webhook_routes_exact", unique: true
    t.index ["waba_id"], name: "idx_whatsapp_webhook_routes_waba"
    t.check_constraint "destination::text = ANY (ARRAY['dev'::character varying, 'widget'::character varying]::text[])", name: "chk_whatsapp_webhook_routes_destination"
    t.check_constraint "phone_number_id::text ~ '^[0-9]+$'::text", name: "chk_whatsapp_webhook_routes_phone_digits"
    t.check_constraint "waba_id::text ~ '^[0-9]+$'::text", name: "chk_whatsapp_webhook_routes_waba_digits"
  end

  create_table "working_hours", force: :cascade do |t|
    t.bigint "inbox_id"
    t.bigint "account_id"
    t.integer "day_of_week", null: false
    t.boolean "closed_all_day", default: false
    t.integer "open_hour"
    t.integer "open_minutes"
    t.integer "close_hour"
    t.integer "close_minutes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "open_all_day", default: false
    t.index ["account_id"], name: "index_working_hours_on_account_id"
    t.index ["inbox_id"], name: "index_working_hours_on_inbox_id"
  end

  add_foreign_key "account_user_lifecycle_snapshots", "accounts", on_delete: :cascade
  add_foreign_key "account_user_lifecycle_snapshots", "users", column: "deactivated_by_id", on_delete: :nullify
  add_foreign_key "account_user_lifecycle_snapshots", "users", on_delete: :cascade
  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "assignment_client_ownerships", "accounts", name: "fk_rails_assignment_client_ownerships_account"
  add_foreign_key "assignment_client_ownerships", "assignment_policies", name: "fk_rails_assignment_client_ownerships_policy", on_delete: :nullify
  add_foreign_key "assignment_client_ownerships", "contacts", name: "fk_rails_assignment_client_ownerships_contact", on_delete: :cascade
  add_foreign_key "assignment_client_ownerships", "users", name: "fk_rails_assignment_client_ownerships_user"
  add_foreign_key "assignment_decision_logs", "accounts", name: "fk_rails_assignment_decision_logs_account"
  add_foreign_key "assignment_decision_logs", "assignment_policies", name: "fk_rails_assignment_decision_logs_policy", on_delete: :nullify
  add_foreign_key "assignment_decision_logs", "conversations", name: "fk_rails_assignment_decision_logs_conversation"
  add_foreign_key "assignment_decision_logs", "inboxes", name: "fk_rails_assignment_decision_logs_inbox"
  add_foreign_key "assignment_decision_logs", "users", column: "assigned_user_id", name: "fk_rails_assignment_decision_logs_assigned_user", on_delete: :nullify
  add_foreign_key "assignment_quota_usages", "accounts", name: "fk_rails_assignment_quota_usages_account"
  add_foreign_key "assignment_quota_usages", "assignment_policies", name: "fk_rails_assignment_quota_usages_policy", on_delete: :nullify
  add_foreign_key "assignment_quota_usages", "contacts", name: "fk_rails_assignment_quota_usages_contact", on_delete: :cascade
  add_foreign_key "assignment_quota_usages", "conversations", name: "fk_rails_assignment_quota_usages_conversation"
  add_foreign_key "assignment_quota_usages", "users", name: "fk_rails_assignment_quota_usages_user"
  add_foreign_key "bulk_action_runs", "accounts"
  add_foreign_key "bulk_action_runs", "users"
  add_foreign_key "campaign_audience_imports", "accounts", on_delete: :cascade
  add_foreign_key "campaign_audience_imports", "inboxes", on_delete: :cascade
  add_foreign_key "campaign_audience_imports", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "campaign_audience_recipients", "accounts", on_delete: :cascade
  add_foreign_key "campaign_audience_recipients", "campaign_audience_imports", on_delete: :cascade
  add_foreign_key "campaign_audience_recipients", "contacts", on_delete: :nullify
  add_foreign_key "campaign_deliveries", "accounts"
  add_foreign_key "campaign_deliveries", "campaign_runs"
  add_foreign_key "campaign_deliveries", "campaigns"
  add_foreign_key "campaign_deliveries", "contacts"
  add_foreign_key "campaign_deliveries", "inboxes"
  add_foreign_key "campaign_runs", "accounts"
  add_foreign_key "campaign_runs", "campaigns"
  add_foreign_key "campaign_runs", "inboxes"
  add_foreign_key "campaigns", "campaign_audience_imports", on_delete: :nullify
  add_foreign_key "campaigns", "captain_assistants"
  add_foreign_key "captain_assistant_responses", "captain_document_chunks", column: "document_chunk_id", on_delete: :nullify
  add_foreign_key "captain_document_chunks", "accounts"
  add_foreign_key "captain_document_chunks", "captain_assistants", column: "assistant_id", on_delete: :nullify
  add_foreign_key "captain_document_chunks", "captain_documents", column: "document_id"
  add_foreign_key "captain_knowledge_answer_cache_entries", "accounts", on_delete: :cascade
  add_foreign_key "captain_knowledge_answer_cache_entries", "captain_assistants", column: "assistant_id", on_delete: :nullify
  add_foreign_key "captain_mcp_servers", "accounts"
  add_foreign_key "captain_skills", "accounts"
  add_foreign_key "communication_thread_conversations", "accounts"
  add_foreign_key "communication_thread_conversations", "communication_threads"
  add_foreign_key "communication_thread_conversations", "contact_inboxes"
  add_foreign_key "communication_thread_conversations", "conversations"
  add_foreign_key "communication_thread_conversations", "inboxes"
  add_foreign_key "communication_threads", "accounts"
  add_foreign_key "communication_threads", "contacts"
  add_foreign_key "communication_threads", "teams"
  add_foreign_key "communication_threads", "users", column: "assignee_id"
  add_foreign_key "confirmation_requests", "accounts"
  add_foreign_key "confirmation_requests", "contacts"
  add_foreign_key "confirmation_requests", "conversations"
  add_foreign_key "confirmation_requests", "inboxes"
  add_foreign_key "confirmation_requests", "messages", column: "delivery_message_id"
  add_foreign_key "confirmation_requests", "messages", column: "resolved_message_id"
  add_foreign_key "confirmation_requests", "reminders"
  add_foreign_key "confirmation_requests", "users", column: "requested_by_id"
  add_foreign_key "confirmation_requests", "users", column: "resolved_by_id"
  add_foreign_key "contact_channel_profiles", "accounts"
  add_foreign_key "contact_channel_profiles", "contact_inboxes"
  add_foreign_key "contact_channel_profiles", "contacts"
  add_foreign_key "contact_channel_profiles", "inboxes"
  add_foreign_key "contacts", "users", column: "owner_id"
  add_foreign_key "conversation_status_transitions", "accounts"
  add_foreign_key "conversation_status_transitions", "conversations"
  add_foreign_key "crm_comments", "accounts"
  add_foreign_key "crm_comments", "users"
  add_foreign_key "crm_deal_contacts", "accounts"
  add_foreign_key "crm_deal_contacts", "contacts"
  add_foreign_key "crm_deal_contacts", "crm_deals", column: "deal_id"
  add_foreign_key "crm_deals", "accounts"
  add_foreign_key "crm_deals", "communication_threads", column: "originating_communication_thread_id"
  add_foreign_key "crm_deals", "companies"
  add_foreign_key "crm_deals", "conversations", column: "originating_conversation_id"
  add_foreign_key "crm_deals", "crm_pipelines", column: "pipeline_id"
  add_foreign_key "crm_deals", "crm_stages", column: "stage_id"
  add_foreign_key "crm_deals", "teams"
  add_foreign_key "crm_deals", "users", column: "creator_id"
  add_foreign_key "crm_deals", "users", column: "owner_id"
  add_foreign_key "crm_events", "accounts"
  add_foreign_key "crm_events", "users", column: "actor_id"
  add_foreign_key "crm_field_definitions", "accounts"
  add_foreign_key "crm_pipelines", "accounts"
  add_foreign_key "crm_stages", "accounts"
  add_foreign_key "crm_stages", "crm_pipelines", column: "pipeline_id"
  add_foreign_key "crm_task_statuses", "accounts"
  add_foreign_key "crm_tasks", "accounts"
  add_foreign_key "crm_tasks", "conversations", column: "originating_conversation_id"
  add_foreign_key "crm_tasks", "crm_deals", column: "deal_id"
  add_foreign_key "crm_tasks", "crm_task_statuses", column: "status_id"
  add_foreign_key "crm_tasks", "teams"
  add_foreign_key "crm_tasks", "users", column: "assignee_id"
  add_foreign_key "crm_tasks", "users", column: "creator_id"
  add_foreign_key "inboxes", "portals"
  add_foreign_key "kaspi_pay_payments", "accounts"
  add_foreign_key "kaspi_pay_payments", "integrations_hooks", column: "integration_hook_id"
  add_foreign_key "lead_forms", "accounts"
  add_foreign_key "lead_forms", "inboxes"
  add_foreign_key "lead_submissions", "accounts"
  add_foreign_key "lead_submissions", "contact_inboxes"
  add_foreign_key "lead_submissions", "contacts"
  add_foreign_key "lead_submissions", "conversations"
  add_foreign_key "lead_submissions", "crm_deals"
  add_foreign_key "lead_submissions", "inboxes"
  add_foreign_key "lead_submissions", "lead_forms"
  add_foreign_key "llm_eval_runs", "accounts"
  add_foreign_key "llm_eval_runs", "users"
  add_foreign_key "llm_event_annotations", "accounts"
  add_foreign_key "llm_event_annotations", "llm_events"
  add_foreign_key "llm_event_annotations", "users"
  add_foreign_key "llm_usage_events", "llm_events", on_delete: :cascade
  add_foreign_key "medelement_provider_commands", "accounts", on_delete: :cascade
  add_foreign_key "medelement_provider_commands", "confirmation_requests", on_delete: :nullify
  add_foreign_key "medelement_provider_commands", "contacts", on_delete: :nullify
  add_foreign_key "medelement_provider_commands", "integrations_hooks", column: "hook_id", on_delete: :nullify
  add_foreign_key "medelement_provider_commands", "scheduling_appointments", column: "appointment_id", on_delete: :nullify
  add_foreign_key "medelement_provider_commands", "users", column: "requested_by_id", on_delete: :nullify
  add_foreign_key "medelement_sync_conflicts", "accounts", on_delete: :cascade
  add_foreign_key "medelement_sync_conflicts", "integrations_hooks", column: "hook_id", on_delete: :nullify
  add_foreign_key "medelement_sync_conflicts", "medelement_sync_runs", column: "first_sync_run_id", on_delete: :nullify
  add_foreign_key "medelement_sync_conflicts", "medelement_sync_runs", column: "last_sync_run_id", on_delete: :nullify
  add_foreign_key "medelement_sync_conflicts", "users", column: "resolved_by_id", on_delete: :nullify
  add_foreign_key "medelement_sync_runs", "accounts", on_delete: :cascade
  add_foreign_key "medelement_sync_runs", "integrations_hooks", column: "hook_id", on_delete: :nullify
  add_foreign_key "medelement_sync_runs", "users", column: "requested_by_id", on_delete: :nullify
  add_foreign_key "meta_ad_referrals", "accounts", on_delete: :cascade
  add_foreign_key "meta_ad_referrals", "communication_threads", on_delete: :nullify
  add_foreign_key "meta_ad_referrals", "contacts", on_delete: :nullify
  add_foreign_key "meta_ad_referrals", "conversations", on_delete: :nullify
  add_foreign_key "meta_ad_referrals", "inboxes", on_delete: :cascade
  add_foreign_key "meta_ad_referrals", "messages", on_delete: :nullify
  add_foreign_key "meta_channel_credential_healths", "accounts", on_delete: :cascade
  add_foreign_key "reminder_groups", "accounts"
  add_foreign_key "reminder_groups", "captain_assistants", column: "assistant_id"
  add_foreign_key "reminder_groups", "users", column: "creator_id"
  add_foreign_key "reminders", "accounts"
  add_foreign_key "reminders", "contact_inboxes", column: "target_contact_inbox_id"
  add_foreign_key "reminders", "contacts", column: "target_contact_id"
  add_foreign_key "reminders", "conversations"
  add_foreign_key "reminders", "conversations", column: "target_conversation_id"
  add_foreign_key "reminders", "inboxes", column: "target_inbox_id"
  add_foreign_key "reminders", "reminder_groups"
  add_foreign_key "reminders", "users", column: "creator_id"
  add_foreign_key "reminders", "users", column: "owner_id"
  add_foreign_key "scheduling_appointments", "accounts"
  add_foreign_key "scheduling_appointments", "companies"
  add_foreign_key "scheduling_appointments", "contacts"
  add_foreign_key "scheduling_appointments", "conversations"
  add_foreign_key "scheduling_appointments", "scheduling_resources", column: "resource_id"
  add_foreign_key "scheduling_appointments", "scheduling_services", column: "service_id"
  add_foreign_key "scheduling_appointments", "users", column: "created_by_id"
  add_foreign_key "scheduling_appointments", "users", column: "owner_id"
  add_foreign_key "scheduling_break_rules", "accounts"
  add_foreign_key "scheduling_break_rules", "scheduling_resources", column: "resource_id"
  add_foreign_key "scheduling_expenses", "accounts"
  add_foreign_key "scheduling_expenses", "scheduling_appointments", column: "appointment_id"
  add_foreign_key "scheduling_expenses", "scheduling_resources", column: "resource_id"
  add_foreign_key "scheduling_expenses", "users", column: "paid_by_id"
  add_foreign_key "scheduling_holidays", "accounts"
  add_foreign_key "scheduling_payments", "accounts"
  add_foreign_key "scheduling_payments", "scheduling_appointments", column: "appointment_id"
  add_foreign_key "scheduling_payments", "users", column: "recorded_by_id"
  add_foreign_key "scheduling_resources", "accounts"
  add_foreign_key "scheduling_resources", "users"
  add_foreign_key "scheduling_service_prices", "accounts"
  add_foreign_key "scheduling_service_prices", "scheduling_resources", column: "resource_id"
  add_foreign_key "scheduling_service_prices", "scheduling_services", column: "service_id"
  add_foreign_key "scheduling_services", "accounts"
  add_foreign_key "scheduling_time_offs", "accounts"
  add_foreign_key "scheduling_time_offs", "scheduling_resources", column: "resource_id"
  add_foreign_key "scheduling_work_rules", "accounts"
  add_foreign_key "scheduling_work_rules", "scheduling_resources", column: "resource_id"
  add_foreign_key "scheduling_workday_overrides", "accounts"
  add_foreign_key "scheduling_workday_overrides", "scheduling_resources", column: "resource_id"
  add_foreign_key "telegram_notification_bindings", "users"
  add_foreign_key "telephony_agent_bindings", "accounts"
  add_foreign_key "telephony_agent_bindings", "users"
  add_foreign_key "telephony_ai_voice_fish_voices", "accounts", on_delete: :cascade
  add_foreign_key "telephony_ai_voice_fish_voices", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "telephony_call_sessions", "accounts"
  add_foreign_key "telephony_call_sessions", "contacts"
  add_foreign_key "telephony_call_sessions", "conversations", on_delete: :nullify
  add_foreign_key "telephony_call_sessions", "inboxes", on_delete: :nullify
  add_foreign_key "telephony_call_sessions", "telephony_agent_bindings", column: "agent_binding_id"
  add_foreign_key "telephony_call_sessions", "telephony_number_bindings", column: "number_binding_id"
  add_foreign_key "telephony_contact_endpoints", "accounts"
  add_foreign_key "telephony_contact_endpoints", "contacts"
  add_foreign_key "telephony_contact_endpoints", "inboxes", on_delete: :nullify
  add_foreign_key "telephony_contact_endpoints", "telephony_number_bindings", column: "number_binding_id", on_delete: :nullify
  add_foreign_key "telephony_events", "accounts"
  add_foreign_key "telephony_events", "telephony_call_sessions", column: "call_session_id"
  add_foreign_key "telephony_number_bindings", "accounts"
  add_foreign_key "telephony_number_bindings", "inboxes"
  add_foreign_key "telephony_number_bindings", "telephony_provider_connections", column: "provider_connection_id"
  add_foreign_key "telephony_provider_connections", "accounts"
  add_foreign_key "telephony_provider_connections", "users", column: "created_by_id"
  add_foreign_key "telephony_provider_connections", "users", column: "updated_by_id"
  add_foreign_key "telephony_provisioning_runs", "accounts"
  add_foreign_key "telephony_provisioning_runs", "inboxes"
  add_foreign_key "telephony_provisioning_runs", "telephony_number_bindings", column: "number_binding_id"
  add_foreign_key "telephony_provisioning_runs", "telephony_provider_connections", column: "provider_connection_id"
  add_foreign_key "telephony_provisioning_runs", "users", column: "requested_by_id"
  add_foreign_key "telephony_routing_policies", "accounts"
  add_foreign_key "telephony_routing_policies", "captain_assistants"
  add_foreign_key "telephony_routing_policies", "telephony_number_bindings", column: "number_binding_id"
  add_foreign_key "telephony_sip_profiles", "accounts"
  add_foreign_key "telephony_sip_profiles", "inboxes"
  add_foreign_key "telephony_sip_profiles", "telephony_provider_connections", column: "provider_connection_id"
  add_foreign_key "telephony_sip_profiles", "users"
  add_foreign_key "touch_occurrence_claims", "accounts"
  add_foreign_key "touch_occurrence_claims", "reminders"
  add_foreign_key "touch_occurrence_claims", "touch_plan_enrollments"
  add_foreign_key "touch_plan_enrollments", "accounts"
  add_foreign_key "touch_plan_enrollments", "automation_rules"
  add_foreign_key "touch_plan_enrollments", "reminder_groups"
  add_foreign_key "whatsapp_coexistence_contact_pending_events", "accounts", on_delete: :cascade
  add_foreign_key "whatsapp_coexistence_contact_pending_events", "channel_whatsapp", column: "channel_id", on_delete: :cascade
  add_foreign_key "whatsapp_flow_sessions", "accounts"
  add_foreign_key "whatsapp_flow_sessions", "conversations"
  add_foreign_key "whatsapp_flow_sessions", "inboxes"
  add_foreign_key "whatsapp_flow_sessions", "messages"
  add_foreign_key "whatsapp_flow_sessions", "messages", column: "response_message_id"
  add_foreign_key "whatsapp_flow_sessions", "whatsapp_flows"
  add_foreign_key "whatsapp_flows", "accounts"
  add_foreign_key "whatsapp_flows", "inboxes"
  add_foreign_key "whatsapp_pending_message_mutations", "accounts", on_delete: :cascade
  add_foreign_key "whatsapp_pending_message_mutations", "inboxes", on_delete: :cascade
  add_foreign_key "whatsapp_template_media_sources", "channel_whatsapp", column: "whatsapp_channel_id", on_delete: :cascade
  # no candidate create_trigger statement could be found, creating an adapter-specific one
  execute(<<-SQL)
CREATE OR REPLACE FUNCTION public.accounts_after_insert_row_tr()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    execute format('create sequence IF NOT EXISTS conv_dpid_seq_%s', NEW.id);
    RETURN NULL;
END;
$function$
  SQL

  # no candidate create_trigger statement could be found, creating an adapter-specific one
  execute("CREATE TRIGGER accounts_after_insert_row_tr AFTER INSERT ON \"accounts\" FOR EACH ROW EXECUTE FUNCTION accounts_after_insert_row_tr()")

  # no candidate create_trigger statement could be found, creating an adapter-specific one
  execute(<<-SQL)
CREATE OR REPLACE FUNCTION public.camp_dpid_before_insert()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    execute format('create sequence IF NOT EXISTS camp_dpid_seq_%s', NEW.id);
    RETURN NULL;
END;
$function$
  SQL

  # no candidate create_trigger statement could be found, creating an adapter-specific one
  execute("CREATE TRIGGER camp_dpid_before_insert AFTER INSERT ON \"accounts\" FOR EACH ROW EXECUTE FUNCTION camp_dpid_before_insert()")

  # no candidate create_trigger statement could be found, creating an adapter-specific one
  execute(<<-SQL)
CREATE OR REPLACE FUNCTION public.campaigns_before_insert_row_tr()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    NEW.display_id := nextval('camp_dpid_seq_' || NEW.account_id);
    RETURN NEW;
END;
$function$
  SQL

  # no candidate create_trigger statement could be found, creating an adapter-specific one
  execute("CREATE TRIGGER campaigns_before_insert_row_tr BEFORE INSERT ON \"campaigns\" FOR EACH ROW EXECUTE FUNCTION campaigns_before_insert_row_tr()")

  # no candidate create_trigger statement could be found, creating an adapter-specific one
  execute(<<-SQL)
CREATE OR REPLACE FUNCTION public.conversations_before_insert_row_tr()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    NEW.display_id := nextval('conv_dpid_seq_' || NEW.account_id);
    RETURN NEW;
END;
$function$
  SQL

  # no candidate create_trigger statement could be found, creating an adapter-specific one
  execute("CREATE TRIGGER conversations_before_insert_row_tr BEFORE INSERT ON \"conversations\" FOR EACH ROW EXECUTE FUNCTION conversations_before_insert_row_tr()")

end
