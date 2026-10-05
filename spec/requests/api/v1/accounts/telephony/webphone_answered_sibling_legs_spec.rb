require 'rails_helper'

# The legs of one Beeline call share a conversation and one voice message (the
# route lifecycle jobs run, as in production). One operator takes the call: any
# of the three. The chat must show one call that follows the answered leg, and
# the legs closed for the others must neither start conversations of their own
# nor leave a message behind that stays "connecting" or reads "no answer".
RSpec.describe 'Telephony webphone answered call with sibling legs', type: :request do
  include ActiveJob::TestHelper
  include_context 'with three Beeline operator browsers'

  def report_legs_with_lifecycle
    profiles.each_with_index.map do |profile, index|
      perform_enqueued_jobs(only: Telephony::InboundRouteLifecycleJob) { report_leg(profile, "sip-call-id-#{index}") }
      leg_session(profile, "sip-call-id-#{index}")
    end
  end

  def claim!(index, legs)
    Telephony::OperatorCallClaimService.new(account: account, user: operators[index], call_ref: legs[index].external_call_ref).perform
  end

  def answer!(index, legs)
    Telephony::OperatorCallAnsweredService.new(account: account, user: operators[index], call_ref: legs[index].external_call_ref).perform
  end

  def complete!(index, legs)
    Telephony::OperatorCallRejectService.new(
      account: account, user: operators[index], call_ref: legs[index].external_call_ref, status: 'completed'
    ).perform
  end

  # The end of the call as the provider reports it.
  def complete_by_event!(leg)
    Telephony::EventsIngestionService.new(
      payload: {
        account_id: account.id, call_ref: leg.external_call_ref, provider: 'beeline', event: 'session_completed',
        event_type: 'session_completed', event_key: "completed:#{leg.external_call_ref}", status: 'completed',
        direction: 'inbound', ended_at: Time.current.iso8601(3), duration_seconds: 12
      }
    ).perform
  end

  def call_statuses
    account.conversations.order(:id).map { |conversation| conversation.additional_attributes['call_status'] }
  end

  def voice_bubbles
    account.messages.voice_calls.order(:id).map { |message| message.content_attributes.dig('data', 'status') }
  end

  [0, 1, 2].each do |winner_index|
    context "when operator #{winner_index + 1} of 3 takes the call" do
      it 'keeps one conversation, no ghost conversation for a closed leg and one bubble' do
        legs = report_legs_with_lifecycle
        conversation_ids = legs.map { |leg| leg.reload.conversation_id }
        expect(conversation_ids.uniq.size).to eq(1)

        expect { claim!(winner_index, legs) }.not_to(change { [account.conversations.count, account.messages.voice_calls.count] })

        expect(legs.map { |leg| leg.reload.conversation_id }).to eq(conversation_ids)
        expect(voice_bubbles.size).to eq(1)
        expect(voice_bubbles).not_to include('no_answer')
      end

      it 'closes the other legs as answered by another operator' do
        legs = report_legs_with_lifecycle
        claim!(winner_index, legs)

        legs.each_with_index do |leg, index|
          if index == winner_index
            expect(leg.reload.end_reason).to be_nil
          else
            expect(leg.reload).to have_attributes(status: 'no_answer', end_reason: 'answered_by_other_operator')
          end
        end
      end

      it 'makes the bubble follow the answered leg until the call ends' do
        legs = report_legs_with_lifecycle
        claim!(winner_index, legs)
        answer!(winner_index, legs)
        expect(voice_bubbles).to eq(['in_progress'])

        complete!(winner_index, legs)

        expect(voice_bubbles).to eq(['completed'])
        expect(account.conversations.count).to eq(1)
        expect(account.messages.voice_calls.count).to eq(1)
      end

      it 'keeps the call in its conversation when the provider reports the end of the answered leg' do
        legs = report_legs_with_lifecycle
        claim!(winner_index, legs)
        answer!(winner_index, legs)
        expect(call_statuses).to eq(['in_progress'])

        complete_by_event!(legs[winner_index])

        expect(account.conversations.count).to eq(1)
        expect(call_statuses).to eq(['completed'])
        expect(voice_bubbles).to eq(['completed'])
        expect(legs.map { |leg| leg.reload.conversation_id }.uniq.size).to eq(1)
      end

      it 'does not tell the operator who took the call about the legs closed for the others' do
        legs = report_legs_with_lifecycle
        claim!(winner_index, legs)

        winner_token = operators[winner_index].pubsub_token
        legs.each_with_index do |leg, index|
          next if index == winner_index

          expect(ActionCable.server).not_to have_received(:broadcast).with(
            winner_token, hash_including(event: 'voice_call.status_changed', data: hash_including(callSid: leg.external_call_ref))
          )
          expect(ActionCable.server).to have_received(:broadcast).with(
            operators[index].pubsub_token,
            hash_including(event: 'voice_call.status_changed', data: hash_including(callSid: leg.external_call_ref, status: 'no_answer'))
          )
        end
      end
    end
  end

  it 'leaves nothing behind when the closed legs report the hangup of the PBX afterwards' do
    legs = report_legs_with_lifecycle
    claim!(1, legs)
    answer!(1, legs)

    [0, 2].each do |index|
      post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
           params: { call_ref: legs[index].external_call_ref, status: 'no_answer', reason: 'remote_hangup' },
           headers: auth_headers(operators[index]), as: :json
    end
    complete!(1, legs)

    expect(account.conversations.count).to eq(1)
    expect(voice_bubbles).to eq(['completed'])
  end
end
