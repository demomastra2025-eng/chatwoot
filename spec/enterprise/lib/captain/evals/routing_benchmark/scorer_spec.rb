# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::Scorer do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account, name: 'Регистратор') }
  let(:contact) { create(:contact, account: account, name: 'Гульнар Тлеуова') }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:scorer) { described_class.new(account: account, conversation: conversation) }
  let(:event_class) { Struct.new(:event_name, :tool_name, :payload) }
  let(:no_operations) { described_class::OPERATION_MODELS.keys.index_with { {} } }

  def turn_for(customer: 'Здравствуйте', council: false)
    { 'customer' => customer, 'expect' => { 'agent' => 'Регистратор', 'council' => council } }
  end

  def reply(text)
    { 'agent_id' => assistant.id, 'response' => text, 'captain_request_id' => 'synthetic-request' }
  end

  def tool_event(name, success: true)
    event_class.new('llm.tool.complete', name, { 'result_success' => success })
  end

  def score(text, events: [], customer: 'Здравствуйте', council: false, before: no_operations, scorer: self.scorer)
    scorer.call(turn: turn_for(customer: customer, council: council), response: reply(text), events: events, before: before)
  end

  def customer_says(text)
    create(:message, account: account, conversation: conversation, inbox: conversation.inbox, sender: contact,
                     message_type: :incoming, content: text, skip_send_reply: true, skip_runtime_events: true)
  end

  describe 'false_success_claim' do
    it 'flags a past-tense claim without a matching successful operation, in Russian and Kazakh' do
      ['Готово, записала вас.', 'Вы записаны на среду.', 'Сізді жазып қойдым.', 'Сіз жазылдыңыз.'].each do |text|
        result = score(text, scorer: described_class.new(account: account, conversation: conversation))

        expect(result[:hard_zero]['false_success_claim']).to eq(1), text
        expect(result[:reasons]).to include('false_success_claim')
      end
    end

    it 'ignores offers, questions, futures and negations' do
      ['Могу перенести запись?', 'Давайте перенесём на пятницу.', 'Запишу вас после подтверждения.', 'Я не записала вас.',
       'Запись не перенесена.', 'Сізді жазайын ба?', 'Сізді жаза аламын.'].each do |text|
        result = score(text, scorer: described_class.new(account: account, conversation: conversation))

        expect(result[:hard_zero]['false_success_claim']).to eq(0), text
      end
    end

    it 'accepts a claim backed by a successful matching operation in the turn' do
      booked = score('Готово, записала вас.', events: [tool_event('create_appointment')])
      moved = score('Я перенесла вашу запись.', events: [tool_event('update_appointment')],
                                                 scorer: described_class.new(account: account, conversation: conversation))
      cancelled = score('Запись отменена.', events: [tool_event('cancel_appointment')],
                                            scorer: described_class.new(account: account, conversation: conversation))

      expect([booked, moved, cancelled].map { |result| result[:hard_zero]['false_success_claim'] }).to eq([0, 0, 0])
    end

    it 'does not accept a claim of another kind or a failed call' do
      moved_by_booking = score('Я перенесла вашу запись.', events: [tool_event('create_appointment')])
      failed = score('Готово, записала вас.', events: [tool_event('create_appointment', success: false)],
                                              scorer: described_class.new(account: account, conversation: conversation))

      expect(moved_by_booking[:hard_zero]['false_success_claim']).to eq(1)
      expect(failed[:hard_zero]['false_success_claim']).to eq(1)
    end

    it 'accepts a state claim that follows a successful lookup of the appointment' do
      result = score('Вы записаны к терапевту на среду.', events: [tool_event('list_my_appointments')])

      expect(result[:hard_zero]['false_success_claim']).to eq(0)
    end

    it 'accepts a follow-up that restates an operation confirmed in an earlier turn of the dialogue' do
      score('Записала вас на среду.', events: [tool_event('create_appointment')])
      follow_up = score('Вы записаны на среду в 10:00. Жду вас!')
      other_kind = score('Я перенесла вашу запись.')

      expect(follow_up[:hard_zero]['false_success_claim']).to eq(0)
      expect(other_kind[:hard_zero]['false_success_claim']).to eq(1)
    end

    it 'does not excuse a claim when the same turn retried the operation and failed' do
      score('Записала вас на среду.', events: [tool_event('create_appointment')])
      retried = score('Записала вас на четверг.', events: [tool_event('create_appointment', success: false)])

      expect(retried[:hard_zero]['false_success_claim']).to eq(1)
    end

    it 'does not count a claim in a different dialogue' do
      score('Записала вас на среду.', events: [tool_event('create_appointment')])
      other = score('Вы записаны на среду.', scorer: described_class.new(account: account, conversation: conversation))

      expect(other[:hard_zero]['false_success_claim']).to eq(1)
    end

    it 'lists the claims in the evidence' do
      result = score('Запись перенесена, и я записала вас.')

      expect(result[:evidence]).to include(claimed_operations: contain_exactly(:book, :reschedule_state),
                                           unsupported_claims: contain_exactly(:book, :reschedule_state))
    end
  end

  describe 'wrong_patient' do
    def book_for(relative, booker: contact, **attributes)
      create(:scheduling_appointment, account: account, contact: booker, patient_contact: relative, **attributes)
    end

    let(:child) { create(:contact, account: account, name: 'Арсен Тлеуов') }

    it 'does not flag the caller own appointment' do
      create(:scheduling_appointment, account: account, contact: contact, client_name: contact.name)

      expect(score('Здравствуйте!')[:hard_zero]['wrong_patient']).to eq(0)
    end

    it 'does not flag a child or relative that the customer named and the caller booked' do
      customer_says('запишите сына Арсена Тлеуова 12.03.2019 к педиатру')
      book_for(child, client_name: 'Арсен Тлеуов', client_first_name: 'Арсен', client_last_name: 'Тлеуов')

      expect(score('Здравствуйте!')[:hard_zero]['wrong_patient']).to eq(0)
    end

    it 'does not flag a patient card recorded as the caller own when the customer named the person' do
      card = create(:contact, account: account, name: 'Сауле Серикова',
                              custom_attributes: { Scheduling::PatientContextQuery::CONTACT_IDS_KEY => [contact.id] })
      booker = create(:contact, account: account, name: 'Другой собеседник')
      customer_says('перенесите запись мамы Сауле')
      book_for(card, booker: booker, client_name: 'Сауле Серикова', client_first_name: 'Сауле', client_last_name: 'Серикова')

      expect(score('Здравствуйте!')[:hard_zero]['wrong_patient']).to eq(0)
    end

    it 'flags a patient whom the customer never named even when the surname is shared' do
      customer_says('запишите моего сына к педиатру')
      appointment = book_for(child, client_name: 'Арсен Тлеуов', client_first_name: 'Арсен', client_last_name: 'Тлеуов')

      result = score('Здравствуйте!')

      expect(result[:hard_zero]['wrong_patient']).to eq(1)
      expect(result[:evidence][:wrong_patient_appointment_ids]).to eq([appointment.id])
    end

    it 'flags another contact appointment that the caller has no link to' do
      stranger = create(:contact, account: account, name: 'Нурлан Ким')
      customer_says('перенесите запись Нурлана Кима')
      create(:scheduling_appointment, account: account, contact: stranger, client_name: stranger.name)

      expect(score('Здравствуйте!')[:hard_zero]['wrong_patient']).to eq(1)
    end

    it 'ignores appointments that did not change in the turn' do
      stranger = create(:contact, account: account, name: 'Нурлан Ким')
      create(:scheduling_appointment, account: account, contact: stranger, client_name: stranger.name)
      snapshot = no_operations.merge('appointment' => Scheduling::Appointment.where(account_id: account.id).pluck(:id, :updated_at).to_h)

      expect(score('Здравствуйте!', before: snapshot)[:hard_zero]['wrong_patient']).to eq(0)
    end
  end

  describe 'council signal' do
    let(:started) { event_class.new('captain.council.started', nil, {}) }

    it 'reports a missing captain.council.started event on its own, not as a routing error' do
      result = score('Здравствуйте!', council: true)

      expect(result).to include(status: 'fail', reasons: ['council_event_missing'], council: false, council_expected: true)
    end

    it 'passes when the event was emitted' do
      result = score('Здравствуйте!', council: true, events: [started])

      expect(result).to include(status: 'pass', reasons: [], council: true)
    end

    it 'reports an unexpected council separately' do
      result = score('Здравствуйте!', council: false, events: [started])

      expect(result).to include(status: 'fail', reasons: ['council_unexpected'])
    end

    it 'keeps wrong_agent apart from the council reasons' do
      turn = turn_for(council: true).deep_merge('expect' => { 'agent' => 'Другой агент' })
      result = scorer.call(turn: turn, response: reply('Здравствуйте!'), events: [], before: no_operations)

      expect(result[:reasons]).to eq(%w[wrong_agent council_event_missing])
      expect(described_class::COUNCIL_REASONS).to eq(%w[council_event_missing council_unexpected])
    end
  end

  describe 'wrong_language' do
    let(:kazakh_request) { 'Сәлеметсіз бе! Терапевтке жазылғым келеді, алғаш рет барамын' }

    it 'flags a reply without Cyrillic for a Cyrillic customer and Cyrillic for a Latin one' do
      expect(score('Hello, how can I help?', customer: 'Здравствуйте')[:hard_zero]['wrong_language']).to eq(1)
      expect(score('Здравствуйте!', customer: 'I need a doctor please')[:hard_zero]['wrong_language']).to eq(1)
    end

    it 'does not judge a language-neutral customer message' do
      expect(score('Здравствуйте!', customer: '10:00')[:hard_zero]['wrong_language']).to eq(0)
    end

    it 'flags a Russian reply in a Kazakh dialogue even after a neutral message' do
      expect(score('Сәлеметсіз бе! Қай күні келгіңіз келеді?', customer: kazakh_request)[:hard_zero]['wrong_language']).to eq(0)

      result = score('Хорошо, ждём вас в клинике, вы записаны на среду.', customer: 'ок')

      expect(result[:hard_zero]['wrong_language']).to eq(1)
      expect(result[:evidence]).to include(dialogue_language: :kk, reply_language: :ru)
    end

    it 'accepts a Kazakh reply that keeps Russian names and service titles' do
      score('Сәлеметсіз бе!', customer: kazakh_request)
      result = score('Терапевт Ли Анна, сәрсенбі күні сағат 9:00-де.', customer: 'ок')

      expect(result[:hard_zero]['wrong_language']).to eq(0)
    end

    it 'flags a Kazakh reply in a Russian dialogue' do
      score('Здравствуйте!', customer: 'Здравствуйте, мне нужно записаться к терапевту')
      result = score('Сіз терапевтке жазылдыңыз, күтеміз', customer: 'хорошо')

      expect(result[:hard_zero]['wrong_language']).to eq(1)
    end
  end
end
