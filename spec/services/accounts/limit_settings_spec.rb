# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Accounts::LimitSettings do
  let(:account) { create(:account) }
  let(:max) { ChatwootApp.max_limit }
  let(:marks_key) { described_class::KEY }

  def settings(modules: nil)
    described_class.new(account.reload, modules: modules)
  end

  # A plan with numbers of its own: the base of the file has only `unlimited` for conversations and channels
  def plan_with(numbers)
    plans = Accounts::Plans
    allow(plans).to receive(:limits_for).and_wrap_original do |original, *args|
      original.call(*args).merge(numbers)
    end
  end

  def apply_plan!(modules: [])
    Accounts::ApplyPlan.new(account: account, modules: modules).call
  end

  def choose(marks)
    account.update!(custom_attributes: account.custom_attributes.to_h.merge(marks_key => marks))
  end

  # The general values of the platform (installation settings): none unless a spec sets one
  def global(name, value)
    allow(GlobalConfig).to receive(:get).with(name).and_return(name => value)
  end

  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    described_class::GLOBAL_SETTINGS.each_value { |name| global(name, nil) }
  end

  describe 'the number that stands for «без ограничений»' do
    it 'is 100 000 for a count, and a number nobody reaches for the storage (bytes) and the AI tokens' do
      expect(Accounts::Plans.unlimited_value('agents')).to eq(max)
      expect(Accounts::Plans.unlimited_value('storage_bytes')).to eq(max * 1.gigabyte)
      expect(Accounts::Plans.unlimited_value('captain_tokens')).to eq(max * 1_000_000)
    end

    it 'is recognised for its own limit only' do
      expect(Accounts::Plans.unlimited_value?('agents', max)).to be(true)
      expect(Accounts::Plans.unlimited_value?('storage_bytes', max)).to be(false) # 100 000 bytes is a quota, not «no limit»
      expect(Accounts::Plans.unlimited_value?('storage_bytes', max * 1.gigabyte)).to be(true)
      expect(Accounts::Plans.unlimited_value?('agents', nil)).to be(false)
    end

    it 'is what a plan writes for `unlimited` in every limit' do
      # a plan whose file says `unlimited` for the storage and the tokens
      config = YAML.safe_load(File.read(Accounts::Plans::CONFIG_PATH))
      config['base']['limits'].merge!('storage_bytes' => 'unlimited', 'captain_tokens' => 'unlimited')
      limits = Accounts::Plans.new(config).limits_for([])

      expect(limits).to include('storage_bytes' => max * 1.gigabyte, 'captain_tokens' => max * 1_000_000, 'conversations' => max)
    end
  end

  describe '#source and #effective: one limit, every combination' do
    context 'when the account has no plan' do
      it 'follows the platform: no number is no limit, the general value is the limit' do
        expect(settings.source('conversations')).to eq(:plan)
        expect(settings.effective('conversations')).to be_nil

        global('ACCOUNT_CONVERSATIONS_LIMIT', 500)
        expect(settings.effective('conversations')).to eq(500)
        expect(settings.plan_following_value('conversations')).to eq(500)
        expect(settings.plan_value('conversations')).to be_nil
      end

      it 'reads a number the account holds as «своё число»' do
        account.update!(limits: { 'agents' => 5 })

        expect(settings.source('agents')).to eq(:custom)
        expect(settings.custom_value('agents')).to eq(5)
        expect(settings.choice('agents')).to eq(5)
        expect(settings.effective('agents')).to eq(5)
      end

      it 'reads the number of no limit as «без ограничений»' do
        account.update!(limits: { 'agents' => max, 'storage_bytes' => max * 1.gigabyte })

        expect(settings.source('agents')).to eq(:unlimited)
        expect(settings.source('storage_bytes')).to eq(:unlimited)
        expect(settings.choice('agents')).to eq(:unlimited)
        expect(settings.custom_value('agents')).to be_nil
      end
    end

    context 'when the account has a plan' do
      before { apply_plan! }

      it 'follows the number of the plan, and shows it as the number «как в тарифе» gives' do
        expect(account.reload.limits['conversations']).to eq(max)
        expect(settings.source('conversations')).to eq(:plan)
        expect(settings.plan_value('conversations')).to eq(max)
        expect(settings.plan_following_value('conversations')).to eq(max)
        expect(settings.effective('conversations')).to eq(max)
      end

      it 'follows the platform where the plan has no number' do
        global('ACCOUNT_STORAGE_BYTES_LIMIT', 10.gigabytes)

        expect(settings.plan_value('storage_bytes')).to be_nil
        expect(settings.plan_following_value('storage_bytes')).to eq(10.gigabytes)
        expect(settings.effective('storage_bytes')).to eq(10.gigabytes)
      end

      it 'has no limit at all where neither the plan nor the platform has a number' do
        expect(settings.plan_following_value('inboxes')).to be_nil
        expect(settings.effective('inboxes')).to be_nil
      end

      it 'takes a number chosen by hand over the plan, and «без ограничений» over a general value' do
        choose('conversations' => 50, 'storage_bytes' => 'unlimited')
        account.update!(limits: account.limits.merge('conversations' => 50, 'storage_bytes' => max * 1.gigabyte))
        global('ACCOUNT_STORAGE_BYTES_LIMIT', 10.gigabytes)

        expect(settings.source('conversations')).to eq(:custom)
        expect(settings.effective('conversations')).to eq(50)
        expect(settings.source('storage_bytes')).to eq(:unlimited)
        expect(settings.effective('storage_bytes')).to eq(max * 1.gigabyte)
      end

      it 'takes a chosen number even when it is the same as the number of the plan' do
        choose('conversations' => max)
        expect(settings.source('conversations')).to eq(:custom)

        choose('conversations' => 'unlimited')
        expect(settings.source('conversations')).to eq(:unlimited)
      end

      it 'ignores a malformed list: an unknown limit, a negative or fractional number, anything else' do
        choose('nonsense' => 5, 'agents' => -1, 'inboxes' => 1.5, 'conversations' => 'many', 'emails' => nil)

        expect(settings.marks).to eq({})
        expect(settings.source('agents')).to eq(:plan)
      end
    end

    context 'when the plan has a number of its own' do
      before do
        plan_with('agents' => 10)
        apply_plan!
      end

      it 'writes it, and an account that follows the plan holds it' do
        expect(account.reload.limits['agents']).to eq(10)
        expect(settings.source('agents')).to eq(:plan)
      end

      it 'calls a number the account holds that is not the plan one «своё число» while the account is not tracked yet' do
        account.update!(custom_attributes: account.custom_attributes.to_h.except(marks_key), limits: { 'agents' => 3 })

        expect(settings).not_to be_tracked
        expect(settings.source('agents')).to eq(:custom)
      end

      it 'calls it an older number of the plan once the account is tracked' do
        account.update!(limits: account.limits.merge('agents' => 3))

        expect(settings).to be_tracked
        expect(settings.source('agents')).to eq(:plan)
        expect(settings.effective('agents')).to eq(3) # what the code enforces until the plan is applied again
      end
    end

    context 'when a trial ended and put the operator limit at 0' do
      it 'does not take the zero for a choice' do
        account.update!(limits: { 'agents' => 5, 'inboxes' => 3 })
        apply_plan!
        account.reload.activate_trial!(3)
        account.expire_trial!

        expect(account.reload.limits).to include('agents' => 0, 'inboxes' => 0)
        expect(settings.source('agents')).to eq(:plan)
        expect(settings.effective('agents')).to eq(0)
      end

      it 'does not lock a limit chosen by hand, and leaves its zero alone' do
        apply_plan!
        choose('agents' => 0, 'inboxes' => 'unlimited')
        account.update!(limits: account.limits.merge('agents' => 0, 'inboxes' => max))
        account.reload.activate_trial!(3)
        account.expire_trial!

        expect(account.reload.limits).to include('agents' => 0, 'inboxes' => max)
        expect(settings.source('agents')).to eq(:custom)
        expect(account.trial_held_limits).to be_empty
      end
    end
  end

  describe '#positions' do
    it 'gives every limit its source and the number that applies' do
      apply_plan!
      account.update!(limits: account.limits.merge('agents' => 4))
      choose('agents' => 4)

      positions = settings.positions

      expect(positions.keys).to eq(Accounts::Plans::LIMIT_KEYS)
      expect(positions['agents']).to eq(described_class::Position.new(source: :custom, value: 4))
      expect(positions['conversations']).to eq(described_class::Position.new(source: :plan, value: max))
      expect(positions['emails']).to eq(described_class::Position.new(source: :plan, value: nil))
    end
  end

  describe '#apply' do
    before { apply_plan! }

    it 'writes «своё число» as the number and as a mark' do
      result = settings.apply('agents' => 8)

      expect(result.limits).to include('agents' => 8)
      expect(result.marks).to eq('agents' => 8)
    end

    it 'writes «без ограничений» as the number that stands for no limit of that limit' do
      result = settings.apply('agents' => :unlimited, 'storage_bytes' => :unlimited, 'captain_tokens' => :unlimited)

      expect(result.limits).to include('agents' => max, 'storage_bytes' => max * 1.gigabyte, 'captain_tokens' => max * 1_000_000)
      expect(result.marks).to eq('agents' => 'unlimited', 'storage_bytes' => 'unlimited', 'captain_tokens' => 'unlimited')
    end

    it 'writes the number of the plan for «как в тарифе» and takes the mark off' do
      plan_with('agents' => 10)
      account.update!(limits: account.limits.merge('agents' => 8))
      choose('agents' => 8)

      result = settings.apply('agents' => :plan)

      expect(result.limits).to include('agents' => 10)
      expect(result.marks).to eq({})
    end

    it 'takes the number off where the plan has none, so the general value of the platform applies again' do
      account.update!(limits: account.limits.merge('inboxes' => 7))
      choose('inboxes' => 7)

      result = settings.apply('inboxes' => :plan)

      expect(result.limits).not_to have_key('inboxes')
      expect(result.marks).to eq({})
    end

    it 'leaves the limits it is not told about as they are, chosen ones included' do
      account.update!(limits: account.limits.merge('inboxes' => 7, 'agents' => 2))
      choose('inboxes' => 7)

      result = settings.apply('emails' => 100)

      expect(result.limits).to include('inboxes' => 7, 'agents' => 2, 'emails' => 100, 'conversations' => max)
      expect(result.marks).to include('inboxes' => 7, 'emails' => 100)
    end

    it 'keeps the numbers an account from before the list holds, as chosen ones' do
      account.update!(custom_attributes: account.custom_attributes.to_h.except(marks_key), limits: { 'agents' => 3, 'conversations' => 500 })

      result = settings.apply('inboxes' => 4)

      expect(result.marks).to eq('agents' => 3, 'conversations' => 500, 'inboxes' => 4)
    end

    it 'says what changed, with the source and the number before and after' do
      account.update!(limits: account.limits.merge('agents' => 6))
      choose('agents' => 6)

      changes = settings.apply('agents' => :plan, 'inboxes' => 9, 'conversations' => :plan).changes

      expect(changes.keys).to eq(%w[inboxes agents])
      expect(changes['agents']).to eq(
        'from' => described_class::Position.new(source: :custom, value: 6), 'to' => described_class::Position.new(source: :plan, value: nil)
      )
      expect(changes['inboxes']['to']).to eq(described_class::Position.new(source: :custom, value: 9))
    end

    it 'refuses what is not a choice' do
      expect { settings.apply('agents' => -1) }.to raise_error(ArgumentError)
      expect { settings.apply('agents' => 'five') }.to raise_error(ArgumentError)
    end

    it 'ignores a limit that does not exist' do
      expect(settings.apply('nonsense' => 5).limits).not_to have_key('nonsense')
    end

    it 'writes nothing to the account' do
      expect { settings.apply('agents' => 8) }.not_to(change { account.reload.attributes })
    end
  end
end
