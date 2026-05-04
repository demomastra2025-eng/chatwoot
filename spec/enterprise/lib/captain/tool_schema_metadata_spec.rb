require 'rails_helper'

RSpec.describe 'Captain tool schema metadata' do
  it 'keeps create_touch public and assistant schemas aligned on relative scheduling fields' do
    public_params = Captain::Tools::CreateTouchTool.parameters
    assistant_params = Captain::Tools::Copilot::CreateTouchService.parameters

    expected_create_touch_description =
      'Create a scheduled outbound touch with free text, attachments, or an approved official WhatsApp channel template. ' \
      'For official WhatsApp outside the 24-hour window, use channel_template instead of free_text or AI-generated text.'
    expected_relative_anchor_description = 'Optional relative anchor: touch.created_at, conversation.created_at, deal.expected_close_on, task.due_at, appointment.starts_at, appointment.ends_at'

    expect(Captain::Tools::CreateTouchTool.description).to eq(expected_create_touch_description)
    expect(Captain::Tools::Copilot::CreateTouchService.description).to eq(expected_create_touch_description)
    expect(public_params[:relative_anchor].description).to eq(expected_relative_anchor_description)
    expect(assistant_params[:relative_anchor].description).to eq(expected_relative_anchor_description)
    expect(public_params[:target_inbox_id].description).to include('ID')
    expect(assistant_params[:target_inbox_id].description).to include('ID')
    expect(public_params[:attachment_ids].type).to eq('array')
    expect(assistant_params[:attachment_ids].type).to eq(:array)
    expect(public_params[:artifact_ids].type).to eq('array')
    expect(assistant_params[:artifact_ids].type).to eq(:array)
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
    expect(update_task_public[:priority].description).to eq('Updated task priority: low, medium, high, or urgent')
    expect(update_task_assistant[:priority].description).to eq('Updated task priority: low, medium, high, or urgent')
    expect(search_tasks[:priority].description).to eq('Task priority: low, medium, high, or urgent')
    expect(search_appointments[:status].description).to eq('Appointment status: scheduled, confirmed, completed, cancelled, or no_show')
    expect(search_appointments[:payment_status].description).to eq('Payment status: awaiting_payment, prepaid, paid, or cancelled')
    expect(update_contact[:phone_number].description).to include('E.164')
    expect(search_resources[:search_by].description).to eq('Search mode: name, specialty, or all')
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
    expect(resolve_public[:reason].description).to eq('Optional reason for resolving the conversation')
    expect(resolve_assistant[:reason].description).to eq('Optional reason for resolving the conversation')
    expect(handoff_public[:reason].description).to eq('Optional handoff reason for the human team')
    expect(handoff_assistant[:reason].description).to eq('Optional handoff reason for the human team')
  end
end
