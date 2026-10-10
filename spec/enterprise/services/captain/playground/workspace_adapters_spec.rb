require 'rails_helper'

RSpec.describe Captain::Playground::ToolExecutor, 'native rules through the production tool wrapper' do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:session) { Captain::Playground::Session.new(account: account, user: user, assistant: assistant) }

  before do
    account.enable_features!('crm_tasks', 'crm_deals', 'scheduling')
    allow(assistant).to receive(:allowed_agent_tool_ids).and_return(
      described_class::HANDLERS.keys + Captain::Playground::ToolSupport::CUSTOM_FIELD_TOOLS
    )
    allow(Captain::ToolSafety).to receive(:check_arguments!)
    allow(Captain::ToolSafety).to receive(:check_result!)
  end

  after { Current.reset }

  def wrapped(workspace, id)
    definition = Captain::ToolRegistry.definition_for(id)
    tool = if definition.agent_tool_class == Captain::Tools::Agent::AccountToolAdapter
             definition.agent_tool_class.new(assistant, tool_id: id)
           else
             definition.agent_tool_class.new(assistant)
           end
    context = Captain::Runtime::RunContext.new({
      state: workspace.state.merge(source: 'playground', account_id: account.id, assistant_id: assistant.id),
      playground_session: workspace
    })
    Captain::Runtime::ToolWrapper.new(tool, context)
  end

  def call(workspace, id, **arguments)
    wrapped(workspace, id).call(arguments)
  end

  def result(workspace, id, **arguments)
    value = call(workspace, id, **arguments)
    expect(value).not_to start_with('ERROR:')
    JSON.parse(value)
  end

  def handle(workspace, key, value)
    workspace.namespace.encode({ key => value }).fetch(key)
  end

  def business_counts
    [Contact, Conversation, Message, Notification, Reminder, Crm::Task, Crm::Deal, Scheduling::Appointment,
     Integrations::Medelement::ProviderCommand].map(&:count)
  end

  it 'gives every customer tool an explicit adapter or external-service refusal and removes only the customer provider-status tool' do
    definitions = Captain::ToolRegistry.definitions.select { |definition| definition.supports_scope?(Captain::ToolAccess::SCOPE_AGENT) }
    unsupported = definitions.select { |definition| Captain::Playground::ToolSupport.for_tool(definition.id) == 'blocked_no_adapter' }
    expect(unsupported.map(&:id)).to eq([])
    expect(definitions.select { |definition| definition.to_h[:playground_support] == 'blocked_external_service' }.map(&:id))
      .to match_array(Captain::Playground::ToolSupport::EXTERNAL_TOOLS)
    expect(definitions.map(&:id)).not_to include('get_appointment_provider_status')
    expect(Captain::ToolRegistry.definition_for('get_appointment_provider_status').assistant_tool_class).to be_present
  end

  it 'assigns synthetic staff and sends only JSON notifications with native selector/type validation and atomic errors' do
    assistant
    user
    baseline = business_counts
    expect(Notification).not_to receive(:create!)
    expect(account).not_to receive(:users)
    session.with_lock do |workspace|
      data = workspace.scenario.data
      data['staff'] = [{ 'id' => 1801, 'name' => 'Scenario operator', 'email' => 'operator@example.test', 'type' => 'User' }]
      conversation_id = handle(workspace, :conversation_id, data['conversation']['id'])
      staff_id = handle(workspace, :assignee_id, 1801)
      assigned = result(workspace, 'assign_conversation', conversation_id: conversation_id, assignee_id: staff_id, assignee_type: 'User')
      expect(assigned.dig('conversation', 'assignee_id')).to eq(staff_id)
      expect(assigned.dig('conversation', 'assignee_type')).to eq('User')
      original = data.deep_dup
      operation = Captain::Tools::Operations::NotificationOperations.new(assistant: assistant)
      expect { operation.send(:find_recipient!, recipient_id: 1801, recipient_email: 'operator@example.test', recipient_name: nil) }
        .to raise_error(ArgumentError, 'Exactly one recipient selector is required')
      expect(call(workspace, 'send_notification', message: 'Ready', recipient_id: handle(workspace, :recipient_id, 1801),
                  recipient_email: 'operator@example.test')).to include('Exactly one recipient selector is required')
      expect(data).to eq(original)
      notification = result(workspace, 'send_notification', message: '  Scenario only  ', recipient_email: 'OPERATOR@EXAMPLE.TEST')
      expect(notification).to include('simulated' => true, 'delivered' => false)
      expect(notification.dig('notification', 'message')).to eq('Scenario only')
      expect(notification.dig('notification', 'recipient', 'id')).to be_negative
      workspace.set_permissions!(read: true, write: true)
      expect(result(workspace, 'send_notification', conversation_id: conversation_id, message: 'Still JSON',
                    recipient_id: handle(workspace, :recipient_id, 1801))).to include('simulated' => true, 'delivered' => false)
      expect(data['notifications'].size).to eq(2)
    end
    expect(business_counts).to eq(baseline)
  end

  it 'uses the real channel template catalog and reply-window policy without delivering or creating messages' do
    assistant
    baseline = business_counts
    expect(Messages::MessageBuilder).not_to receive(:new)
    expect(SendReplyJob).not_to receive(:perform_later)
    session.with_lock do |workspace|
      data = workspace.scenario.data
      data['inbox'] = { 'channel_type' => 'Channel::Whatsapp', 'channel' => { 'provider' => 'whatsapp_cloud' } }
      data['channel_templates'] = [{ 'id' => 1801, 'name' => 'visit_ready', 'language' => 'ru', 'status' => 'APPROVED',
        'category' => 'UTILITY', 'components' => [{ 'type' => 'BODY', 'text' => 'Your visit is ready.' }] }]
      id = handle(workspace, :conversation_id, data['conversation']['id'])
      templates = result(workspace, 'list_channel_templates', name: 'visit_ready')
      expect(templates).to include('supports_channel_templates' => true, 'total_count' => 1)
      expect(templates['templates'].first).to include('name' => 'visit_ready', 'status' => 'approved', 'supported' => true)
      expect(call(workspace, 'send_message_to_conversation', conversation_id: id, content: 'Outside the window'))
        .to include(Outbound::DeliveryPolicy::WHATSAPP_TEMPLATE_REQUIRED_REASON)
      expect(data['messages']).to be_empty
      sent = result(workspace, 'send_message_to_conversation', conversation_id: id, content_kind: 'channel_template',
                    template_params: { name: 'visit_ready', language: 'ru' })
      expect(sent).to include('delivered' => false, 'simulated' => true)
      expect(sent.dig('message', 'template_params')).to include('name' => 'visit_ready')
      expect(sent['message_id']).to be_negative
      expect(data['messages'].size).to eq(1)
    end
    expect(business_counts).to eq(baseline)
  end

  it 'creates, reads through the native payload, cancels and deletes a synthetic touch with read/write ON and zero jobs' do
    assistant
    baseline = business_counts
    expect(Reminders::CreateService).not_to receive(:new)
    expect(SendReplyJob).not_to receive(:perform_later)
    session.with_lock do |workspace|
      workspace.set_permissions!(read: true, write: true)
      scheduled = 2.days.from_now.change(usec: 0).iso8601
      created = result(workspace, 'create_touch', body: 'Scenario reminder', scheduled_at: scheduled, timezone: 'Asia/Almaty')
      expect(created).to include('simulated' => true, 'delivered' => false, 'status' => 'pending', 'timing_mode' => 'absolute')
      id = created['touch_id']
      expect(id).to be_negative
      expect(created.dig('touch', 'body')).to eq('Scenario reminder')
      expect(Time.iso8601(created['scheduled_at'])).to eq(Time.iso8601(scheduled))
      expect(created.dig('touch', 'target', 'contact', 'name')).to eq('Айгуль Садыкова')
      duplicate = result(workspace, 'create_touch', body: 'Scenario reminder', scheduled_at: scheduled, timezone: 'Asia/Almaty')
      expect(duplicate['touch_id']).to eq(id)
      cancelled = result(workspace, 'cancel_touch', touch_id: id, reason: 'Scenario stopped')
      expect(cancelled).to include('status' => 'cancelled', 'reason' => 'Scenario stopped')
      expect(result(workspace, 'delete_touch', touch_id: id)).to include('deleted' => true, 'touch_id' => id)
      expect(workspace.scenario.data['touches']).to be_empty
    end
    expect(business_counts).to eq(baseline)
  end

  it 'rejects native invalid touch content and recurrence and materializes relative fixed wall-clock time from JSON' do
    travel_to(Time.utc(2026, 10, 10, 10)) do
      session.with_lock do |workspace|
        operation = Captain::Tools::Operations::TouchOperations.new(assistant: assistant)
        expect { operation.send(:validate_touch_content!, body: '', content_kind: 'free_text', template_params: {}, attachments_present: false) }
          .to raise_error(ArgumentError) { |error| expect(call(workspace, 'create_touch', body: '', relative_offset_minutes: 30)).to include(error.message) }
        expect(call(workspace, 'create_touch', body: 'Test', repeat_mode: 'daily', relative_offset_minutes: 30))
          .to include('recurring touches require absolute scheduled_at')
        workspace.scenario.data['messages'] << { 'id' => 1801, 'message_type' => 'incoming', 'private' => false, 'created_at' => Time.current.iso8601 }
        created = result(workspace, 'create_touch', body: 'Tomorrow at nine', relative_offset_minutes: 1440,
          relative_anchor: 'conversation.last_incoming_message_at', relative_time_mode: 'fixed_time_of_day',
          relative_time_of_day: '09:00', timezone: 'Asia/Almaty')
        expect(created).to include('timing_mode' => 'relative', 'relative_offset_seconds' => 86_400, 'relative_time_of_day' => '09:00')
        expect(Time.iso8601(created['scheduled_at'])).to eq(Time.find_zone!('Asia/Almaty').local(2026, 10, 11, 9))
        expect(workspace.scenario.data['touches'].size).to eq(1)
      end
    end
  end

  it 'uses native bulk-cancellation eligibility and cancels matching JSON enrollments without disturbing materialized delivery' do
    session.with_lock do |workspace|
      first = result(workspace, 'create_touch', body: 'First', scheduled_at: 2.days.from_now.iso8601)
      result(workspace, 'create_touch', body: 'Already sent', scheduled_at: 3.days.from_now.iso8601)
      data = workspace.scenario.data
      data['touches'].first.merge!('status' => 'processing', 'processing_started_at' => Time.current.iso8601)
      data['touches'].last.merge!('status' => 'processing', 'metadata' => { Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY => 1801 })
      data['touch_plan_enrollments'] = [{ 'id' => 1901, 'remindable_type' => 'Conversation',
        'remindable_id' => data['conversation']['id'], 'status' => 'active' }]
      payload = result(workspace, 'cancel_touches')
      expect(payload).to include('cancelled_count' => 1, 'skipped_count' => 1, 'cancelled_enrollment_count' => 1, 'remaining_open_count' => 1)
      expect(payload['cancelled_touch_ids']).to eq([first['touch_id']])
      expect(payload['skipped_touches'].first['reason']).to eq('delivery_already_materialized')
      expect(data['touches'].first['processing_started_at']).to be_nil
      expect(data['touch_plan_enrollments'].first['status']).to eq('cancelled')
    end
  end

  it 'applies native message-edit validation and retries only failed outgoing JSON messages without sending' do
    assistant
    baseline = business_counts
    expect(SendReplyJob).not_to receive(:perform_later)
    expect(Channel::Telegram).not_to receive(:find)
    session.with_lock do |workspace|
      data = workspace.scenario.data
      data['inbox'] = { 'channel_type' => 'Channel::Telegram' }
      data['messages'] = [{ 'id' => 1801, 'content' => 'Original', 'message_type' => 'outgoing', 'private' => false,
        'source_id' => 'synthetic-message', 'status' => 'failed', 'content_attributes' => {} }]
      id = handle(workspace, :message_id, 1801)
      expect(result(workspace, 'edit_message', message_id: id, content: '  Corrected  ').dig('message', 'content')).to eq('Corrected')
      expect(result(workspace, 'retry_failed_message', message_id: id)).to include('delivered' => false, 'simulated' => true)
      expect(call(workspace, 'retry_failed_message', message_id: id)).to include('Only failed messages can be retried')
      data['messages'].first['message_type'] = 'incoming'
      expect(call(workspace, 'edit_message', message_id: id, content: 'Denied')).to include('Only outgoing messages can be edited')
      expect(data['messages'].first['content']).to eq('Corrected')
    end
    expect(business_counts).to eq(baseline)
  end

  it 'creates tasks with native context/status payloads and reads exact negative IDs without a live task catalog' do
    assistant
    baseline = business_counts
    expect(Crm::TaskCatalogs::Provisioner).not_to receive(:new)
    expect(account).not_to receive(:crm_task_types)
    session.with_lock do |workspace|
      first = result(workspace, 'create_task', title: '  Scenario task  ', due_at: 2.days.from_now.iso8601)
      expect(first['task_id']).to be_negative
      expect(first.dig('task', 'title')).to eq('Scenario task')
      expect(first.dig('task', 'context_kind')).to eq('personal')
      workspace.set_permissions!(read: true, write: true)
      expect(result(workspace, 'get_task', task_id: first['task_id']).dig('task', 'title')).to eq('Scenario task')
      expect(result(workspace, 'update_task', task_id: first['task_id'], title: 'Updated scenario').dig('task', 'title')).to eq('Updated scenario')
      timeline = result(workspace, 'get_task_timeline', task_id: first['task_id'])
      expect(timeline['items'].map { |item| item['event_type'] }).to include('create_task', 'update_task')
      expect(call(workspace, 'update_task', task_id: first['task_id'], priority: 'urgent', outcome: 'not_done'))
        .to include('Outcome note')
      expect(workspace.scenario.data['tasks'].first['outcome']).to be_nil
      original = workspace.scenario.data.deep_dup
      unsupported_argument = call(workspace, 'create_task', title: 'All-day task without a date', all_day: true)
      expect(Captain::ToolResult.error?(unsupported_argument)).to be(true)
      expect(unsupported_argument).to include('Invalid tool arguments at /all_day')
      expect(workspace.scenario.data).to eq(original)

      # The customer tool does not expose all_day. Scenario snapshots can still
      # contain it, and a supported update must obey the native due_on validator.
      workspace.scenario.data['tasks'].first.merge!('all_day' => true, 'due_on' => nil, 'due_at' => nil, 'start_at' => nil)
      original = workspace.scenario.data.deep_dup
      missing_due = call(workspace, 'update_task', task_id: first['task_id'], title: 'All-day task without a date')
      expect(Captain::ToolResult.error?(missing_due)).to be(true)
      expect(missing_due).to include(Crm::Task.human_attribute_name(:due_on))
      expect(workspace.scenario.data).to eq(original)
    end
    expect(business_counts).to eq(baseline)
  end

  it 'enforces configured production pipeline movement rules before mutating a synthetic deal' do
    session.with_lock do |workspace|
      data = workspace.scenario.data
      data['pipelines'].first['restrict_stage_skipping'] = true
      id = handle(workspace, :deal_id, data['deals'].first['id'])
      original = data['deals'].first.deep_dup
      expect(call(workspace, 'update_deal', deal_id: id, stage_id: handle(workspace, :stage_id, data['stages'].last['id'])))
        .to include('This stage transition is restricted')
      expect(data['deals'].first).to eq(original)
      moved = result(workspace, 'update_deal', deal_id: id, stage_id: handle(workspace, :stage_id, data['stages'][1]['id']))
      expect(moved.dig('deal', 'stage_id')).to eq(handle(workspace, :stage_id, data['stages'][1]['id']))
    end
  end
end
