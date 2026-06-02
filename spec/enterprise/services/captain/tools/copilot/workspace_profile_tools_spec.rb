# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Captain workspace profile copilot tools' do
  let(:account) do
    create(:account).tap do |record|
      record.update!(
        name: 'Old Company',
        locale: source_locale,
        domain: 'reply.old.example.com',
        support_email: 'support.old@example.com',
        custom_attributes: {
          'industry' => 'Retail',
          'company_size' => '11-50',
          'timezone' => 'Asia/Almaty'
        },
        settings: record.settings.merge(
          'reporting_timezone' => 'Asia/Almaty',
          'auto_resolve_after' => 30,
          'auto_resolve_message' => 'We resolved this conversation.',
          'auto_resolve_ignore_waiting' => false,
          'auto_resolve_label' => 'done',
          'scheduling_contact_required' => true,
          'scheduling_company_enabled' => true,
          'mcp_access' => {
            'enabled' => true,
            'sources' => {
              'captain' => true,
              'openapi_read' => true,
              'openapi_write' => false
            },
            'max_risk_level' => 'low',
            'require_confirmation_for_mutations' => true
          }
        )
      )
    end
  end
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:admin) { create(:user, :administrator, account: account) }
  let(:source_locale) { Account.locales.key?('en') ? 'en' : Account.locales.keys.first }
  let(:target_locale) { Account.locales.key?('ru') ? 'ru' : Account.locales.keys.second || Account.locales.keys.first }

  before do
    confirmation_gate = instance_double(Captain::Copilot::ToolConfirmationGate, call: nil)
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_return(confirmation_gate)
  end

  describe Captain::Tools::Copilot::GetWorkspaceProfileService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'returns safe editable workspace profile metadata for account administrators' do
      create(:inbox, account: account)
      create(:team, account: account)

      payload = JSON.parse(service.execute)

      expect(payload['action']).to eq('get_workspace_profile')
      expect(payload['workspace']).to include(
        'id' => account.id,
        'name' => 'Old Company',
        'locale' => source_locale,
        'domain' => 'reply.old.example.com',
        'support_email' => 'support.old@example.com',
        'configured_support_email' => 'support.old@example.com',
        'status' => 'active'
      )
      expect(payload.dig('workspace', 'custom_attributes')).to include(
        'industry' => 'Retail',
        'company_size' => '11-50',
        'timezone' => 'Asia/Almaty'
      )
      expect(payload.dig('workspace', 'settings')).to include(
        'reporting_timezone' => 'Asia/Almaty',
        'auto_resolve_after' => 30,
        'scheduling_company_enabled' => true
      )
      expect(payload.dig('workspace', 'available_locales')).to include(source_locale)
      expect(payload.dig('workspace', 'counts')).to include('users' => 1, 'teams' => 1, 'inboxes' => 1)
      expect(payload.dig('editable_fields', 'account')).to include('name', 'locale', 'domain', 'support_email')
    end

    it 'returns a compact MCP access summary inside the workspace profile' do
      payload = JSON.parse(service.execute)

      expect(payload.dig('workspace', 'mcp_access')).to include(
        'enabled' => true,
        'max_risk_level' => 'low',
        'require_confirmation_for_mutations' => true
      )
      expect(payload.dig('workspace', 'mcp_access', 'sources')).to include(
        'captain' => true,
        'openapi_read' => true,
        'openapi_write' => false
      )
    end

    it 'rejects direct non-admin execution as defense in depth' do
      agent = create(:user, account: account)

      result = described_class.new(assistant, user: agent).execute

      expect(result).to include('Account administrator permission is required')
    end
  end

  describe Captain::Tools::Copilot::UpdateWorkspaceProfileService do
    let(:service) { described_class.new(assistant, user: admin) }
    let(:appointment_touch_plan) { create(:reminder_group, account: account, entity_kinds: ['appointment']) }
    let(:workspace_update_params) do
      {
        name: 'New Company',
        locale: target_locale,
        domain: '',
        support_email: 'support.new@example.com',
        industry: 'Services',
        company_size: '51-200',
        timezone: 'Asia/Almaty',
        reporting_timezone: 'Asia/Almaty',
        auto_resolve_after: 60,
        auto_resolve_message: 'Resolved by policy.',
        auto_resolve_ignore_waiting: true,
        auto_resolve_label: '',
        scheduling_contact_required: false,
        scheduling_company_enabled: false,
        default_appointment_touch_plan_id: appointment_touch_plan.id
      }
    end

    it 'updates safe workspace profile fields and account settings' do
      payload = JSON.parse(service.execute(**workspace_update_params))

      account.reload
      expect(payload['action']).to eq('update_workspace_profile')
      expect(payload['workspace']).to include(
        'id' => account.id,
        'name' => 'New Company',
        'locale' => target_locale,
        'domain' => '',
        'configured_support_email' => 'support.new@example.com'
      )
      expect(payload['updated_fields']).to include(
        'account.name',
        'account.locale',
        'account.domain',
        'account.support_email',
        'custom_attributes.industry',
        'settings.auto_resolve_after',
        'settings.scheduling_company_enabled',
        'settings.default_appointment_touch_plan_id'
      )
      expect(account).to have_attributes(name: 'New Company', locale: target_locale, domain: '', support_email: 'support.new@example.com')
      expect(account.custom_attributes).to include('industry' => 'Services', 'company_size' => '51-200', 'timezone' => 'Asia/Almaty')
      expect(account.settings).to include(
        'reporting_timezone' => 'Asia/Almaty',
        'auto_resolve_after' => 60,
        'auto_resolve_message' => 'Resolved by policy.',
        'auto_resolve_ignore_waiting' => true,
        'auto_resolve_label' => '',
        'scheduling_contact_required' => false,
        'scheduling_company_enabled' => false,
        'default_appointment_touch_plan_id' => appointment_touch_plan.id
      )
    end

    it 'rejects invalid locale without mutating the account' do
      result = service.execute(locale: 'not-a-locale')

      expect(result).to include('locale must be one of:')
      expect(account.reload.locale).to eq(source_locale)
    end

    it 'rejects unsupported fields instead of silently ignoring them' do
      result = service.execute(unknown_setting: 'surprise')

      expect(result).to include('Unsupported workspace profile fields: unknown_setting')
      expect(account.reload.name).to eq('Old Company')
    end

    it 'rejects default touch-plan IDs outside the current account' do
      other_plan = create(:reminder_group, account: create(:account), entity_kinds: ['appointment'])

      result = service.execute(default_appointment_touch_plan_id: other_plan.id)

      expect(result).to include("Couldn't find ReminderGroup")
      expect(account.reload.settings['default_appointment_touch_plan_id']).to be_blank
    end

    it 'rejects default touch-plan IDs for an incompatible entity kind' do
      deal_plan = create(:reminder_group, account: account, entity_kinds: ['deal'])

      result = service.execute(default_appointment_touch_plan_id: deal_plan.id)

      expect(result).to include('default_appointment_touch_plan_id must reference a touch plan that supports appointment')
      expect(account.reload.settings['default_appointment_touch_plan_id']).to be_blank
    end

    it 'rejects direct non-admin execution as defense in depth' do
      agent = create(:user, account: account)

      result = described_class.new(assistant, user: agent).execute(name: 'Blocked Company')

      expect(result).to include('Account administrator permission is required')
      expect(account.reload.name).to eq('Old Company')
    end

    it 'does not mutate until the backend confirmation gate permits execution' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original

      payload = JSON.parse(service.execute(name: 'Needs Approval'))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(payload.dig('data', 'confirmation_required')).to be(true)
      expect(account.reload.name).to eq('Old Company')
    end
  end

  describe 'registry exposure' do
    it 'exposes workspace profile tools only to the operator assistant scope' do
      get_definition = Captain::ToolRegistry.definition_for('get_workspace_profile')
      update_definition = Captain::ToolRegistry.definition_for('update_workspace_profile')
      tool_ids = %w[get_workspace_profile update_workspace_profile]

      expect(get_definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
      expect(get_definition.to_h).to include(risk_level: 'low', idempotent: true, selected_by_default: false)
      expect(update_definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
      expect(update_definition.to_h).to include(risk_level: 'high', requires_confirmation: true, selected_by_default: false)
      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)).not_to include(*tool_ids)
      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)).to include(*tool_ids)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
