# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Captain suppressed reply guard and outgoing IIN redaction (17.6)', type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:user) { create(:user, account: account, role: :administrator) }

  describe 'Item 3: Captain::PatientIntent actionable_request? and claims_staff_transfer?' do
    it 'treats booking requests, questions, clinic inquiries, human requests and greetings as actionable' do
      [
        'Запишите меня к Кемеровой на завтра',
        'Сколько стоит консультация гинеколога',
        'Есть свободные окошки на пятницу',
        'Здравствуйте!',
        'Соедините с оператором',
        'Завтра в 15:00'
      ].each do |text|
        expect(Captain::PatientIntent.actionable_request?(text)).to be(true), "expected #{text.inspect} to be actionable"
      end
    end

    it 'allows pure courtesy acknowledgements without questions or booking requests to stay non-actionable' do
      ['Спасибо!', 'Рахмет', '👍', 'Хорошо, буду', 'Спасибо, что перенесли'].each do |text|
        expect(Captain::PatientIntent.actionable_request?(text)).to be(false), "expected #{text.inspect} not to be actionable"
      end
    end

    it 'detects staff transfer claims in reasoning or operator_note' do
      expect(Captain::PatientIntent.claims_staff_transfer?('Запрос передан сотруднику клиники')).to be(true)
      expect(Captain::PatientIntent.claims_staff_transfer?('Перевожу диалог на оператора')).to be(true)
      expect(Captain::PatientIntent.claims_staff_transfer?('Transferred to staff for manual handling')).to be(true)
      expect(Captain::PatientIntent.claims_staff_transfer?('Handing off to a human agent')).to be(true)
      expect(Captain::PatientIntent.claims_staff_transfer?('Переключаю диалог на живого оператора')).to be(true)
      expect(Captain::PatientIntent.claims_staff_transfer?('Пациент только поблагодарил.')).to be(false)
    end
  end

  describe 'Item 3: AgentRunnerService blocks unsafe response_mode: suppress without handoff' do
    let(:runner) { Captain::Assistant::AgentRunnerService.new(assistant: assistant) }

    it 'raises unsafe_suppressed_response semantic error on actionable patient request without handoff' do
      runner.instance_variable_set(:@current_patient_text, 'Запишите меня к Кемеровой на завтра')
      error = runner.send(
        :semantic_output_error,
        { 'response' => '', 'response_mode' => 'suppress', 'reasoning' => 'Не удалось найти врача' },
        {},
        handoff_tool_called: false
      )

      expect(error).to be_present
      expect(error.code).to eq('unsafe_suppressed_response')
    end

    it 'raises unsafe_suppressed_response semantic error when reasoning claims transfer to staff without handoff' do
      runner.instance_variable_set(:@current_patient_text, 'Ок')
      error = runner.send(
        :semantic_output_error,
        { 'response' => '', 'response_mode' => 'suppress', 'reasoning' => 'Диалог передан сотруднику' },
        {},
        handoff_tool_called: false
      )

      expect(error).to be_present
      expect(error.code).to eq('unsafe_suppressed_response')
    end

    it 'permits response_mode: suppress on pure courtesy acknowledgement without transfer claim' do
      runner.instance_variable_set(:@current_patient_text, 'Спасибо большое! 👍')
      error = runner.send(
        :semantic_output_error,
        { 'response' => '', 'response_mode' => 'suppress', 'reasoning' => 'Пациент поблагодарил, ответ не нужен' },
        {},
        handoff_tool_called: false
      )

      expect(error).to be_nil
    end
  end

  describe 'Item 3: AgentOutcomeClassifier escalates swallowed actionable requests or staff transfer claims' do
    it 'turns no_reply into human_needed when patient asked a clinic inquiry or note claims staff transfer' do
      trace_collector = instance_double(
        Enterprise::Captain::ReplySuggestionService::TraceCollector,
        suggestion_meta: {},
        captain_trace: {}
      )
      inquiry_outcome = Captain::ReplySuggestion::AgentOutcomeClassifier.new(
        { 'response' => '', 'response_mode' => 'suppress', 'operator_note' => 'Пропуск' },
        trace_collector: trace_collector,
        patient_text: 'Какая цена приема терапевта'
      ).perform
      expect(inquiry_outcome[:outcome]).to eq('human_needed')

      transfer_claim_outcome = Captain::ReplySuggestion::AgentOutcomeClassifier.new(
        { 'response' => '', 'response_mode' => 'suppress', 'operator_note' => 'Обращение передано сотруднику.' },
        trace_collector: trace_collector,
        patient_text: 'Ок'
      ).perform
      expect(transfer_claim_outcome[:outcome]).to eq('human_needed')

      thanks_outcome = Captain::ReplySuggestion::AgentOutcomeClassifier.new(
        { 'response' => '', 'response_mode' => 'suppress', 'operator_note' => 'Пациент поблагодарил.' },
        trace_collector: trace_collector,
        patient_text: 'Спасибо!'
      ).perform
      expect(thanks_outcome[:outcome]).to eq('no_reply')
    end
  end

  describe 'Item 5: outgoing post-LLM IIN redaction across customer and suggestion paths' do
    let(:valid_iin) do
      base = '90010130001'
      weights1 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
      weights2 = [3, 4, 5, 6, 7, 8, 9, 10, 11, 1, 2]
      digits = base.chars.map(&:to_i)
      chk = digits.zip(weights1).sum { |d, w| d * w } % 11
      chk = digits.zip(weights2).sum { |d, w| d * w } % 11 if chk == 10
      "#{base}#{chk == 10 ? 0 : chk}"
    end

    it 'redacts 12-digit personal IINs in AgentRunnerService#guard_public_response while preserving phone numbers' do
      allow(Captain::Safety::CustomRulesRuntime).to receive(:check_output!) { |response:, **| response }
      runner = Captain::Assistant::AgentRunnerService.new(assistant: assistant)

      guarded = runner.send(
        :guard_public_response,
        { 'response' => "Записали вас! Ваш ИИН #{valid_iin}, телефон +7 701 555 01 01." }
      )

      expect(guarded['response']).not_to include(valid_iin)
      expect(guarded['response']).to include('[ИИН СКРЫТ]')
      expect(guarded['response']).to include('+7 701 555 01 01')
    end

    it 'redacts 12-digit personal IINs in Captain::Assistant#render_runtime_text' do
      rendered = assistant.render_runtime_text("Передаю диалог оператору. ИИН пациента: #{valid_iin}")

      expect(rendered).not_to include(valid_iin)
      expect(rendered).to include('[ИИН СКРЫТ]')
    end

    it 'redacts 12-digit personal IINs in Captain::ReplySuggestionService#legacy_draft' do
      allow(Captain::ReplySuggestion::DraftClaims).to receive(:check).and_return(:ok)
      inbox = create(:inbox, account: account)
      conversation = create(:conversation, account: account, inbox: inbox)
      service = Captain::ReplySuggestionService.new(
        account: account,
        conversation_display_id: conversation.display_id,
        conversation: conversation,
        user: user
      )

      outcome = service.send(:legacy_draft, { message: "Здравствуйте! Проверили ваш ИИН #{valid_iin}, запись активна." })

      expect(outcome[:outcome]).to eq('draft')
      expect(outcome[:message]).not_to include(valid_iin)
      expect(outcome[:message]).to include('[ИИН СКРЫТ]')
    end
  end
end
