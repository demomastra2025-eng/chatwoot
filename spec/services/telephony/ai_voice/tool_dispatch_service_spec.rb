require 'rails_helper'

RSpec.describe Telephony::AiVoice::ToolDispatchService do
  describe '.catalog' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    it 'does not advertise native Voice tools without a Captain assistant' do
      expect(described_class.catalog).to be_empty
      expect(described_class::VOICE_TOOL_CATALOG.pluck(:name)).to include('end_call', 'request_transfer')
    end

    it 'never discovers MCP tools even when a server is configured' do
      allow(Captain::Mcp::ToolCatalog).to receive(:with_runtime_cache).and_call_original
      allow(Captain::Mcp::ToolCatalog).to receive(:without_discovery).and_call_original
      allow(described_class).to receive(:captain_tool_catalog).and_return([{ 'name' => 'get_contact' }])
      expect(described_class.catalog(captain_assistant: assistant).pluck('name')).to eq(['get_contact'])
      expect(Captain::Mcp::ToolCatalog).not_to have_received(:with_runtime_cache)
      expect(Captain::Mcp::ToolCatalog).to have_received(:without_discovery).once
    end

    it 'coalesces concurrent catalog builds for the same assistant' do
      allow(described_class).to receive(:captain_tool_catalog) do
        sleep 0.05
        [{ 'name' => 'get_contact' }]
      end
      results = Array.new(4) do
        Thread.new { described_class.catalog(captain_assistant: assistant).pluck('name') }
      end.map(&:value)
      expect(results).to all(eq(['get_contact']))
      expect(described_class).to have_received(:captain_tool_catalog).once
    end

    it 'filters forged or stale prompt-selected tools before serializing provider schema' do
      allow(assistant).to receive(:voice_runtime_agent_tools).and_return(
        [{ id: 'get_contact' }, { id: 'handoff' }, { id: 'create_deal' }, { id: 'faq_lookup' },
         { id: 'mcp__unsafe' }, { id: 'update_contact' }]
      )
      expect(assistant).not_to receive(:available_assistant_tools)

      catalog = described_class.catalog(captain_assistant: assistant).index_by { |tool| tool.fetch('name') }
      expect(catalog.keys).to match_array(%w[get_contact update_contact])
      expect(described_class.customer_captain_tool_definitions(assistant).pluck(:id)).to match_array(%w[get_contact update_contact])
      expect(catalog.dig('get_contact', 'parameters', 'properties')).to have_key('contact_id')
      expect(catalog.dig('update_contact', 'parameters', 'properties')).to include('name', 'email', 'custom_attributes')
      expect(catalog.dig('update_contact', 'parameters', 'properties')).not_to have_key('identifier')
    end

    it 'advertises selected current-contact and customer-task tools only' do
      assistant.update!(config: assistant.config.deep_merge(
        'tool_access' => { 'agent' => { 'enabled' => true,
                                        'tool_ids' => %w[get_contact update_contact customer_tasks create_task] } }
      ))
      expect(described_class.catalog(captain_assistant: assistant).pluck('name'))
        .to match_array(%w[get_contact update_contact customer_tasks])
    end
  end

  describe '#ensure_voice_crm_source!' do
    let(:account) { create(:account) }
    let(:conversation) { create(:conversation, account: account) }
    let(:provider) { 'asterisk_analog' }
    let(:call_ref) { 'asterisk_analog:test-call' }
    let!(:call_session) do
      create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        provider: provider,
        external_call_ref: call_ref
      )
    end

    def source_guard_service(title)
      described_class.new(
        tool_name: 'create_deal',
        payload: {
          account_id: account.id,
          call_ref: call_session.external_call_ref,
          arguments: { title: title }
        }
      )
    end

    it 'rejects an unrelated messaging source on a phone call' do
      expect { source_guard_service('Лид из Telegram: клиент').send(:ensure_voice_crm_source!) }
        .to raise_error(Telephony::Error) { |error| expect(error.code).to eq('VOICE_CRM_SOURCE_MISMATCH') }
    end

    it 'allows a source-neutral deal title on a phone call' do
      expect(source_guard_service('Входящий телефонный звонок').send(:ensure_voice_crm_source!)).to be_nil
    end

    context 'when the call uses WhatsApp voice' do
      let(:provider) { 'whatsapp_cloud' }
      let(:call_ref) { 'whatsapp:test-call' }

      it 'allows the matching WhatsApp source' do
        expect(source_guard_service('Лид из WhatsApp: клиент').send(:ensure_voice_crm_source!)).to be_nil
      end
    end
  end

  describe '#captain_tool_result_envelope' do
    subject(:service) { described_class.new(tool_name: 'update_deal', payload: {}) }

    it 'keeps successful Captain output backward compatible' do
      expect(service.send(:captain_tool_result_envelope, '{"action":"update_deal"}')).to eq(
        action: 'captain_tool',
        tool_name: 'update_deal',
        result: '{"action":"update_deal"}'
      )
    end

    it 'promotes Captain error strings to a typed non-retryable business failure' do
      result = service.send(
        :captain_tool_result_envelope,
        Captain::ToolResult.failure_output(error: ArgumentError.new('target is ambiguous'), retryable: false)
      )

      expect(result).to include(
        status: 'failed',
        error: 'captain_tool_business_failed',
        code: 'CAPTAIN_TOOL_BUSINESS_FAILED',
        retryable: false,
        message: a_string_including('target is ambiguous')
      )
    end
  end

  describe 'selected deal context' do
    let(:account) { create(:account) }
    let(:contact) { create(:contact, account: account) }
    let(:conversation) { create(:conversation, account: account, contact: contact) }
    let!(:call_session) do
      create(
        :telephony_call_session,
        account: account,
        contact: contact,
        conversation: conversation,
        inbox: conversation.inbox,
        external_call_ref: 'selected-deal-context'
      )
    end
    let(:deal) { create(:crm_deal, account: account) }

    def selected_deal_service(tool_name)
      described_class.new(
        tool_name: tool_name,
        payload: {
          account_id: account.id,
          call_ref: call_session.external_call_ref,
          arguments: {}
        }
      )
    end

    it 'persists one unambiguous search result with call and tenant scope' do
      result = JSON.generate(total_count: 1, deals: [{ id: deal.id, title: deal.title }])

      service = selected_deal_service('search_deals')
      attempt = service.send(:begin_selected_deal_attempt!)
      service.send(:finalize_selected_deal_attempt!, attempt, result)

      expect(call_session.reload.metadata['captain_selected_deal']).to include(
        'deal_id' => deal.id,
        'account_id' => account.id,
        'conversation_id' => conversation.id,
        'contact_id' => contact.id,
        'source_tool' => 'search_deals',
        'selected_at' => be_present
      )
    end

    it 'invalidates an older selection when a newer search is ambiguous' do
      call_session.update!(metadata: { 'captain_selected_deal' => { 'deal_id' => deal.id } })
      result = JSON.generate(total_count: 2, deals: [{ id: deal.id }, { id: deal.id + 1 }])

      service = selected_deal_service('search_deals')
      attempt = service.send(:begin_selected_deal_attempt!)
      service.send(:finalize_selected_deal_attempt!, attempt, result)

      expect(call_session.reload.metadata).not_to have_key('captain_selected_deal')
    end

    it 'invalidates an older selection when a newer selection attempt fails' do
      call_session.update!(metadata: { 'captain_selected_deal' => { 'deal_id' => deal.id } })
      service = selected_deal_service('search_deals')
      attempt = service.send(:begin_selected_deal_attempt!)

      expect(call_session.reload.metadata).not_to have_key('captain_selected_deal')
      service.send(:finalize_selected_deal_attempt!, attempt, nil)
      expect(call_session.reload.metadata).not_to have_key('captain_selected_deal')
    end

    it 'rejects a disabled deal tool before construction without modifying the previous selection' do
      call_session.update!(metadata: { 'captain_selected_deal' => { 'deal_id' => deal.id } })
      service = selected_deal_service('search_deals')
      allow(service).to receive(:ensure_voice_crm_source!)
      allow(service).to receive(:captain_tool_definition).and_return({})
      allow(Captain::ToolCatalog).to receive(:build_tool).and_return(nil)

      expect(service.send(:perform_captain_tool))
        .to include(status: 'failed', result: a_string_including('customer AI'))
      expect(Captain::ToolCatalog).not_to have_received(:build_tool)
      expect(call_session.reload.metadata['captain_selected_deal']).to eq('deal_id' => deal.id)
    end

    it 'does not let an older late result overwrite a newer ambiguous attempt' do
      service = selected_deal_service('search_deals')
      older_attempt = service.send(:begin_selected_deal_attempt!)
      newer_attempt = service.send(:begin_selected_deal_attempt!)
      successful_result = JSON.generate(total_count: 1, deals: [{ id: deal.id }])

      service.send(:finalize_selected_deal_attempt!, newer_attempt, JSON.generate(total_count: 0, deals: []))
      service.send(:finalize_selected_deal_attempt!, older_attempt, successful_result)

      expect(call_session.reload.metadata).not_to have_key('captain_selected_deal')
    end

    it 'does not create a selection from a parseable failed payload' do
      service = selected_deal_service('get_deal')
      attempt = service.send(:begin_selected_deal_attempt!)
      failed_result = JSON.generate(status: 'failed', error: 'not_found', deal: { id: deal.id })

      service.send(:finalize_selected_deal_attempt!, attempt, failed_result)

      expect(call_session.reload.metadata).not_to have_key('captain_selected_deal')
    end

    it 'atomically claims the one-use selection before an update' do
      call_session.update!(metadata: { 'captain_selected_deal' => { 'deal_id' => deal.id } })

      first_claim = selected_deal_service('update_deal').send(:claim_selected_deal_context!)
      second_claim = selected_deal_service('update_deal').send(:claim_selected_deal_context!)

      expect(first_claim).to eq('deal_id' => deal.id)
      expect(second_claim).to be_nil
      expect(call_session.reload.metadata).not_to have_key('captain_selected_deal')
    end
  end

  describe '#captain_tool_arguments' do
    let(:account) { create(:account) }
    let(:conversation) { create(:conversation, account: account) }
    let!(:call_session) do
      create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        provider: 'asterisk_analog',
        external_call_ref: 'asterisk_analog:phone-guard'
      )
    end

    def phone_guard_service(arguments)
      described_class.new(
        tool_name: 'add_contact_note',
        payload: { account_id: account.id, call_ref: call_session.external_call_ref, arguments: arguments }
      )
    end

    it 'rejects an incomplete phone number even when confirmation is asserted' do
      service = phone_guard_service(content: 'Телефон клиента: +7 708 34', voice_caller_confirmed: true)

      expect { service.send(:captain_tool_arguments) }
        .to raise_error(Telephony::Error) { |error| expect(error.code).to eq('VOICE_CRM_PHONE_INCOMPLETE') }
    end

    it 'requires explicit caller confirmation for a complete phone number' do
      service = phone_guard_service(content: 'Телефон клиента: +7 708 123 45 67')

      expect { service.send(:captain_tool_arguments) }
        .to raise_error(Telephony::Error) { |error| expect(error.code).to eq('VOICE_CRM_PHONE_CONFIRMATION_REQUIRED') }
    end

    it 'passes only native tool arguments after a complete confirmed number' do
      service = phone_guard_service(content: 'Телефон клиента: +7 708 123 45 67', voice_caller_confirmed: true)

      expect(service.send(:captain_tool_arguments)).to eq(content: 'Телефон клиента: +7 708 123 45 67')
    end
  end

  describe '#captain_runtime_state' do
    let(:account) { create(:account, captain_runtime: { 'assistant_thinking_effort' => 'low' }) }
    let(:whatsapp_channel) do
      create(
        :channel_whatsapp,
        account: account,
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
    end
    let(:inbox) { whatsapp_channel.inbox }
    let(:conversation) { create(:conversation, account: account, inbox: inbox) }
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:call_session) do
      create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        inbox: inbox,
        number_binding: nil,
        external_call_ref: 'whatsapp:wacid-test-call'
      )
    end

    before do
      create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    end

    it 'holds the shared assignment fence while yielding the current assistant' do
      service = described_class.new(
        tool_name: 'faq_lookup',
        payload: { account_id: account.id, call_ref: call_session.external_call_ref, arguments: {} }
      )

      expect(Telephony::AiVoice::AssistantAssignmentLock).to receive(:with_lock!).with(inbox.id).and_call_original

      service.with_captain_assistant_assignment_lock do |assistant_id|
        expect(assistant_id).to eq(assistant.id)
      end
    end

    it 'uses lightweight runtime preferences instead of full captain preferences for Captain tools' do
      service = described_class.new(
        tool_name: 'faq_lookup',
        payload: {
          account_id: account.id,
          call_ref: call_session.external_call_ref,
          arguments: {}
        }
      )
      resolved_account = service.send(:account)

      expect(resolved_account).not_to receive(:captain_preferences)
      expect(resolved_account).to receive(:captain_runtime_preferences).and_call_original

      state = service.send(:captain_runtime_state)

      expect(state[:captain_runtime]['assistant_thinking_effort']).to eq('low')
    end

    it 'does not build unrelated conversation prompt context for realtime FAQ lookup' do
      service = described_class.new(
        tool_name: 'faq_lookup',
        payload: {
          account_id: account.id,
          call_ref: call_session.external_call_ref,
          arguments: {}
        }
      )

      expect(Captain::ContextFields).not_to receive(:runtime_state_for)
      expect(assistant).not_to receive(:prompt_context_state)

      state = service.send(:captain_runtime_state)

      expect(state).to include(account_id: account.id, assistant_id: assistant.id, source: 'voice_ai')
      expect(state[:conversation]).to include(id: conversation.id, display_id: conversation.display_id)
      expect(state).not_to have_key(:prompt_context)
    end
  end

  describe '#with_captain_assistant_assignment_lock' do
    let(:account) { create(:account) }
    let(:inbox) { create(:inbox, account: account) }
    let(:conversation) { create(:conversation, account: account, inbox: inbox) }
    let(:call_session) do
      create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        inbox: inbox,
        number_binding: nil,
        external_call_ref: 'asterisk_analog:assignment-snapshot'
      )
    end

    it 'keeps a missing assignment stable after the lock is released' do
      service = described_class.new(
        tool_name: 'create_note',
        payload: { account_id: account.id, call_ref: call_session.external_call_ref, arguments: {} }
      )

      service.with_captain_assistant_assignment_lock do |assistant_id|
        expect(assistant_id).to be_nil
      end
      assistant = create(:captain_assistant, account: account)
      create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
      assignment_inbox = service.send(:assignment_inbox)
      assignment_inbox.association(:captain_inbox).reset
      assignment_inbox.association(:captain_assistant).reset

      expect(service.captain_assistant_id).to be_nil
    end
  end

  # Transport handler behavior remains testable; public #perform denies this AI tool.
  describe '#perform_end_call transport handler' do
    let(:account) { create(:account) }
    let(:provider) { double('provider', terminate_call: true) }
    let(:media_client) { instance_double(Whatsapp::MediaServerClient, terminate_session: true) }
    let(:whatsapp_call) do
      create(
        :call,
        account: account,
        status: 'in_progress',
        provider_call_id: 'wacid.IhggMDBENkUxMUQ3QTNGMzZGMjE0QjVBMTA0QUYwNzM0MjUcGAs3NzA4MDA4NzQyMRUCABUIAA==',
        media_session_id: 'sess_20260520062333_1'
      )
    end
    let(:call_session) do
      create(
        :telephony_call_session,
        account: account,
        conversation: whatsapp_call.conversation,
        inbox: whatsapp_call.inbox,
        contact: whatsapp_call.contact,
        number_binding: nil,
        provider: 'whatsapp_cloud',
        external_call_ref: "whatsapp:#{whatsapp_call.provider_call_id}",
        status: 'in_progress',
        metadata: {
          'ai_voice' => {
            'transport' => 'whatsapp_cloud',
            'media_session_id' => whatsapp_call.media_session_id
          },
          'whatsapp_cloud' => {
            'provider_call_id' => whatsapp_call.provider_call_id
          }
        }
      )
    end

    before do
      allow_any_instance_of(Channel::Whatsapp).to receive(:provider_service).and_return(provider)
      allow(Whatsapp::MediaServerClient).to receive(:new).and_return(media_client)
      allow(ActionCable.server).to receive(:broadcast)
    end

    it 'terminates the WhatsApp provider call and media-server session, not just local UI state' do
      result = described_class.new(
        tool_name: 'end_call',
        payload: {
          account_id: account.id,
          call_ref: call_session.external_call_ref,
          arguments: {
            ended_by: 'user',
            reason: 'user requested to end the call'
          }
        }
      ).send(:perform_end_call)

      expect(result).to include(action: 'end_call', status: 'completed', transport_terminate_requested: true)
      expect(provider).to have_received(:terminate_call).with(whatsapp_call.provider_call_id).once
      expect(media_client).to have_received(:terminate_session).with(whatsapp_call.media_session_id).once
      expect(call_session.reload).to have_attributes(
        status: 'completed',
        ended_by: 'user',
        end_reason: 'user requested to end the call'
      )
      expect(whatsapp_call.reload.status).to eq('completed')
    end

    it 'does not terminate an unrelated WhatsApp call when a non-WhatsApp call ref collides' do
      unrelated_provider_call_id = 'shared-call-ref-1'
      unrelated_whatsapp_call = create(
        :call,
        account: account,
        status: 'in_progress',
        provider_call_id: unrelated_provider_call_id,
        media_session_id: 'unrelated-media-session'
      )
      fonoster_session = create(
        :telephony_call_session,
        account: account,
        conversation: create(:conversation, account: account),
        provider: 'sipuni',
        external_call_ref: unrelated_provider_call_id,
        status: 'in_progress',
        metadata: {}
      )

      result = described_class.new(
        tool_name: 'end_call',
        payload: {
          account_id: account.id,
          call_ref: fonoster_session.external_call_ref,
          arguments: { reason: 'caller requested hangup' }
        }
      ).send(:perform_end_call)

      expect(result).to include(action: 'end_call', status: 'completed', transport_terminate_requested: false)
      expect(provider).not_to have_received(:terminate_call)
      expect(media_client).not_to have_received(:terminate_session)
      expect(fonoster_session.reload).to have_attributes(status: 'completed', end_reason: 'caller requested hangup')
      expect(unrelated_whatsapp_call.reload.status).to eq('in_progress')
    end

    it 'serializes stale end_call dispatches and preserves the first terminal outcome' do
      first_dispatch = described_class.new(
        tool_name: 'end_call',
        payload: {
          account_id: account.id,
          call_ref: call_session.external_call_ref,
          arguments: { ended_by: 'ai_agent', reason: 'first terminal reason' }
        }
      )
      stale_dispatch = described_class.new(
        tool_name: 'end_call',
        payload: {
          account_id: account.id,
          call_ref: call_session.external_call_ref,
          arguments: { ended_by: 'user', reason: 'stale overwrite' }
        }
      )
      stale_dispatch.send(:call_session)

      first_dispatch.send(:perform_end_call)

      expect { stale_dispatch.send(:perform_end_call) }.to raise_error(Telephony::Error) do |error|
        expect(error.code).to eq('CALL_SESSION_TERMINAL')
      end
      expect(provider).to have_received(:terminate_call).with(whatsapp_call.provider_call_id).once
      expect(media_client).to have_received(:terminate_session).with(whatsapp_call.media_session_id).once
      expect(call_session.reload).to have_attributes(
        status: 'completed',
        ended_by: 'ai_agent',
        end_reason: 'first terminal reason'
      )
    end
  end

  # Routing handler behavior remains testable; public #perform denies this AI tool.
  describe '#perform_request_transfer routing handler' do
    let(:account) { create(:account) }
    let(:inbox) { create(:inbox, account: account) }
    let(:number_binding) { create(:telephony_number_binding, account: account, inbox: inbox) }
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:conversation) { create(:conversation, account: account, inbox: inbox, status: 'pending') }
    let(:call_session) do
      create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        inbox: inbox,
        number_binding: number_binding,
        external_call_ref: 'manager-handoff-call',
        status: 'in_progress'
      )
    end
    let(:routing_policy) do
      create(
        :telephony_routing_policy,
        account: account,
        number_binding: number_binding,
        operator_agent_aor: nil,
        ai_voice_settings: voice_settings
      )
    end
    let(:voice_settings) do
      {
        'manager_handoff_mode' => 'callback',
        'callback_message' => 'Наш менеджер вам перезвонит.'
      }
    end

    before do
      routing_policy
      create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    end

    it 'uses the native Captain handoff and returns a callback terminal action without a SIP target' do
      result = described_class.new(
        tool_name: 'request_transfer',
        payload: {
          account_id: account.id,
          call_ref: call_session.external_call_ref,
          arguments: { reason: 'Клиент попросил связаться с менеджером' }
        }
      ).send(:perform_request_transfer)

      expect(result).to include(
        action: 'callback_handoff',
        status: 'accepted',
        message: 'Наш менеджер вам перезвонит.'
      )
      expect(conversation.reload).to have_attributes(status: 'open')
      expect(conversation.waiting_since).to be_present
      expect(conversation.messages.last).to have_attributes(
        private: true,
        content: 'Клиент попросил связаться с менеджером'
      )

      expect do
        described_class.new(
          tool_name: 'request_transfer',
          payload: {
            account_id: account.id,
            call_ref: call_session.external_call_ref,
            arguments: { reason: 'Повторный вызов' }
          }
        ).send(:perform_request_transfer)
      end.not_to(change { conversation.messages.count })
    end

    it 'excludes every native Voice action regardless of handoff mode' do
      catalog = described_class.catalog(voice_settings: { 'manager_handoff_mode' => 'disabled' })
      tool_names = catalog.map { |tool| tool.fetch('name') }

      expect(tool_names).to be_empty
    end

    context 'when live transfer has no configured target' do
      let(:voice_settings) do
        {
          'manager_handoff_mode' => 'live_transfer',
          'transfer_failure_mode' => 'callback',
          'transfer_failure_message' => 'Соединить не удалось. Менеджер вам перезвонит.'
        }
      end

      it 'falls back to the already-created native manager handoff' do
        result = described_class.new(
          tool_name: 'request_transfer',
          payload: {
            account_id: account.id,
            call_ref: call_session.external_call_ref,
            arguments: { reason: 'Нужен специалист' }
          }
        ).send(:perform_request_transfer)

        expect(result).to include(
          action: 'callback_handoff',
          fallback_from: 'transfer',
          message: 'Соединить не удалось. Менеджер вам перезвонит.'
        )
        expect(conversation.reload.status).to eq('open')
      end
    end

    context 'when a missing live-transfer target must end the call' do
      let(:voice_settings) do
        {
          'manager_handoff_mode' => 'live_transfer',
          'transfer_failure_mode' => 'end_call',
          'transfer_failure_message' => 'Соединить не удалось. Завершаю звонок.'
        }
      end

      it 'returns an announced end-call action instead of raising a target error' do
        result = described_class.new(
          tool_name: 'request_transfer',
          payload: {
            account_id: account.id,
            call_ref: call_session.external_call_ref,
            arguments: { reason: 'Нужен специалист' }
          }
        ).send(:perform_request_transfer)

        expect(result).to include(
          action: 'end_call',
          fallback_from: 'transfer',
          message: 'Соединить не удалось. Завершаю звонок.'
        )
      end
    end
  end
end
