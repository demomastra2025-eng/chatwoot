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

      it 'calls a number that is neither the plan one nor the one the plan wrote «своё число»' do
        account.update!(limits: account.limits.merge('agents' => 3))

        expect(settings.source('agents')).to eq(:custom)
        expect(settings.custom_value('agents')).to eq(3)
      end

      it 'calls a number an account from before the lists holds «своё число» as well, and reads nothing it never wrote' do
        account.update!(custom_attributes: account.custom_attributes.to_h.except(*described_class::ATTRIBUTE_KEYS), limits: { 'agents' => 3 })

        expect(settings.source('agents')).to eq(:custom)
        expect(account.reload.custom_attributes).not_to include(*described_class::ATTRIBUTE_KEYS)
      end

      it 'calls the number the plan wrote and has changed since an older number of the plan, until the plan is applied again' do
        plan_with('agents' => 20)

        expect(settings.source('agents')).to eq(:plan)
        expect(settings.effective('agents')).to eq(10) # what the code enforces until the plan is applied again
        expect(settings.plan_value('agents')).to eq(20)
      end

      it 'does not take the number the plan wrote for a number of the plan once the plan has none for the limit any more' do
        plan_with('agents' => nil)

        expect(settings.source('agents')).to eq(:custom)
      end
    end

    # The first plan an old account gets after the deploy has no number for the limit; a number somebody typed there stays his, however
    # the plan changes later
    context 'when the plan gets a number for a limit where an account holds a number of its own' do
      before do
        account.update!(limits: { 'agents' => 10, 'conversations' => max, 'non_web_inboxes' => max },
                        custom_attributes: { 'plan' => 'base', 'plan_modules' => [], 'plan_version' => 2 })
      end

      it 'keeps the number as «своё число» through the first plan, the new number of the plan and the next plan' do
        expect(settings.source('agents')).to eq(:custom)
        apply_plan!
        expect(settings.source('agents')).to eq(:custom)

        plan_with('agents' => 5)
        expect(settings.source('agents')).to eq(:custom)
        apply_plan!

        expect(account.reload.limits['agents']).to eq(10)
        expect(settings.source('agents')).to eq(:custom)
        expect(account.custom_attributes[described_class::PLAN_NUMBERS_KEY]).not_to include('agents')
      end

      it 'follows the plan again once the number of the plan is the very number it holds' do
        plan_with('agents' => 10)

        expect(settings.source('agents')).to eq(:plan)
      end
    end

    # An account whose plan was applied before the numbers of the plan were kept holds what the plans of that time wrote: 100 000 for
    # conversations and main channels. The file may get a number for them before anybody applies the plan to the account again.
    context 'when the plan of the account was applied before the numbers of the plan were kept' do
      before do
        account.update!(limits: { 'conversations' => max, 'non_web_inboxes' => max, 'agents' => 7, 'inboxes' => max },
                        custom_attributes: { 'plan' => 'base', 'plan_modules' => [], 'plan_version' => 2 })
      end

      it 'has a table of what those plans wrote: the number of no limit, for the two limits they set' do
        expect(described_class::LEGACY_PLAN_NUMBERS).to eq('conversations' => max, 'non_web_inboxes' => max).and be_frozen
      end

      it 'follows the plan while the file says unlimited, as before' do
        expect(settings.source('conversations')).to eq(:plan)
        expect(settings.source('non_web_inboxes')).to eq(:plan)
      end

      it 'keeps following the plan when the file gives the limit a number, and says what the plan writes', :aggregate_failures do
        plan_with('conversations' => 2000)

        expect(settings.source('conversations')).to eq(:plan)
        expect(settings.choice('conversations')).to eq(:plan)
        expect(settings.effective('conversations')).to eq(max) # what the code enforces until the plan is applied
        expect(settings.plan_value('conversations')).to eq(2000)
        expect(settings.following_plan_numbers).to include('conversations' => 2000, 'non_web_inboxes' => max)
      end

      it 'reads any other number as «своё число», and the limits the old plans never wrote as well', :aggregate_failures do
        plan_with('conversations' => 2000, 'inboxes' => 20)
        account.update!(limits: account.limits.merge('conversations' => 300))

        expect(settings.source('conversations')).to eq(:custom)
        expect(settings.source('inboxes')).to eq(:unlimited) # 100 000 channels was never written by a plan
        expect(settings.source('agents')).to eq(:custom)
      end

      it 'is not read for an account that has no plan, nor for a limit with a number kept beside the list', :aggregate_failures do
        plan_with('conversations' => 2000)
        account.update!(custom_attributes: { described_class::PLAN_NUMBERS_KEY => { 'conversations' => 1000 } })
        expect(settings.source('conversations')).to eq(:unlimited) # no plan, nothing to follow

        account.update!(custom_attributes: { 'plan' => 'base', described_class::PLAN_NUMBERS_KEY => { 'conversations' => 1000 } })
        expect(settings.source('conversations')).to eq(:unlimited) # the plan wrote 1000 last: 100 000 is not its number
        expect(settings.source('non_web_inboxes')).to eq(:plan)    # nothing is kept for this one: the table is read
      end

      it 'does not take a limit chosen by hand for the plan' do
        plan_with('conversations' => 2000)
        choose('conversations' => 'unlimited', 'non_web_inboxes' => max)

        expect(settings.source('conversations')).to eq(:unlimited)
        expect(settings.source('non_web_inboxes')).to eq(:custom)
      end

      it 'keeps following the plan after another row has been saved, even one that follows the plan and so keeps its number', :aggregate_failures do
        plan_with('non_web_inboxes' => 50, 'conversations' => 2000)
        result = settings.apply('non_web_inboxes' => :plan, 'agents' => 3)
        account.update!(limits: result.limits, custom_attributes: result.custom_attributes(account.custom_attributes))

        expect(account.reload.custom_attributes[described_class::PLAN_NUMBERS_KEY]).to eq('non_web_inboxes' => 50)
        expect(settings.source('conversations')).to eq(:plan)
        expect(settings.source('non_web_inboxes')).to eq(:plan)
        expect(settings.source('agents')).to eq(:custom)
      end

      it 'writes nothing in #apply for a row that follows the plan and only waits for the plan to be applied' do
        plan_with('conversations' => 2000)

        result = settings.apply('conversations' => :plan)

        expect(result.changes).to be_empty
        expect(result.limits).to include('conversations' => max)
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

    it 'remembers the number the plan writes for «как в тарифе», and forgets it for the other choices' do
      plan_with('agents' => 10, 'emails' => 100)
      account.update!(limits: account.limits.merge('agents' => 8, 'emails' => 100),
                      custom_attributes: account.custom_attributes.merge(marks_key => { 'agents' => 8 },
                                                                         described_class::PLAN_NUMBERS_KEY => { 'emails' => 100 }))

      result = settings.apply('agents' => :plan, 'emails' => 30)

      expect(result.limits).to include('agents' => 10, 'emails' => 30)
      expect(result.plan_numbers).to eq('agents' => 10)
    end

    it 'leaves the limits it is not told about as they are, chosen ones included' do
      account.update!(limits: account.limits.merge('inboxes' => 7, 'agents' => 2))
      choose('inboxes' => 7)

      result = settings.apply('emails' => 100)

      expect(result.limits).to include('inboxes' => 7, 'agents' => 2, 'emails' => 100, 'conversations' => max)
      expect(result.marks).to include('inboxes' => 7, 'emails' => 100)
    end

    it 'lists only what was chosen: the numbers an account from before the lists holds are read as chosen without being listed' do
      account.update!(custom_attributes: account.custom_attributes.to_h.except(*described_class::ATTRIBUTE_KEYS),
                      limits: { 'agents' => 3, 'conversations' => 500 })

      result = settings.apply('inboxes' => 4)

      expect(result.marks).to eq('inboxes' => 4)
      expect(result.limits).to eq('agents' => 3, 'conversations' => 500, 'inboxes' => 4)
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

  # The form of the screens sends every row, the ones nobody touched included: those must change nothing
  describe 'a choice that says what the limit already is' do
    before { apply_plan! }

    it 'is the same for «как в тарифе» on a limit that follows the plan, whatever number it holds' do
      expect(settings.same_choice?('conversations', :plan)).to be(true)
      expect(settings.same_choice?('conversations', :unlimited)).to be(false)
      expect(settings.same_choice?('conversations', 50)).to be(false)
    end

    it 'is the same for «без ограничений» and for the number of «своё число»' do
      choose('agents' => 'unlimited', 'inboxes' => 4)
      account.update!(limits: account.limits.merge('agents' => max, 'inboxes' => 4))

      expect(settings.same_choice?('agents', :unlimited)).to be(true)
      expect(settings.same_choice?('agents', :plan)).to be(false)
      expect(settings.same_choice?('inboxes', 4)).to be(true)
      expect(settings.same_choice?('inboxes', 5)).to be(false)
      expect(settings.same_choice?('inboxes', :unlimited)).to be(false)
    end

    it 'is the same for a storage size that is the same at the precision of the field (gigabytes with two decimals)' do
      account.update!(limits: account.limits.merge('storage_bytes' => 5_000_000_000))

      expect(settings.source('storage_bytes')).to eq(:custom)
      expect(settings.same_choice?('storage_bytes', (BigDecimal('4.66') * 1.gigabyte).round(0).to_i)).to be(true)
      expect(settings.same_choice?('storage_bytes', (BigDecimal('4.67') * 1.gigabyte).round(0).to_i)).to be(false)
      expect(settings.same_choice?('storage_bytes', 5_000_000_000)).to be(true)
    end

    it 'is never the same for something that is no choice (it is refused by #apply)' do
      expect(settings.same_choice?('agents', 'five')).to be(false)
      expect { settings.apply('agents' => 'five') }.to raise_error(ArgumentError)
    end

    it 'leaves a zero that an ended trial put on a limit, and says nothing changed' do
      account.update!(limits: account.limits.merge('agents' => 5, 'inboxes' => 3))
      account.reload.activate_trial!(3)
      account.expire_trial!
      expect(account.reload.limits).to include('agents' => 0, 'inboxes' => 0)

      result = settings.apply('agents' => :plan, 'inboxes' => :plan, 'emails' => 50)

      expect(result.limits).to include('agents' => 0, 'inboxes' => 0, 'emails' => 50)
      expect(result.changes.keys).to eq(['emails'])
    end

    it 'leaves the number of the plan that the plan has changed since, until somebody chooses something else' do
      plan_with('conversations' => 1000)

      result = settings.apply('conversations' => :plan, 'agents' => :plan)

      expect(result.limits).to include('conversations' => max)
      expect(result.changes).to be_empty
      expect(result.marks).to eq({})
    end

    it 'leaves a number a partner wrote, which is a number of its own for the account' do
      account.update!(limits: account.limits.merge('conversations' => 1000))

      expect(settings.source('conversations')).to eq(:custom)
      result = settings.apply('conversations' => 1000)

      expect(result.changes).to be_empty
      expect(result.limits).to include('conversations' => 1000)
      expect(result.marks).to eq({})
    end

    it 'leaves a storage size of odd bytes when the form sends the number as it shows it' do
      account.update!(limits: account.limits.merge('storage_bytes' => 5_000_000_000))

      result = settings.apply('storage_bytes' => (BigDecimal('4.66') * 1.gigabyte).round(0).to_i)

      expect(result.limits['storage_bytes']).to eq(5_000_000_000)
      expect(result.changes).to be_empty
    end

    it 'changes the limit as soon as the choice is a different one, a zero of a trial and a drifted plan number included' do
      plan_with('conversations' => 1000)

      result = settings.apply('conversations' => :unlimited)

      expect(result.limits['conversations']).to eq(max)
      expect(result.marks).to eq('conversations' => 'unlimited')
      expect(result.changes.keys).to eq(['conversations'])
    end
  end

  describe '#following_plan_numbers' do
    it 'lists the numbers of the plan that the limits following it hold, and nothing for the limits chosen by hand or left alone' do
      plan_with('agents' => 10, 'emails' => 100)
      apply_plan!
      choose('emails' => 30)
      account.update!(limits: account.limits.merge('emails' => 30))

      expect(settings.following_plan_numbers).to eq('conversations' => max, 'non_web_inboxes' => max, 'agents' => 10)
    end

    it 'is empty for an account without a plan' do
      expect(settings.following_plan_numbers).to eq({})
    end
  end

  describe 'Result#custom_attributes' do
    before { apply_plan! }

    it 'sets the two lists beside the other attributes, and does not store an empty one' do
      account.update!(custom_attributes: account.custom_attributes.merge('crm_id' => '7'))

      result = settings.apply('agents' => 8)
      attributes = result.custom_attributes(account.custom_attributes)

      expect(attributes).to include('crm_id' => '7', 'plan' => 'base', marks_key => { 'agents' => 8 })
      expect(attributes[described_class::PLAN_NUMBERS_KEY]).to eq('conversations' => max, 'non_web_inboxes' => max)
      expect(settings.apply('agents' => :plan).custom_attributes(attributes)).not_to have_key(marks_key)
    end

    it 'keeps the attributes it is given untouched' do
      attributes = account.reload.custom_attributes

      settings.apply('agents' => 8).custom_attributes(attributes)

      expect(attributes).not_to have_key(marks_key)
    end
  end
end
