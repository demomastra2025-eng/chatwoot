require 'rails_helper'

RSpec.describe 'Captain tool schema metadata' do
  it 'keeps create_touch public and assistant schemas aligned across relative, absolute, and recurring scheduling' do
    public_params = Captain::Tools::CreateTouchTool.parameters
    assistant_params = Captain::Tools::Copilot::CreateTouchService.parameters

    expected_create_touch_description =
      'Create a delayed outbound touch with free text, attachments, or an approved official WhatsApp channel template. ' \
      'Supports relative scheduling (relative_offset_minutes + optional relative_anchor) and absolute scheduling (scheduled_at as ISO8601). ' \
      'Recurrence (repeat_mode daily/weekly/monthly/weekdays) is available only with absolute scheduled_at and requires repeat_until_at. ' \
      'For a fixed wall-clock time on relative touches use relative_time_mode=fixed_time_of_day with relative_time_of_day HH:MM. ' \
      'For official WhatsApp outside the 24-hour window, use channel_template instead of free_text or AI-generated text.'
    expected_relative_anchor_description =
      'Optional relative anchor: touch.created_at, conversation.created_at, ' \
      'conversation.last_incoming_message_at, conversation.last_activity_at, ' \
      'conversation.last_outgoing_message_at, conversation.waiting_since, ' \
      'deal.expected_close_on, task.due_at, appointment.starts_at, appointment.ends_at. ' \
      'Defaults to conversation.last_incoming_message_at for conversation touches, ' \
      'falling back to touch.created_at when no incoming customer message exists.'
    expected_auto_cancel_description =
      'Set true only when a customer reply in the same conversation should cancel this scheduled touch; ' \
      'set false when the touch must remain scheduled'

    expect(Captain::Tools::CreateTouchTool.description).to eq(expected_create_touch_description)
    expect(Captain::Tools::Copilot::CreateTouchService.description).to eq(expected_create_touch_description)
    expect(public_params[:relative_anchor].description).to eq(expected_relative_anchor_description)
    expect(assistant_params[:relative_anchor].description).to eq(expected_relative_anchor_description)
    expect(public_params[:auto_cancel_on_incoming].description).to eq(expected_auto_cancel_description)
    expect(assistant_params[:auto_cancel_on_incoming].description).to eq(expected_auto_cancel_description)
    expect(public_params[:target_inbox_id].description).to include('ID')
    expect(assistant_params[:target_inbox_id].description).to include('ID')
    expect(public_params[:attachment_ids].type).to eq('array')
    expect(assistant_params[:attachment_ids].type).to eq(:array)
    expect(public_params[:artifact_ids].type).to eq('array')
    expect(assistant_params[:artifact_ids].type).to eq(:array)
    expect(public_params.keys).to match_array(assistant_params.keys)
    expect(public_params[:scheduled_at].required).to be(false)
    expect(assistant_params[:scheduled_at].required).to be(false)
    expect(public_params).not_to have_key(:timing_mode)
    expect(assistant_params).not_to have_key(:timing_mode)
    expect(public_params[:relative_offset_minutes].required).to be(false)
    expect(assistant_params[:relative_offset_minutes].required).to be(false)
    expect(public_params[:relative_offset_minutes].description).to include('Positive')
    expect(assistant_params[:relative_offset_minutes].description).to include('Positive')
    expect(public_params[:repeat_mode].description).to include('daily, weekly, monthly, weekdays')
    expect(assistant_params[:repeat_mode].description).to include('daily, weekly, monthly, weekdays')
    expect(public_params[:repeat_mode].description).to include('require both absolute scheduled_at and repeat_until_at')
    expect(assistant_params[:repeat_mode].description).to include('require both absolute scheduled_at and repeat_until_at')
    expect(public_params[:relative_time_mode].description).to include('fixed_time_of_day')
    expect(assistant_params[:relative_time_mode].description).to include('fixed_time_of_day')
    expect(public_params[:content_kind].required).to be(false)
    expect(assistant_params[:content_kind].required).to be(false)
    expect(public_params[:template_params].required).to be(false)
    expect(assistant_params[:template_params].required).to be(false)
  end

  it 'documents explicit enum-like values for high-risk or filter-heavy tools' do
    create_task_public = Captain::Tools::CreateTaskTool.parameters
    create_task_assistant = Captain::Tools::Copilot::CreateTaskService.parameters
    update_task_public = Captain::Tools::UpdateTaskTool.parameters
    update_task_assistant = Captain::Tools::Copilot::UpdateTaskService.parameters
    search_tasks = Captain::Tools::Copilot::SearchTasksService.parameters
    search_appointments = Captain::Tools::Copilot::SearchAppointmentsService.parameters
    update_contact = Captain::Tools::Copilot::UpdateContactService.parameters
    search_resources = Captain::Tools::Copilot::SearchSchedulingResourcesService.parameters

    expect(create_task_public[:priority].description).to eq('Task priority: low, medium, high, or urgent')
    expect(create_task_assistant[:priority].description).to eq('Task priority: low, medium, high, or urgent')
    expect(create_task_public[:activity_type].description).to eq('Task type: task, call, meeting, message, or touch')
    expect(create_task_assistant[:activity_type].description).to eq('Task type: task, call, meeting, message, or touch')
    expect(create_task_public[:outcome_note].description).to eq('Task result details: what was done or why it was not done')
    expect(create_task_assistant[:outcome_note].description).to eq('Task result details: what was done or why it was not done')
    expect(update_task_public[:priority].description).to eq('Updated task priority: low, medium, high, or urgent')
    expect(update_task_assistant[:priority].description).to eq('Updated task priority: low, medium, high, or urgent')
    expect(update_task_public[:activity_type].description).to eq('Updated task type: task, call, meeting, message, or touch')
    expect(update_task_assistant[:activity_type].description).to eq('Updated task type: task, call, meeting, message, or touch')
    expect(update_task_public[:outcome_note].description).to eq('Updated task result details: what was done or why it was not done')
    expect(update_task_assistant[:outcome_note].description).to eq('Updated task result details: what was done or why it was not done')
    expect(search_tasks[:activity_type].description).to eq('Task type: task, call, meeting, message, or touch')
    expect(search_tasks[:priority].description).to eq('Task priority: low, medium, high, or urgent')
    expect(search_appointments[:status].description).to eq('Appointment status: scheduled, confirmed, completed, cancelled, or no_show')
    expect(search_appointments[:payment_status].description).to eq('Payment status: awaiting_payment, prepaid, paid, or cancelled')
    expect(update_contact[:phone_number].description).to include('E.164')
    expect(search_resources[:search_by].description).to eq('Search mode: name, specialty, or all')
  end

  it 'exposes CRM custom_attributes as JSON strings so models can pass dynamic CRM field keys' do
    tool_pairs = [
      [Captain::Tools::CreateDealTool, Captain::Tools::Copilot::CreateDealService],
      [Captain::Tools::UpdateDealTool, Captain::Tools::Copilot::UpdateDealService],
      [Captain::Tools::CreateTaskTool, Captain::Tools::Copilot::CreateTaskService],
      [Captain::Tools::UpdateTaskTool, Captain::Tools::Copilot::UpdateTaskService]
    ]

    tool_pairs.each do |public_tool, assistant_tool|
      expect(public_tool.parameters[:custom_attributes].type).to eq('string')
      expect(assistant_tool.parameters[:custom_attributes].type).to eq(:string)
      custom_attributes_schema = public_tool.new(Captain::Assistant.new).params_schema.dig(
        'properties', 'custom_attributes'
      )
      expect(custom_attributes_schema['type']).to eq('string')
    end
  end

  it 'exposes scheduling appointment custom_attributes as native objects' do
    tool_pairs = [
      [Captain::Tools::CreateAppointmentTool, Captain::Tools::Copilot::CreateAppointmentService],
      [Captain::Tools::UpdateAppointmentTool, Captain::Tools::Copilot::UpdateAppointmentService]
    ]

    tool_pairs.each do |public_tool, assistant_tool|
      expect(public_tool.parameters[:custom_attributes].type).to eq('object')
      expect(assistant_tool.parameters[:custom_attributes].type).to eq(:object)
      custom_attributes_schema = public_tool.new(Captain::Assistant.new).params_schema.dig(
        'properties', 'custom_attributes'
      )
      expect(custom_attributes_schema['type']).to eq('object')
    end
  end

  it 'keeps registry descriptions aligned with runtime descriptions for representative built-in tools' do
    expect(Captain::ToolRegistry.definition_for('create_touch').description).to eq(
      Captain::Tools::CreateTouchTool.description
    )
    expect(Captain::ToolRegistry.definition_for('search_appointments').description).to eq(
      Captain::Tools::Copilot::SearchAppointmentsService.description
    )
    expect(Captain::ToolRegistry.definition_for('search_scheduling_resources').description).to eq(
      Captain::Tools::Copilot::SearchSchedulingResourcesService.description
    )
    expect(Captain::ToolRegistry.definition_for('resolve_conversation').description).to eq(
      Captain::Tools::ResolveConversationTool.description
    )
  end

  it 'exposes optional reason parameters for resolve and handoff in both scopes' do
    resolve_public = Captain::Tools::ResolveConversationTool.parameters
    resolve_assistant = Captain::Tools::Copilot::ResolveConversationService.parameters
    handoff_public = Captain::Tools::HandoffTool.parameters
    handoff_assistant = Captain::Tools::Copilot::HandoffService.parameters

    expect(resolve_public[:reason].required).to be(false)
    expect(resolve_assistant[:reason].required).to be(false)
    expect(resolve_public[:status_reason].required).to be(false)
    expect(resolve_assistant[:status_reason].required).to be(false)
    expect(resolve_public[:reason].description).to eq('Optional reason for resolving the conversation')
    expect(resolve_assistant[:reason].description).to eq('Optional reason for resolving the conversation')
    expect(resolve_public[:status_reason].description).to include('Configured conversation status reason')
    expect(resolve_assistant[:status_reason].description).to include('Configured conversation status reason')
    expect(handoff_public[:reason].description).to eq('Optional handoff reason for the human team')
    expect(handoff_assistant[:reason].description).to eq('Optional handoff reason for the human team')
    expect(handoff_public[:status_reason].description).to include('Configured conversation status reason')
    expect(handoff_assistant[:status_reason].description).to include('Configured conversation status reason')
  end
end
