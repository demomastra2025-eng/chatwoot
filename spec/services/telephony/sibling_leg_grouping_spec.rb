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
end
