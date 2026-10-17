require 'rails_helper'

RSpec.describe Telephony::CallsService do
  describe '#create_outbound!' do
    it 'checks operator availability before creating provider side effects' do
      account = create(:account)
      user = create(:user, account: account, role: :agent)
      contact = instance_double(Contact, phone_number: '+77070001002')
      inbox = instance_double(Inbox)
      conversation = instance_double(Conversation)
      guard = instance_double(Telephony::OperatorBusyService)

      allow(Telephony::OperatorBusyService).to receive(:new)
        .with(account: account, user: user)
        .and_return(guard)
      allow(guard).to receive(:with_lock).and_raise(
        Telephony::Error.new(
          code: 'OPERATOR_BUSY',
          message: 'Operator already has an active call',
          status: :conflict
        )
      )

      expect do
        described_class.new(account: account).create_outbound!(
          inbox: inbox,
          conversation: conversation,
          contact: contact,
          user: user
        )
      end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('OPERATOR_BUSY') }
    end

    it 'enforces call_routing.outbound.access_mode == selected_operators and applies caller_id_number' do
      account = create(:account)
      allowed_agent = create(:user, account: account, role: :agent)
      blocked_agent = create(:user, account: account, role: :agent)
      voice_channel = create(
        :channel_voice,
        account: account,
        provider: 'wazo',
        phone_number: '+77085012233',
        provider_config: {
          'provider_kind' => 'wazo',
          'number_ref' => 'wazo-num-outbound-1',
          'provider_connection_id' => 1,
          'call_routing' => {
            'outbound' => {
              'access_mode' => 'selected_operators',
              'allowed_user_ids' => [allowed_agent.id],
              'caller_id_number' => '+77089990011'
            }
          }
        }
      )
      voice_inbox = voice_channel.inbox
      Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
      contact = create(:contact, account: account, phone_number: '+77015556677')
      contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox)
      conversation = create(:conversation, account: account, inbox: voice_inbox, contact: contact, contact_inbox: contact_inbox)

      expect do
        described_class.new(account: account).create_outbound!(
          inbox: voice_inbox,
          conversation: conversation,
          contact: contact,
          user: blocked_agent
        )
      end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('OUTBOUND_CALL_FORBIDDEN') }

      result = described_class.new(account: account).create_outbound!(
        inbox: voice_inbox,
        conversation: conversation,
        contact: contact,
        user: allowed_agent
      )
      expect(result[:call_session].from_number).to eq('+77089990011')
    end
  end

  describe 'InboundRoutingService call_routing integration' do
    it 'honors call_routing.inbound schedule_mode, fallback_action=forward, and off_hours_action=forward' do
      account = create(:account)
      voice_channel = create(
        :channel_voice,
        account: account,
        provider: 'wazo',
        phone_number: '+77085012244',
        provider_config: {
          'provider_kind' => 'wazo',
          'number_ref' => 'wazo-num-inbound-1',
          'provider_connection_id' => 1,
          'call_routing' => {
            'inbound' => {
              'schedule_mode' => 'always',
              'fallback_action' => 'forward',
              'fallback_forward_number' => '+77017778899'
            }
          }
        }
      )
      voice_inbox = voice_channel.inbox
      binding = Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
      allow(voice_inbox).to receive(:out_of_office?).and_return(true)

      decision = Telephony::InboundRoutingService.new(
        payload: {
          'account_id' => account.id,
          'number_ref' => binding.number_ref,
          'call_ref' => 'wazo-inbound-route-1',
          'caller_number' => '+77015556677',
          'inbound_number' => '+77085012244',
          'diagnostic_route_probe' => true
        }
      ).perform

      expect(decision[:action]).to eq('forward')
      expect(decision[:forward_number]).to eq('+77017778899')
      expect(decision[:reason]).to eq('operator_unavailable')
    end

    it 'allows parallel AI voice agent calls on a single voice_agent SIP profile up to max_channels and rejects when max_channels is reached' do
      account = create(:account)
      connection = create(
        :telephony_provider_connection,
        account: account,
        provider_kind: 'wazo',
        status: 'active',
        metadata: { 'max_channels' => 2 }
      )
      voice_channel = create(
        :channel_voice,
        account: account,
        provider: 'wazo',
        phone_number: '+77085012255',
        provider_config: {
          'provider_kind' => 'wazo',
          'number_ref' => 'wazo-num-ai-parallel-1',
          'provider_connection_id' => connection.id,
          'routing_mode' => 'ai',
          'app_ref' => 'wazo-ai-app-ref',
          'ai_app_ref' => 'wazo-ai-app-ref',
          'call_routing' => {
            'inbound' => {
              'routing_authority' => 'onelink',
              'schedule_mode' => 'always',
              'fallback_action' => 'ai'
            }
          }
        }
      )
      voice_inbox = voice_channel.inbox
      binding = Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
      binding.update!(provider_connection: connection, app_ref: 'wazo-ai-app-ref')
      voice_agent_profile = create(
        :telephony_sip_profile,
        account: account,
        inbox: voice_inbox,
        provider_connection: connection,
        user: nil,
        profile_kind: 'voice_agent',
        internal_extension: '1099',
        sip_username: 'voice-agent-1099',
        credentials_ref: 'cred-voice-agent-1099',
        password_secret_ref: 'cred-voice-agent-1099',
        status: 'active',
        enabled: true
      )

      # Diagnostic probe does not create a CallSession
      probe_decision = Telephony::InboundRoutingService.new(
        payload: {
          'account_id' => account.id,
          'number_ref' => binding.number_ref,
          'call_ref' => 'wazo-ai-probe-0',
          'caller_number' => '+77015550000',
          'inbound_number' => '+77085012255',
          'diagnostic_route_probe' => true
        }
      ).perform
      expect(probe_decision[:action]).to eq('ai')
      expect(Telephony::CallSession.where(external_call_ref: 'wazo-ai-probe-0')).to be_empty

      # First real inbound AI call on the single voice_agent profile reserves an active CallSession automatically
      first_decision = Telephony::InboundRoutingService.new(
        payload: {
          'account_id' => account.id,
          'number_ref' => binding.number_ref,
          'call_ref' => 'wazo-ai-call-1',
          'caller_number' => '+77015550001',
          'inbound_number' => '+77085012255'
        }
      ).perform

      expect(first_decision[:action]).to eq('ai')
      expect(first_decision[:voice_agent_sip_profile_id]).to eq(voice_agent_profile.id)
      expect(first_decision[:ai_max_concurrent_calls]).to eq(2)
      expect(first_decision[:active_trunk_calls]).to eq(0)
      expect(Telephony::CallSession.active.where(external_call_ref: 'wazo-ai-call-1')).to exist

      # Second simultaneous real inbound call still routes to AI (active_trunk_calls=1 < max_channels=2) and reserves second CallSession
      second_decision = Telephony::InboundRoutingService.new(
        payload: {
          'account_id' => account.id,
          'number_ref' => binding.number_ref,
          'call_ref' => 'wazo-ai-call-2',
          'caller_number' => '+77015550002',
          'inbound_number' => '+77085012255'
        }
      ).perform

      expect(second_decision[:action]).to eq('ai')
      expect(second_decision[:ai_max_concurrent_calls]).to eq(2)
      expect(second_decision[:active_trunk_calls]).to eq(1)
      expect(Telephony::CallSession.active.where(external_call_ref: 'wazo-ai-call-2')).to exist

      # Third simultaneous real inbound call sees 2 active trunk calls and is rejected with max_channels_reached
      third_decision = Telephony::InboundRoutingService.new(
        payload: {
          'account_id' => account.id,
          'number_ref' => binding.number_ref,
          'call_ref' => 'wazo-ai-call-3',
          'caller_number' => '+77015550003',
          'inbound_number' => '+77085012255'
        }
      ).perform

      expect(third_decision[:action]).to eq('reject')
      expect(third_decision[:reason]).to eq('max_channels_reached')
      expect(third_decision[:ai_max_concurrent_calls]).to eq(2)
      expect(third_decision[:active_trunk_calls]).to eq(2)
    end

    it 'honors external_pbx routing authority for external Cloud PBX providers, rejects disabled explicit targets without broadcasting, and supports voice_agent targets' do
      account = create(:account)
      operator = create(:user, account: account, role: :agent)
      second_operator = create(:user, account: account, role: :agent)
      connection = create(:telephony_provider_connection, account: account, provider_kind: 'sipuni', status: 'active')
      voice_channel = create(
        :channel_voice,
        :sipuni,
        account: account,
        provider: 'sipuni',
        phone_number: '+77085012266',
        provider_config: {
          'provider_kind' => 'sipuni',
          'number_ref' => 'sipuni-num-ext-1',
          'provider_connection_id' => connection.id,
          'app_ref' => 'sipuni-ai-app',
          'ai_app_ref' => 'sipuni-ai-app',
          'call_routing' => {
            'inbound' => {
              'routing_authority' => 'external_pbx',
              'schedule_mode' => 'business_hours',
              'off_hours_action' => 'reject',
              'skip_busy_operators' => true
            }
          }
        }
      )
      voice_inbox = voice_channel.inbox
      binding = Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
      binding.update!(provider_connection: connection, app_ref: 'sipuni-ai-app')
      binding.routing_policy.update!(ai_app_ref: 'sipuni-ai-app')
      profile = create(
        :telephony_sip_profile,
        account: account,
        inbox: voice_inbox,
        provider_connection: connection,
        user: operator,
        internal_extension: '205',
        sip_username: 'sipuni-205',
        agent_aor: 'sip:sipuni-205@ats01.kz.sipuni.com',
        status: 'active',
        enabled: true
      )
      disabled_profile = create(
        :telephony_sip_profile,
        account: account,
        inbox: voice_inbox,
        provider_connection: connection,
        user: second_operator,
        internal_extension: '206',
        sip_username: 'sipuni-206',
        agent_aor: 'sip:sipuni-206@ats01.kz.sipuni.com',
        status: 'disabled',
        enabled: false
      )
      voice_agent_profile = create(
        :telephony_sip_profile,
        account: account,
        inbox: voice_inbox,
        provider_connection: connection,
        user: nil,
        profile_kind: 'voice_agent',
        internal_extension: '299',
        sip_username: 'sipuni-ai-299',
        credentials_ref: 'cred-sipuni-ai-299',
        password_secret_ref: 'cred-sipuni-ai-299',
        agent_aor: 'sip:sipuni-ai-299@ats01.kz.sipuni.com',
        status: 'active',
        enabled: true
      )
      allow(voice_inbox).to receive(:out_of_office?).and_return(true)

      decision = Telephony::InboundRoutingService.new(
        payload: {
          'account_id' => account.id,
          'number_ref' => binding.number_ref,
          'call_ref' => 'sipuni-ext-call-1',
          'caller_number' => '+77015559988',
          'inbound_number' => '+77085012266',
          'diagnostic_route_probe' => true
        },
        trusted_target_sip_profile_id: profile.id
      ).perform

      expect(decision[:action]).to eq('operator')
      expect(decision[:routing_authority]).to eq('external_pbx')
      expect(decision[:reason]).to eq('external_pbx_route')
      expect(decision[:operator_user_id]).to eq(operator.id)

      disabled_target_decision = Telephony::InboundRoutingService.new(
        payload: {
          'account_id' => account.id,
          'number_ref' => binding.number_ref,
          'call_ref' => 'sipuni-ext-call-2',
          'caller_number' => '+77015559988',
          'inbound_number' => '+77085012266',
          'diagnostic_route_probe' => true
        },
        trusted_target_sip_profile_id: disabled_profile.id
      ).perform

      expect(disabled_target_decision[:action]).to eq('reject')
      expect(disabled_target_decision[:reason]).to eq('operator_unavailable')

      ai_target_decision = Telephony::InboundRoutingService.new(
        payload: {
          'account_id' => account.id,
          'number_ref' => binding.number_ref,
          'call_ref' => 'sipuni-ext-call-3',
          'caller_number' => '+77015559988',
          'inbound_number' => '+77085012266',
          'target_extension' => voice_agent_profile.internal_extension,
          'diagnostic_route_probe' => true
        }
      ).perform

      expect(ai_target_decision[:action]).to eq('ai')
      expect(ai_target_decision[:reason]).to eq('external_pbx_route')
    end
  end
end

