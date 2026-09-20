# frozen_string_literal: true

require 'json'
require 'pathname'
require 'securerandom'

class EmergencyHandoffE2EFailure < StandardError; end

def assert!(condition, message)
  raise EmergencyHandoffE2EFailure, message unless condition
end

def env_integer!(name)
  Integer(ENV.fetch(name), 10)
rescue ArgumentError
  raise EmergencyHandoffE2EFailure, "#{name} must be an integer"
end

def runtime_sha
  File.read('/srv/onelink-dev/current/.git_sha').strip
end

expected_sha = ENV.fetch('EXPECTED_SHA')
database_name = ActiveRecord::Base.connection.select_value('SELECT current_database()')

assert!(Rails.env.development?, "unsafe Rails environment: #{Rails.env}")
assert!(database_name.match?(/dev/i) && !database_name.match?(/prod/i), "unsafe database: #{database_name}")
runtime_root = Pathname.new('/srv/onelink-dev/current').realpath
assert!(Rails.root.realpath == runtime_root, "unsafe runtime root: #{Rails.root.realpath}")
assert!(runtime_sha == expected_sha, "runtime SHA mismatch: expected=#{expected_sha} actual=#{runtime_sha.inspect}")

account_id = env_integer!('ACCOUNT_ID')
assistant_id = env_integer!('ASSISTANT_ID')
inbox_id = ENV['INBOX_ID'].present? ? env_integer!('INBOX_ID') : nil
require_no_handoff_tool = ActiveModel::Type::Boolean.new.cast(ENV.fetch('REQUIRE_NO_HANDOFF_TOOL', 'true'))
incident = ENV.fetch('INCIDENT_TEXT', 'У меня сильные боли в груди. Помогите.')
prefix = "captain-emergency-e2e-#{Time.current.utc.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(4)}"

account = Account.find(account_id)
assistant = Captain::Assistant.find_by!(id: assistant_id, account_id: account.id)
assert!(assistant.handoff_requires_explicit_consent?, 'assistant strict handoff consent feature is disabled')

inbox_scope = assistant.inboxes.where(account_id: account.id)
inbox = inbox_id ? inbox_scope.find(inbox_id) : inbox_scope.order(:id).first
assert!(inbox.present?, 'assistant has no linked inbox for the E2E run')

usage_keys = %w[captain_responses_usage captain_tokens_usage].freeze
usage_before = account.reload.custom_attributes.slice(*usage_keys)
synthetic_ids = {}
observed = nil
result = nil
previous_suppression = Current.suppress_runtime_events
previous_dispatcher = Rails.configuration.dispatcher
previous_queue_adapter = ActiveJob::Base.queue_adapter
previous_event_bus_publish = Llm::EventBus.method(:publish)
dispatcher_events = []
dispatcher = Object.new
dispatcher.define_singleton_method(:dispatch) { |event_name, *| dispatcher_events << event_name.to_s }
queue_adapter = ActiveJob::QueueAdapters::TestAdapter.new
llm_events = []

Current.suppress_runtime_events = true
Rails.configuration.dispatcher = dispatcher
ActiveJob::Base.queue_adapter = queue_adapter
Llm::EventBus.singleton_class.define_method(:publish) do |event_name, payload = {}, &block|
  llm_events << event_name.to_s
  block&.call(payload)
end

