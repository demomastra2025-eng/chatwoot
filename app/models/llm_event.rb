# == Schema Information
#
# Table name: llm_events
#
#  id                      :bigint           not null, primary key
#  blocked                 :boolean          default(FALSE), not null
#  channel_type            :string
#  completion_tokens       :integer
#  credit_multiplier       :integer
#  current_agent           :string
#  duration_ms             :integer
#  error                   :boolean          default(FALSE), not null
#  error_code              :string
#  estimated_cost          :decimal(12, 8)
#  event_name              :string           not null
#  feature                 :string
#  model                   :string
#  moderation_skipped      :boolean          default(FALSE), not null
#  payload                 :jsonb            not null
#  payload_bytes           :integer
#  payload_truncated       :boolean          default(FALSE), not null
#  prompt_tokens           :integer
#  provider                :string
#  queue_wait_ms           :integer
#  reason                  :string
#  retry_count             :integer
#  runtime_mode            :string
#  schema_invalid          :boolean          default(FALSE), not null
#  schema_invalid_count    :integer
#  schema_name             :string
#  source                  :string
#  status                  :string
#  thinking_tokens         :integer
#  tool_calls_count        :integer
#  tool_failure            :boolean          default(FALSE), not null
#  tool_name               :string
#  total_tokens            :integer
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  account_id              :integer
#  assistant_id            :bigint
#  conversation_display_id :integer
#  conversation_id         :bigint
#  copilot_thread_id       :bigint
#  project_case_id         :string
#  request_id              :string
#  session_id              :string
#  trace_id                :string
#
# Indexes
#
#  index_llm_events_on_account_created_at               (account_id,created_at)
#  index_llm_events_on_account_error_code_created_at    (account_id,error_code,created_at) WHERE (error_code IS NOT NULL)
#  index_llm_events_on_account_feature_created_at       (account_id,feature,created_at)
#  index_llm_events_on_account_model_created_at         (account_id,model,created_at)
#  index_llm_events_on_account_project_case_created_at  (account_id,project_case_id,created_at) WHERE (project_case_id IS NOT NULL)
#  index_llm_events_on_account_request_created_at       (account_id,request_id,created_at) WHERE (request_id IS NOT NULL)
#  index_llm_events_on_account_session_created_at       (account_id,session_id,created_at) WHERE (session_id IS NOT NULL)
#  index_llm_events_on_account_trace_created_at         (account_id,trace_id,created_at) WHERE (trace_id IS NOT NULL)
#  index_llm_events_on_assistant_created_at             (assistant_id,created_at)
#  index_llm_events_on_conversation_created_at          (conversation_id,created_at)
#  index_llm_events_on_event_name_created_at            (event_name,created_at)
#

class LlmEvent < ApplicationRecord
  EVENT_FLAGS = {
    'blocked' => :blocked,
    'error' => :error,
    'moderation_skipped' => :moderation_skipped,
    'schema_invalid' => :schema_invalid,
    'tool_failure' => :tool_failure
  }.freeze

  belongs_to :account, optional: true
  belongs_to :conversation, optional: true
  has_many :annotations, class_name: 'LlmEventAnnotation', dependent: :destroy_async

  validates :event_name, presence: true

  scope :for_account, ->(account_id) { where(account_id: account_id) if account_id.present? }
  scope :for_feature, ->(feature) { where(feature: feature) if feature.present? }
  scope :for_model, ->(model) { where(model: model) if model.present? }
  scope :for_event_name, ->(event_name) { where(event_name: event_name) if event_name.present? }
  scope :for_runtime_mode, ->(runtime_mode) { where(runtime_mode: runtime_mode) if runtime_mode.present? }
  scope :for_status, ->(status) { where(status: status) if status.present? }
  scope :for_request_id, ->(request_id) { where(request_id: request_id) if request_id.present? }
  scope :for_trace_id, ->(trace_id) { where(trace_id: trace_id) if trace_id.present? }
  scope :for_session_id, ->(session_id) { where(session_id: session_id) if session_id.present? }
  scope :for_project_case, ->(project_case_id) { where(project_case_id: project_case_id) if project_case_id.present? }
  scope :for_error_code, ->(error_code) { where(error_code: error_code) if error_code.present? }
  scope :for_assistant, ->(assistant_id) { where(assistant_id: assistant_id) if assistant_id.present? }
  scope :for_conversation, ->(conversation_id) { where(conversation_id: conversation_id) if conversation_id.present? }
  scope :for_conversation_display_id, lambda { |conversation_display_id|
    where(conversation_display_id: conversation_display_id) if conversation_display_id.present?
  }
  scope :for_copilot_thread, ->(copilot_thread_id) { where(copilot_thread_id: copilot_thread_id) if copilot_thread_id.present? }
  scope :for_tool_name, ->(tool_name) { where(tool_name: tool_name) if tool_name.present? }
  scope :for_schema_name, ->(schema_name) { where(schema_name: schema_name) if schema_name.present? }
  scope :for_date_range, ->(range) { where(created_at: range) if range.present? }
  scope :chat_completions, -> { where(event_name: 'llm.chat.complete') }
  scope :blocked_events, -> { where(blocked: true) }
  scope :error_events, -> { where(error: true) }
  scope :moderation_skipped_events, -> { where(moderation_skipped: true) }
  scope :schema_invalid_events, -> { where(schema_invalid: true) }
  scope :tool_failure_events, -> { where(tool_failure: true) }
  scope :for_flag, lambda { |flag|
    column_name = EVENT_FLAGS[flag.to_s]
    column_name.present? ? where(column_name => true) : all
  }
end
