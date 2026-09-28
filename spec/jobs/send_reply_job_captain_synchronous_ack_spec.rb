require 'rails_helper'

RSpec.describe SendReplyJob do # rubocop:disable RSpec/SpecFilePathFormat
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  def captain_reply(channel, touch: nil)
    conversation = create(:conversation, account: account, inbox: channel.inbox, status: :pending,
                                         additional_attributes: { conversation_id: 'tt-conv-1' })
    create(:captain_inbox, captain_assistant: assistant, inbox: channel.inbox)
    incoming = create(:message, account: account, conversation: conversation, inbox: channel.inbox, message_type: :incoming)
    reply = create(:message, account: account, conversation: conversation, inbox: channel.inbox,
                             sender: assistant, message_type: :outgoing, source_id: nil, skip_send_reply: true,
                             additional_attributes: {
                               'touch_id' => touch&.id,
                               'captain_delivery_fence' => {
                                 control_generation: conversation.current_captain_control_generation,
                                 assistant_id: assistant.id, trigger_message_id: incoming.id, kind: 'reply'
                               }
                             }.compact)
    touch&.mark_delivery_materialized!(reply.id)
    reply
  end

  %i[channel_line channel_tiktok].each do |channel_factory|
    context "with #{channel_factory} provider" do
      let(:channel) { create(channel_factory, account: account) }

      def stub_provider(result)
        if channel.is_a?(Channel::Line)
          client = double('line client')
          allow(Line::Bot::Client).to receive(:new).and_return(client)
          allow(client).to receive(:push_message).and_return(result)
          client
        else
          client = instance_double(Tiktok::Client)
          allow(Tiktok::Client).to receive(:new).and_return(client)
          if result.is_a?(Exception)
            allow(client).to receive(:send_text_message).and_raise(result)
          else
            allow(client).to receive(:send_text_message).and_return(result)
          end
          client
        end
      end

      def success_response
        channel.is_a?(Channel::Line) ? OpenStruct.new(code: '200', body: '{}') : 'tt-message-1'
      end

      def rejection_response(error)
        return OpenStruct.new(code: '400', body: { message: error }.to_json) if channel.is_a?(Channel::Line)

        Tiktok::Client::ProviderRejection.new(error)
      end

      it 'commits provider success and applies delivered through the real adapter and DB' do
        client = stub_provider(success_response)
        reply = captain_reply(channel)

        described_class.perform_now(reply.id)

        expect(reply.reload.status).to eq('delivered')
        expect(reply.additional_attributes['captain_delivery_state']).to eq('submitted')
        expect(reply.additional_attributes).not_to have_key('captain_delivery_pending_ack')
        expect(client).to have_received(channel.is_a?(Channel::Line) ? :push_message : :send_text_message).once
        described_class.perform_now(reply.id)
        expect(client).to have_received(channel.is_a?(Channel::Line) ? :push_message : :send_text_message).once
      end

      it 'preserves explicit provider rejection and its reason instead of reporting submitted' do
        error = 'recipient rejected'
        response = rejection_response(error)
        client = stub_provider(response)
        reply = captain_reply(channel)

        described_class.perform_now(reply.id)

        expect(reply.reload).to be_failed
        expect(reply.external_error).to eq(error)
        expect(reply.additional_attributes['captain_delivery_state']).to eq('provider_failed')
        expect(reply.additional_attributes).not_to have_key('captain_delivery_pending_ack')
        described_class.perform_now(reply.id)
        expect(client).to have_received(channel.is_a?(Channel::Line) ? :push_message : :send_text_message).once
      end

      it 'does not resend after post-fence reconciliation fails and a later job retries' do
        client = stub_provider(success_response)
        reply = captain_reply(channel)
        allow(Messages::StatusUpdateService).to receive(:new).and_raise('status unavailable')

        expect { described_class.perform_now(reply.id) }.to raise_error('status unavailable')
        expect(reply.reload.additional_attributes).to include(
          'captain_delivery_state' => 'submitted',
          'captain_delivery_pending_ack' => { 'status' => 'delivered' }
        )
        expect(reply).to be_sent
        allow(Messages::StatusUpdateService).to receive(:new).and_call_original

        described_class.perform_now(reply.id)

        expect(reply.reload).to be_delivered
        expect(reply.additional_attributes).not_to have_key('captain_delivery_pending_ack')
        expect(client).to have_received(channel.is_a?(Channel::Line) ? :push_message : :send_text_message).once
      end

      it 'reconciles a durable rejection and fails the reminder on retry without another send' do
        error = 'recipient rejected'
        response = rejection_response(error)
        client = stub_provider(response)
        reply = captain_reply(channel)
        reminder = create(:reminder, account: account, touch_conversation: reply.conversation)
        reminder.mark_delivery_materialized!(reply.id)
        reply.update!(additional_attributes: reply.additional_attributes.to_h.merge('touch_id' => reminder.id))
        allow(Messages::StatusUpdateService).to receive(:new).and_raise('status unavailable')

        expect { described_class.perform_now(reply.id) }.to raise_error('status unavailable')
        expect(reply.reload.additional_attributes).to include(
          'captain_delivery_state' => 'provider_failed',
          'captain_delivery_pending_ack' => { 'status' => 'failed', 'error' => error }
        )
        expect(reply.external_error).to be_nil
        allow(Messages::StatusUpdateService).to receive(:new).and_call_original

        described_class.perform_now(reply.id)

        expect(reply.reload).to be_failed
        expect(reply.external_error).to eq(error)
        expect(reply.additional_attributes).not_to have_key('captain_delivery_pending_ack')
        expect(reminder.reload).to be_failed
        expect(reminder.delivery_stage).to eq('failed')
        expect(client).to have_received(channel.is_a?(Channel::Line) ? :push_message : :send_text_message).once
      end

      it 'keeps a blank provider response outcome_unknown instead of claiming success or resending' do
        client = stub_provider(nil)
        reply = captain_reply(channel)

        2.times { described_class.perform_now(reply.id) }

        expect(reply.reload).to be_failed
        expect(reply.additional_attributes['captain_delivery_state']).to eq('outcome_unknown')
        expect(reply.additional_attributes).not_to have_key('captain_delivery_pending_ack')
        expect(client).to have_received(channel.is_a?(Channel::Line) ? :push_message : :send_text_message).once
      end

      it 'keeps a read acknowledgement monotonic when reconciling a pending delivered receipt' do
        stub_provider(success_response)
        reply = captain_reply(channel)
        allow(Messages::StatusUpdateService).to receive(:new).and_raise('status unavailable')
        expect { described_class.perform_now(reply.id) }.to raise_error('status unavailable')
        allow(Messages::StatusUpdateService).to receive(:new).and_call_original
        Messages::StatusUpdateService.new(reply.reload, 'read').perform

        described_class.perform_now(reply.id)

        expect(reply.reload).to be_read
        expect(reply.additional_attributes).not_to have_key('captain_delivery_pending_ack')
      end

      it 'cancels before provider I/O on human takeover' do
        client = stub_provider(success_response)
        reply = captain_reply(channel)
        create(:message, account: account, conversation: reply.conversation, inbox: channel.inbox,
                         sender: create(:user, account: account), message_type: :outgoing, skip_send_reply: true)

        described_class.perform_now(reply.id)

        expect(reply.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
        expect(reply).to be_failed
        expect(client).not_to have_received(channel.is_a?(Channel::Line) ? :push_message : :send_text_message)
      end

      it 'leaves a late provider success outcome_unknown after human takeover during the call' do
        client = stub_provider(success_response)
        reply = captain_reply(channel)
        response = success_response
        agent = create(:user, account: account)
        activate_human = lambda do |*_args, **_kwargs|
          reply.conversation.activate_captain_human_control!(source: 'agent_reply', actor: agent)
          response
        end
        if channel.is_a?(Channel::Line)
          allow(client).to receive(:push_message, &activate_human)
        else
          allow(client).to receive(:send_text_message, &activate_human)
        end

        described_class.perform_now(reply.id)

        expect(reply.reload).to be_failed
        expect(reply.additional_attributes['captain_delivery_state']).to eq('outcome_unknown')
        expect(reply.additional_attributes).not_to have_key('captain_delivery_pending_ack')
      end

      it 'does not call status or reminder code while holding the conversation fence lock' do
        stub_provider(success_response)
        reply = captain_reply(channel)
        reminder = create(:reminder, account: account, touch_conversation: reply.conversation)
        reminder.mark_delivery_materialized!(reply.id)
        reply.update!(additional_attributes: reply.additional_attributes.to_h.merge('touch_id' => reminder.id))
        lock_order = []
        conversation_locked = false
        allow(Captain::Conversation::DeliveryFenceService).to receive(:new).and_wrap_original do |original, message|
          service = original.call(message)
          conversation = service.instance_variable_get(:@conversation)
          allow(conversation).to receive(:with_captain_control_lock).and_wrap_original do |lock, &block|
            lock.call do
              conversation_locked = true
              block.call
            ensure
              conversation_locked = false
            end
          end
          service
        end
        allow_any_instance_of(Reminder).to receive(:with_lock).and_wrap_original do |original, &block|
          lock_order << :reminder
          original.call(&block)
        end
        allow_any_instance_of(Message).to receive(:with_lock).and_wrap_original do |original, &block|
          lock_order << :message
          original.call(&block)
        end
        allow(Messages::StatusUpdateService).to receive(:new).and_wrap_original do |original, *args|
          expect(conversation_locked).to be(false)
          original.call(*args)
        end

        described_class.perform_now(reply.id)

        expect(reply.reload).to be_delivered
        expect(reminder.reload.delivery_stage).to eq('delivered')
        expect(lock_order.index(:reminder)).to be < lock_order.index(:message)
      end
    end
  end

  it 'reconciles a TikTok receipt persisted after claim, before fence finalization, without resending' do
    channel = create(:channel_tiktok, account: account)
    reply = captain_reply(channel)
    reminder = create(:reminder, account: account, touch_conversation: reply.conversation)
    reminder.mark_delivery_materialized!(reply.id)
    reply.update_columns( # rubocop:disable Rails/SkipsModelValidations
      source_id: 'tt-accepted-before-crash',
      additional_attributes: reply.additional_attributes.to_h.merge(
        'touch_id' => reminder.id, 'captain_delivery_state' => 'dispatching'
      )
    )
    client = instance_double(Tiktok::Client)
    allow(Tiktok::Client).to receive(:new).and_return(client)
    allow(client).to receive(:send_text_message)

    described_class.perform_now(reply.id)

    expect(reply.reload).to be_delivered
    expect(reply.additional_attributes['captain_delivery_state']).to eq('submitted')
    expect(reply.additional_attributes).not_to have_key('captain_delivery_pending_ack')
    expect(reminder.reload.delivery_stage).to eq('delivered')
    expect(client).not_to have_received(:send_text_message)
  end

  it 'retains a post-crash TikTok receipt until status and reminder reconcile on retry' do
    channel = create(:channel_tiktok, account: account)
    reply = captain_reply(channel)
    reminder = create(:reminder, account: account, touch_conversation: reply.conversation)
    reminder.mark_delivery_materialized!(reply.id)
    reply.update_columns( # rubocop:disable Rails/SkipsModelValidations
      source_id: 'tt-accepted-before-crash',
      additional_attributes: reply.additional_attributes.to_h.merge(
        'touch_id' => reminder.id, 'captain_delivery_state' => 'dispatching'
      )
    )
    client = instance_double(Tiktok::Client)
    allow(Tiktok::Client).to receive(:new).and_return(client)
    allow(client).to receive(:send_text_message)
    allow(Messages::StatusUpdateService).to receive(:new).and_raise('status unavailable')

    expect { described_class.perform_now(reply.id) }.to raise_error('status unavailable')
    expect(reply.reload.additional_attributes).to include(
      'captain_delivery_state' => 'submitted',
      'captain_delivery_pending_ack' => { 'status' => 'delivered' }
    )
    expect(reminder.reload.delivery_stage).to eq('materialized')
    allow(Messages::StatusUpdateService).to receive(:new).and_call_original

    described_class.perform_now(reply.id)

    expect(reply.reload).to be_delivered
    expect(reminder.reload.delivery_stage).to eq('delivered')
    expect(reply.additional_attributes).not_to have_key('captain_delivery_pending_ack')
    expect(client).not_to have_received(:send_text_message)
  end

  it 'keeps an ambiguous TikTok transport timeout unknown, without falsely failing a reminder or resending' do
    channel = create(:channel_tiktok, account: account)
    client = instance_double(Tiktok::Client)
    allow(Tiktok::Client).to receive(:new).and_return(client)
    allow(client).to receive(:send_text_message).and_raise(Timeout::Error, 'lost TikTok response')
    reply = captain_reply(channel)
    reminder = create(:reminder, account: account, touch_conversation: reply.conversation)
    reminder.mark_delivery_materialized!(reply.id)
    reply.update!(additional_attributes: reply.additional_attributes.to_h.merge('touch_id' => reminder.id))

    2.times { described_class.perform_now(reply.id) }

    expect(reply.reload.additional_attributes['captain_delivery_state']).to eq('outcome_unknown')
    expect(reply.external_error).to be_nil
    expect(reminder.reload.delivery_stage).to eq('materialized')
    expect(reminder).not_to be_failed
    expect(client).to have_received(:send_text_message).once
  end

  it 'keeps a TikTok send that exceeds the fence deadline unknown without resending' do
    channel = create(:channel_tiktok, account: account)
    client = instance_double(Tiktok::Client)
    allow(Tiktok::Client).to receive(:new).and_return(client)
    allow(client).to receive(:send_text_message) { sleep 2 }
    stub_const('Captain::Conversation::DeliveryFenceService::PROVIDER_DISPATCH_DEADLINE', 1)
    reply = captain_reply(channel)

    2.times { described_class.perform_now(reply.id) }

    expect(reply.reload.additional_attributes['captain_delivery_state']).to eq('outcome_unknown')
    expect(reply.external_error).to be_nil
    expect(client).to have_received(:send_text_message).once
  end

  it 'does not lose a TikTok receipt when finalization raises after the provider accepted it' do
    channel = create(:channel_tiktok, account: account)
    client = instance_double(Tiktok::Client)
    allow(Tiktok::Client).to receive(:new).and_return(client)
    allow(client).to receive(:send_text_message).and_return('tt-accepted-before-finalize-error')
    reply = captain_reply(channel)
    allow(Captain::Conversation::DeliveryFenceService).to receive(:new).and_wrap_original do |original, message|
      fence = original.call(message)
      allow(fence).to receive(:finalize_delivery!).and_raise('finalize unavailable')
      fence
    end

    described_class.perform_now(reply.id)
    described_class.perform_now(reply.id)

    expect(reply.reload).to be_delivered
    expect(reply.additional_attributes['captain_delivery_state']).to eq('submitted')
    expect(client).to have_received(:send_text_message).once
  end

  it 'keeps a post-crash TikTok receipt fenced after human takeover without resending' do
    channel = create(:channel_tiktok, account: account)
    reply = captain_reply(channel)
    reply.update_columns( # rubocop:disable Rails/SkipsModelValidations
      source_id: 'tt-accepted-before-crash',
      additional_attributes: reply.additional_attributes.to_h.merge('captain_delivery_state' => 'dispatching')
    )
    agent = create(:user, account: account)
    reply.conversation.activate_captain_human_control!(source: 'agent_reply', actor: agent)
    client = instance_double(Tiktok::Client)
    allow(Tiktok::Client).to receive(:new).and_return(client)
    allow(client).to receive(:send_text_message)

    described_class.perform_now(reply.id)

    expect(reply.reload.additional_attributes['captain_delivery_state']).to eq('outcome_unknown')
    expect(reply).to be_failed
    expect(reply.additional_attributes).not_to have_key('captain_delivery_pending_ack')
    expect(client).not_to have_received(:send_text_message)
  end
end