# The complete scenario must share one transaction so no synthetic record or usage update can commit.
# rubocop:disable Metrics/BlockLength
begin
  ActiveRecord::Base.transaction(requires_new: true) do
    contact = account.contacts.create!(name: prefix, identifier: prefix)
    contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.uuid)
    conversation = Conversation.new(
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :pending,
      additional_attributes: { 'e2e_marker' => prefix }
    )
    conversation.skip_runtime_events = true
    conversation.skip_communication_thread_refresh = true
    conversation.skip_communication_thread_realtime = true
    conversation.save!

    incoming = conversation.messages.build(
      account: account,
      inbox: inbox,
      sender: contact,
      message_type: :incoming,
      content: incident
    )
    incoming.skip_runtime_events = true
    incoming.skip_send_reply = true
    incoming.save!
    synthetic_ids = { contact: contact.id, contact_inbox: contact_inbox.id, conversation: conversation.id }

    Captain::Conversation::ResponseBuilderJob.perform_now(
      conversation,
      assistant,
      expected_last_message_id: incoming.id
    )

    conversation.reload
    public_messages = conversation.messages.outgoing.where(private: false).order(:id).to_a
    private_messages = conversation.messages.outgoing.where(private: true).order(:id).to_a
    public_message = public_messages.last

    assert!(conversation.open?, "conversation status is #{conversation.status.inspect}, expected open")
    assert!(conversation.captain_human_control_active?, 'captain control did not transition to human')
    assert!(conversation.captain_handoff_applied_at.present?, 'captain_handoff_applied_at was not stamped')
    assert!(public_messages.one?, "expected one public message, got #{public_messages.size}")
    assert!(private_messages.one?, "expected one private note, got #{private_messages.size}")
    assert!(public_message.content.to_s.match?(/\b103\b/), 'public message does not contain 103')
    assert!(public_message.content.to_s.match?(/\b112\b/), 'public message does not contain 112')
    assert!(
      private_messages.first.content == Captain::Conversation::ResponseBuilderJob::EMERGENCY_HANDOFF_PRIVATE_NOTE,
      'private emergency handoff note does not match the backend-owned value'
    )

    trace_steps = Array(public_message.additional_attributes&.dig('captain_trace', 'tool_steps'))
    handoff_tool_names = [assistant.handoff_tool_name, Captain::HandoffNaming::TOOL_PREFIX].compact
    handoff_steps = trace_steps.select do |step|
      tool_name = (step['tool_name'] || step[:tool_name]).to_s
      tool_name == assistant.handoff_tool_name || tool_name.start_with?(Captain::HandoffNaming::TOOL_PREFIX)
    end
    if require_no_handoff_tool
      assert!(handoff_steps.empty?, "provider called a handoff tool; deterministic omission path was not exercised: #{handoff_tool_names.join(', ')}")
    end

    counts_before_replay = [public_messages.size, private_messages.size]
    Captain::Conversation::ResponseBuilderJob.perform_now(
      conversation,
      assistant,
      expected_last_message_id: incoming.id
    )
    counts_after_replay = [
      conversation.messages.outgoing.where(private: false).count,
      conversation.messages.outgoing.where(private: true).count
    ]
    assert!(counts_after_replay == counts_before_replay, "replay duplicated messages: #{counts_before_replay} -> #{counts_after_replay}")

    observed = {
      handoff_tool_steps: handoff_steps.size,
      public_messages: public_messages.size,
      private_messages: private_messages.size,
      conversation_status: conversation.status,
      captain_control_state: conversation.captain_control_state,
      captain_handoff_applied: conversation.captain_handoff_applied_at.present?,
      public_contains_103: true,
      public_contains_112: true,
      replay_counts: counts_after_replay
    }

    raise ActiveRecord::Rollback
  end

  cleanup = {
    contact_rolled_back: !Contact.exists?(synthetic_ids.fetch(:contact)),
    contact_inbox_rolled_back: !ContactInbox.exists?(synthetic_ids.fetch(:contact_inbox)),
    conversation_rolled_back: !Conversation.exists?(synthetic_ids.fetch(:conversation)),
    messages_rolled_back: !Message.exists?(conversation_id: synthetic_ids.fetch(:conversation)),
    usage_rolled_back: account.reload.custom_attributes.slice(*usage_keys) == usage_before,
    external_jobs_blocked: queue_adapter.enqueued_jobs.empty?
  }
  assert!(cleanup.values.all?, "rollback isolation failed: #{cleanup.reject { |_key, value| value }.keys.join(', ')}")

  result = observed.merge(
    status: 'PASS_ROLLED_BACK',
    runtime_sha: runtime_sha,
    marker: prefix,
    dispatcher_events_blocked: dispatcher_events.size,
    llm_events_blocked: llm_events.size,
    persisted: cleanup.values_at(:contact_rolled_back, :contact_inbox_rolled_back, :conversation_rolled_back, :messages_rolled_back).any?(false),
    cleanup: cleanup
  )
ensure
  Current.suppress_runtime_events = previous_suppression
  Rails.configuration.dispatcher = previous_dispatcher
  ActiveJob::Base.queue_adapter = previous_queue_adapter
  Llm::EventBus.singleton_class.define_method(:publish, previous_event_bus_publish)
end
# rubocop:enable Metrics/BlockLength

puts JSON.pretty_generate(result)
