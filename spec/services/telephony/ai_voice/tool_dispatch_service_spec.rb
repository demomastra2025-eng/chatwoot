require 'rails_helper'

RSpec.describe Telephony::AiVoice::ToolDispatchService do
  describe '.catalog' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    it 'bounds Captain discovery and preserves native call controls when discovery stalls' do
      stub_const("#{described_class}::VOICE_CONTEXT_CAPTAIN_CATALOG_TIMEOUT_SECONDS", 0.001)
      allow(Captain::Mcp::ToolCatalog).to receive(:with_runtime_cache).and_call_original
      allow(Captain::Mcp::ToolCatalog).to receive(:without_discovery).and_call_original
      catalog_attempt = 0
      allow(described_class).to receive(:captain_tool_catalog) do
        catalog_attempt += 1
        sleep 0.05 if catalog_attempt == 1
        [{ 'name' => 'faq_lookup' }]
      end

      names = described_class.catalog(captain_assistant: assistant).pluck('name')

      expect(names).to include('end_call', 'request_transfer', 'faq_lookup')
      expect(Captain::Mcp::ToolCatalog).to have_received(:with_runtime_cache).once
      expect(Captain::Mcp::ToolCatalog).to have_received(:without_discovery).once
    end

    it 'resolves only agent-scope Captain tools for the voice catalog' do
      allow(assistant).to receive(:voice_runtime_agent_tools).and_return([{ id: 'faq_lookup' }, { id: 'handoff' }])
      expect(assistant).not_to receive(:available_assistant_tools)

      names = described_class.catalog(captain_assistant: assistant).pluck('name')
      definition_ids = described_class.captain_tool_definitions(assistant).pluck(:id)

      expect(names).to include('faq_lookup', 'end_call')
      expect(names).not_to include('handoff')
      expect(definition_ids).to contain_exactly('faq_lookup')
    end

    it 'publishes native Captain parameter definitions to the realtime provider' do
      allow(assistant).to receive(:voice_runtime_agent_tools).and_return([{ id: 'faq_lookup' }])

      faq = described_class.catalog(captain_assistant: assistant).find { |tool| tool.fetch('name') == 'faq_lookup' }

      expect(faq.dig('parameters', 'required')).to eq(['query'])
      expect(faq.dig('parameters', 'properties', 'query')).to include(
        'type' => 'string',
        'description' => a_string_including('FAQ')
      )
    end

    it 'adds voice data-integrity guidance to mutating Captain tools' do
      allow(assistant).to receive(:voice_runtime_agent_tools).and_return(
        [{ id: 'create_deal' }, { id: 'add_contact_note' }]
      )

      catalog = described_class.catalog(captain_assistant: assistant).index_by { |tool| tool.fetch('name') }

      expect(catalog.dig('create_deal', 'description')).to include('actual call channel')
      expect(catalog.dig('add_contact_note', 'description')).to include('explicitly confirms')
      expect(catalog.dig('add_contact_note', 'parameters', 'properties', 'voice_caller_confirmed')).to include(
        'type' => 'boolean',
        'description' => a_string_including('complete phone number')
      )
    end

    it 'publishes valid item schemas for native array parameters' do
      allow(assistant).to receive(:voice_runtime_agent_tools).and_return([{ id: 'create_deal' }])

      create_deal = described_class.catalog(captain_assistant: assistant).find { |tool| tool.fetch('name') == 'create_deal' }

      expect(create_deal.dig('parameters', 'properties', 'closing_reasons', 'items')).to eq('type' => 'string')
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

  describe '#lock_assistant_assignment!' do
    it 'locks the inbox before the shared advisory and assignment rows' do
      service = described_class.allocate
      inbox = double(id: 42, present?: true)
      captain_inbox = double
      routing_policy = double
      allow(service).to receive_messages(
        assignment_inbox: inbox,
        assignment_captain_inbox: captain_inbox,
        routing_policy: routing_policy
      )

      expect(inbox).to receive(:lock!).ordered
      expect(Telephony::AiVoice::AssistantAssignmentLock).to receive(:acquire!).with(42).ordered
      expect(captain_inbox).to receive(:lock!).ordered
      expect(routing_policy).to receive(:lock!).ordered

      service.send(:lock_assistant_assignment!)
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

    it 'acquires the shared assignment lock before yielding the current assistant' do
      service = described_class.new(
        tool_name: 'faq_lookup',
        payload: { account_id: account.id, call_ref: call_session.external_call_ref, arguments: {} }
      )

      expect(Telephony::AiVoice::AssistantAssignmentLock).to receive(:acquire!).with(inbox.id).and_call_original

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
  end

  describe '#perform end_call' do
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
      ).perform

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
      ).perform

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

      first_dispatch.perform

      expect { stale_dispatch.perform }.to raise_error(Telephony::Error) do |error|
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

  describe '#perform request_transfer' do
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
      ).perform

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
        ).perform
      end.not_to(change { conversation.messages.count })
    end

    it 'excludes request_transfer from the catalog when manager handoff is disabled' do
      catalog = described_class.catalog(voice_settings: { 'manager_handoff_mode' => 'disabled' })
      tool_names = catalog.map { |tool| tool.fetch('name') }

      expect(tool_names).not_to include('request_transfer')
      expect(tool_names).to include('end_call')
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
        ).perform

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
        ).perform

        expect(result).to include(
          action: 'end_call',
          fallback_from: 'transfer',
          message: 'Соединить не удалось. Завершаю звонок.'
        )
      end
    end
  end
end
