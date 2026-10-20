# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuperAdmin::LimitForm do
  let(:max) { ChatwootApp.max_limit }

  def form(account_params)
    described_class.from_params(ActionController::Parameters.new(account_params))
  end

  describe 'the form of the screens (limit_choices and limit_values)' do
    it 'reads the three choices and the number of «своё число»' do
      read = form(limit_choices: { agents: 'custom', inboxes: 'unlimited', emails: 'plan' },
                  limit_values: { agents: '12', inboxes: '9', emails: '5' })

      expect(read).to be_submitted
      expect(read).to be_valid
      expect(read.choices).to eq('agents' => 12, 'inboxes' => :unlimited, 'emails' => :plan)
    end

    it 'only names the limits it was told about' do
      expect(form(limit_choices: { agents: 'plan' }).choices.keys).to eq(['agents'])
    end

    it 'turns gigabytes into bytes, with a comma, a dot or a space' do
      expect(form(limit_choices: { storage_bytes: 'custom' },
                  limit_values: { storage_bytes: '1,5' }).choices).to eq('storage_bytes' => 1.5.gigabytes.to_i)
      expect(form(limit_choices: { storage_bytes: 'custom' }, limit_values: { storage_bytes: ' 50 ' }).choices).to eq('storage_bytes' => 50.gigabytes)
      expect(form(limit_choices: { storage_bytes: 'custom' },
                  limit_values: { storage_bytes: '0.5' }).choices).to eq('storage_bytes' => 0.5.gigabytes.to_i)
      expect(form(limit_choices: { storage_bytes: 'custom' },
                  limit_values: { storage_bytes: '1 000' }).choices).to eq('storage_bytes' => 1000.gigabytes)
    end

    it 'takes a number that big for «без ограничений»' do
      expect(form(limit_choices: { agents: 'custom' }, limit_values: { agents: max.to_s }).choices).to eq('agents' => :unlimited)
      expect(form(limit_choices: { storage_bytes: 'custom' }, limit_values: { storage_bytes: '100000' }).choices).to eq('storage_bytes' => :unlimited)
      expect(form(limit_choices: { storage_bytes: 'custom' },
                  limit_values: { storage_bytes: '99999' }).choices['storage_bytes']).to eq(99_999.gigabytes)
    end

    it 'allows 0' do
      expect(form(limit_choices: { inboxes: 'custom' }, limit_values: { inboxes: '0' }).choices).to eq('inboxes' => 0)
    end

    it 'does not look at the number unless the choice is «своё число»' do
      read = form(limit_choices: { agents: 'plan', inboxes: 'unlimited' }, limit_values: { agents: 'junk', inboxes: '-5' })

      expect(read).to be_valid
    end

    it 'finds the problem and says it in words' do
      read = form(limit_choices: { agents: 'custom', inboxes: 'custom', storage_bytes: 'custom', emails: 'sometimes' },
                  limit_values: { agents: '', inboxes: '2.5', storage_bytes: 'lots' })

      expect(read).not_to be_valid
      expect(read.problems).to eq('agents' => :blank, 'inboxes' => :invalid, 'storage_bytes' => :invalid, 'emails' => :invalid_choice)
      expect(read.message).to eq(
        'Лимит «Каналы»: введите целое число не меньше 0, например 5. ' \
        'Лимит «Операторы»: выбрано «Своё число», но число не указано. ' \
        'Лимит «Хранилище»: введите число гигабайт не меньше 0, например 50 или 1,5. ' \
        'Лимит «Письма в день»: выберите один из трёх вариантов.'
      )
    end

    it 'refuses a negative number, a number in letters, an array, a hash and a very long text' do
      ['-1', 'пять', '1e5', 'NaN', 'Infinity', '1..2', ['5'], { 'a' => '1' }, '9' * 40].each do |value|
        read = form(limit_choices: { agents: 'custom' }, limit_values: { agents: value })

        expect(read.problems).to eq('agents' => :invalid), "#{value.inspect} should be refused"
      end
    end

    it 'keeps what was typed, to draw the form again' do
      read = form(limit_choices: { agents: 'custom', inboxes: 'plan' }, limit_values: { agents: 'lots', inboxes: '3' })

      expect(read.state).to eq('agents' => { 'choice' => 'custom', 'value' => 'lots' }, 'inboxes' => { 'choice' => 'plan', 'value' => '3' })
    end
  end

  describe 'the older form (limits)' do
    it 'takes a number as «своё число» and a blank one or a missing one as «как в тарифе»' do
      read = form(limits: { agents: '12', storage_bytes: '1.5', emails: '', conversations: '0' })

      expect(read).to be_submitted
      expect(read.choices).to eq(
        'inboxes' => :plan, 'agents' => 12, 'conversations' => 0, 'non_web_inboxes' => :plan, 'storage_bytes' => 1.5.gigabytes.to_i,
        'captain_responses' => :plan, 'captain_documents' => :plan, 'captain_tokens' => :plan, 'emails' => :plan
      )
    end

    it 'refuses what is not a number' do
      expect(form(limits: { agents: 'many' }).problems).to eq('agents' => :invalid)
    end

    it 'prefers the new fields when both are sent' do
      read = form(limit_choices: { agents: 'unlimited' }, limits: { agents: '5', inboxes: '3' })

      expect(read.choices).to eq('agents' => :unlimited)
    end
  end

  describe 'a request that says nothing about the limits' do
    it 'is not submitted, and valid' do
      expect(form(name: 'Аккаунт')).not_to be_submitted
      expect(form(name: 'Аккаунт')).to be_valid
      expect(described_class.from_params(nil)).not_to be_submitted
      expect(described_class.from_params('text')).not_to be_submitted
    end
  end
end
