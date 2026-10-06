require 'rails_helper'

RSpec.describe Telephony::SiblingLegGrouping do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:number_binding) { create(:telephony_number_binding, account: account, inbox: inbox, provider: 'beeline') }
  let(:caller_number) { '+70000000001' }
  let(:now) { Time.zone.parse('2026-10-05 07:30:40 UTC') }

  def create_leg(ref, created_at:, **attributes)
    create(
      :telephony_call_session,
      { account: account, inbox: inbox, conversation: nil, contact: nil, number_binding: nil, provider: 'beeline',
        direction: 'inbound', status: 'ringing', external_call_ref: ref, from_number: caller_number,
        to_number: '+70000000099',
        created_at: created_at }.merge(attributes)
    )
  end

  def route(profile_id, group_ref: nil)
    { 'metadata' => { 'target_sip_profile_id' => profile_id, 'logical_call_group_ref' => group_ref }.compact }
  end

  def root_leg(call_ref: 'beeline:janus:new-leg', **overrides)
    described_class.root_leg(number_binding: number_binding, caller_number: caller_number, call_ref: call_ref, now: now, **overrides)
  end

  describe '.applies?' do
    it 'covers inbound Beeline legs only' do
      expect(described_class.applies?(provider: 'beeline')).to be(true)
      expect(described_class.applies?(provider: 'beeline', direction: 'outbound')).to be(false)
      expect(described_class.applies?(provider: 'sipuni')).to be(false)
    end
  end

  describe '.root_leg' do
    it 'is nil for the first leg of a call' do
      expect(root_leg).to be_nil
    end

    it 'returns the oldest leg of the same caller on the same channel' do
      first = create_leg('beeline:janus:1:a', created_at: now - 3.seconds)
      create_leg('beeline:janus:2:b', created_at: now - 2.seconds)

      expect(root_leg).to eq(first)
    end

    it 'is nil for the oldest leg itself when its report is retried' do
      create_leg('beeline:janus:1:a', created_at: now - 3.seconds)
      create_leg('beeline:janus:2:b', created_at: now - 2.seconds)

      expect(root_leg(call_ref: 'beeline:janus:1:a')).to be_nil
    end

    it 'points a retried later leg at the oldest leg' do
      first = create_leg('beeline:janus:1:a', created_at: now - 3.seconds)
      create_leg('beeline:janus:2:b', created_at: now - 2.seconds)

      expect(root_leg(call_ref: 'beeline:janus:2:b')).to eq(first)
    end

    it 'matches the caller by its digits, whatever the notation' do
      first = create_leg('beeline:janus:1:a', created_at: now - 2.seconds, from_number: '70000000001')

      expect(root_leg(caller_number: 'sip:+70000000001@pbx.example.test')).to eq(first)
    end

    it 'ignores legs of another caller, another channel, another provider and outbound legs' do
      create_leg('beeline:janus:1:a', created_at: now - 2.seconds, from_number: '+70000000002')
      create_leg('beeline:janus:2:b', created_at: now - 2.seconds, inbox: create(:inbox, account: account))
      create_leg('sipuni:janus:3:c', created_at: now - 2.seconds, provider: 'sipuni')
      create_leg('beeline:janus:4:d', created_at: now - 2.seconds, direction: 'outbound')
      create_leg('beeline:janus-server:5:e', created_at: now - 2.seconds)

      expect(root_leg).to be_nil
    end

    it 'does not merge a call that started longer ago than the sibling window' do
      create_leg('beeline:janus:1:a', created_at: now - described_class::SIBLING_LEG_WINDOW - 1.second)

      expect(root_leg).to be_nil
    end

    it 'does not merge two calls of the same client when the first is over' do
      create_leg('beeline:janus:1:a', created_at: now - 8.seconds, status: 'cancelled')

      expect(root_leg).to be_nil
    end

    it 'never counts a leg that is already over, however recent: a caller who dials again has a call of its own' do
      create_leg('beeline:janus:1:a', created_at: now - 2.seconds, status: 'cancelled')
      create_leg('beeline:janus:2:b', created_at: now - 1.second, status: 'no_answer')

      expect(root_leg).to be_nil
    end

    it 'joins the oldest leg that is still open and passes over the ones that are over' do
      create_leg('beeline:janus:1:a', created_at: now - 4.seconds, status: 'rejected')
      open_leg = create_leg('beeline:janus:2:b', created_at: now - 3.seconds)
      create_leg('beeline:janus:3:c', created_at: now - 2.seconds)

      expect(root_leg).to eq(open_leg)
    end

    context 'when the destination of the legs differs' do
      it 'never groups a leg that was dialled to another number' do
        create_leg('beeline:janus:1:a', created_at: now - 2.seconds, to_number: '+70000000098')

        expect(root_leg(destination_number: '+70000000099')).to be_nil
      end

      it 'groups legs of the same destination, whatever its notation' do
        first = create_leg('beeline:janus:1:a', created_at: now - 2.seconds, to_number: 'sip:+70000000099@pbx.example.test')

        expect(root_leg(destination_number: '70000000099')).to eq(first)
      end

      it 'never groups a leg that belongs to another number binding of the channel' do
        other_binding = create(:telephony_number_binding, account: account, inbox: create(:inbox, account: account), provider: 'beeline')
        create_leg('beeline:janus:1:a', created_at: now - 2.seconds, number_binding: other_binding)


        expect(root_leg).to be_nil
      end

      it 'does not constrain the destination when the new leg does not report one' do
        first = create_leg('beeline:janus:1:a', created_at: now - 2.seconds, to_number: '+70000000098')

        expect(root_leg).to eq(first)
      end
    end

    context 'when the same operator profile already has a leg of the group' do
      it 'treats a repeated leg of one operator profile as a call of its own' do
        create_leg('beeline:janus:1:a', created_at: now - 3.seconds, metadata: route(11))

        expect(root_leg(operator_profile_id: 11)).to be_nil
      end

      it 'still groups legs of different operator profiles (the genuine call to N operators)' do
        first = create_leg('beeline:janus:1:a', created_at: now - 3.seconds, metadata: route(11))
        create_leg('beeline:janus:2:b', created_at: now - 2.seconds, metadata: route(12, group_ref: 'beeline:janus:1:a'))

        expect(root_leg(operator_profile_id: 13)).to eq(first)
      end

      it 'joins the call that does not have the operator profile yet and passes over the one that has' do
        create_leg('beeline:janus:1:a', created_at: now - 6.seconds, metadata: route(11, group_ref: 'beeline:janus:1:a'))
        create_leg('beeline:janus:2:b', created_at: now - 5.seconds, metadata: route(12, group_ref: 'beeline:janus:1:a'))
        second_call = create_leg('beeline:janus:3:c', created_at: now - 2.seconds, metadata: route(11, group_ref: 'beeline:janus:3:c'))

        expect(root_leg(operator_profile_id: 12)).to eq(second_call)
      end

      it 'keeps the retried report of a leg in its own group' do
        first = create_leg('beeline:janus:1:a', created_at: now - 3.seconds, metadata: route(11, group_ref: 'beeline:janus:1:a'))
        create_leg('beeline:janus:2:b', created_at: now - 2.seconds, metadata: route(12, group_ref: 'beeline:janus:1:a'))

        expect(root_leg(call_ref: 'beeline:janus:2:b', operator_profile_id: 12)).to eq(first)
        expect(root_leg(call_ref: 'beeline:janus:1:a', operator_profile_id: 11)).to be_nil
      end
    end

    it 'keeps an unanswered leg of a long ringing call in the group until the window ends' do
      first = create_leg('beeline:janus:1:a', created_at: now - 18.seconds)

      expect(root_leg).to eq(first)
    end
  end

  describe '.group_key and .group_ref' do
    it 'reuses the key and group ref the root leg already has' do
      route = { 'logical_call_key' => 'janus-inbound:abc', 'logical_call_group_ref' => 'beeline:janus:0:z' }
      root = create_leg('beeline:janus:1:a', created_at: now, metadata: { 'metadata' => route })

      expect(described_class.group_key(root)).to eq('janus-inbound:abc')
      expect(described_class.group_ref(root)).to eq('beeline:janus:0:z')
    end

    it 'derives the same key from the root leg for every caller when it has none' do
      root = create_leg('beeline:janus:1:a', created_at: now)

      expect(described_class.group_key(root)).to start_with('native-sip-group:')
      expect(described_class.group_key(root)).to eq(described_class.group_key(root.reload))
      expect(described_class.group_ref(root)).to eq('beeline:janus:1:a')
    end
  end

  describe '.late_leg_decision?' do
    it 'is true for an operator decision and for a reject (a busy operator)' do
      expect(described_class.late_leg_decision?(action: 'operator')).to be(true)
      expect(described_class.late_leg_decision?('action' => 'reject', 'reason' => 'target_operator_busy')).to be(true)
    end

    it 'is false for an AI decision and for no decision' do
      expect(described_class.late_leg_decision?(action: 'ai')).to be(false)
      expect(described_class.late_leg_decision?({})).to be(false)
    end
  end

  describe '.owner_leg' do
    let(:group_metadata) { { 'metadata' => { 'logical_call_key' => 'janus-inbound:one-call', 'logical_call_group_ref' => 'beeline:janus:1:a' } } }
    let!(:first) { create_leg('beeline:janus:1:a', created_at: now - 3.seconds, metadata: group_metadata) }
    let!(:second) { create_leg('beeline:janus:2:b', created_at: now - 2.seconds, metadata: group_metadata) }

    it 'is nil while the call rings for everybody' do
      expect(described_class.owner_leg(first)).to be_nil
    end

    it 'is the leg an operator claimed' do
      second.update!(status: 'connecting')

      expect(described_class.owner_leg(first)).to eq(second)
    end

    it 'is the leg an operator answered' do
      second.update!(status: 'in_progress', answered_at: Time.current)

      expect(described_class.owner_leg(first)).to eq(second)
    end

    it 'counts the leg that is asked about' do
      first.update!(status: 'connecting')

      expect(described_class.owner_leg(first)).to eq(first)
    end

    it 'skips the leg that is being admitted' do
      first.update!(status: 'connecting')

      expect(described_class.owner_leg(first, except: first)).to be_nil
    end

    it 'is nil when the leg that owned the call is over' do
      second.update!(status: 'completed', answered_at: Time.current, ended_at: Time.current)

      expect(described_class.owner_leg(first)).to be_nil
    end

    it 'ignores a claim on a call of another group' do
      other_group = { 'logical_call_key' => 'janus-inbound:other', 'logical_call_group_ref' => 'beeline:janus:3:c' }
      create_leg('beeline:janus:3:c', created_at: now - 1.second, status: 'connecting', metadata: { 'metadata' => other_group })

      expect(described_class.owner_leg(first)).to be_nil
    end
  end
end
