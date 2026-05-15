require 'rails_helper'

RSpec.describe 'Captain assistant ops tool registry' do
  it 'registers assistant-only operational tools' do
    assistant_tool_ids = Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)

    expect(assistant_tool_ids).to include(
      'send_message_to_conversation',
      'assign_conversation',
      'retry_failed_message',
      'edit_message',
      'translate_message',
      'search_canned_responses',
      'create_canned_response',
      'create_contact',
      'complete_task',
      'merge_contacts',
      'list_account_users',
      'list_teams',
      'list_inboxes',
      'list_assignment_policies',
      'set_inbox_assignment_policy',
      'get_inbox_settings',
      'update_inbox_settings',
      'update_inbox_working_hours',
      'add_inbox_members',
      'remove_inbox_members',
      'update_captain_inbox_auto_reply_mode',
      'add_appointment_payment',
      'execute_macro',
      'get_account_health',
      'get_recent_account_errors',
      'get_tool_execution_log',
      'trace_ai_response',
      'trace_message_delivery',
      'get_channel_health',
      'get_whatsapp_web_diagnostics',
      'reconnect_whatsapp_web',
      'create_label',
      'update_label',
      'remove_label_from_conversation',
      'list_campaigns',
      'preview_campaign',
      'get_campaign_analytics',
      'retry_failed_campaign_deliveries',
      'create_webhook',
      'update_webhook'
    )
  end
end
