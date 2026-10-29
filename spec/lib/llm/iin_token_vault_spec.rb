# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::IinTokenVault do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:valid_adult_iin) { '940720300129' }
  let(:valid_child_iin) do
    base = '18051550012'
    digits = base.chars.map(&:to_i)
    w1 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    w2 = [3, 4, 5, 6, 7, 8, 9, 10, 11, 1, 2]
    chk = w1.each_with_index.sum { |w, i| digits[i] * w } % 11
    chk = w2.each_with_index.sum { |w, i| digits[i] * w } % 11 if chk == 10
    "#{base}#{chk == 10 ? 0 : chk}"
  end
  let(:invalid_checksum_iin) { '940720300120' }

  describe 'outbound LLM tokenization and strict scope isolation' do
    it 'replaces 12-digit IINs with deterministic per-scope [IIN_TOKEN_...] placeholders and never exposes raw digits' do
      described_class.with_scope(account_id: account.id, scope_id: 'conv:101') do
        payload = {
          model: 'openai/gpt-6-luna',
          messages: [{ role: 'user', content: "Мой ИИН #{valid_adult_iin}, телефон +7 701 123 45 67" }]
        }

        content = Llm::OutboundIinRedactor.redact_payload(payload).dig(:messages, 0, :content)
        expect(content).not_to include(valid_adult_iin)
        expect(content).to include('+7 701 123 45 67')
        expect(content).to match(described_class::TOKEN_PATTERN)

        token_in_conv = content[described_class::TOKEN_PATTERN]
        expect(Llm::OutboundIinRedactor.redact_text("Повторяю: #{valid_adult_iin}")).to eq("Повторяю: #{token_in_conv}")
        expect(described_class.detokenize_text(token_in_conv)).to eq(valid_adult_iin)
      end
    end

    it 'blocks detokenization outside a vault, in another conversation, or in another tenant account' do
      token_in_conv = described_class.with_scope(account_id: account.id, scope_id: 'conv:101') do
        described_class.tokenize(valid_adult_iin)
      end

      expect(Llm::OutboundIinRedactor.redact_text("ИИН #{valid_adult_iin}")).to eq('ИИН [ИИН СКРЫТ]')
      expect(described_class.detokenize_text(token_in_conv)).to eq(token_in_conv)

      described_class.with_scope(account_id: account.id, scope_id: 'conv:202') do
        expect(described_class.detokenize_text(token_in_conv)).to eq(token_in_conv)
      end

      described_class.with_scope(account_id: other_account.id, scope_id: 'conv:101') do
        expect(described_class.detokenize_text(token_in_conv)).to eq(token_in_conv)
      end
    end

    it 'persists encrypted token mappings across separate turns of the same conversation via Redis' do
      token_turn1 = nil

      described_class.with_scope(account_id: account.id, scope_id: 'conv:777') do
        token_turn1 = Llm::OutboundIinRedactor.redact_text(valid_adult_iin)
        expect(token_turn1).to match(described_class::TOKEN_PATTERN)
      end

      # Simulate Turn 2 in a fresh thread/request memory map for the same (account_id, conv:777)
      described_class.with_scope(account_id: account.id, scope_id: 'conv:777') do
        expect(described_class.current_scope[:memory]).to be_empty
        expect(described_class.detokenize_text(token_turn1)).to eq(valid_adult_iin)
      end
    end

    it 'tokenizes labeled 12-digit IINs with a checksum typo so raw digits never leak, while preserving validation failure on tool call' do
      inbox = create(:inbox, account: account)
      contact = create(:contact, account: account, name: 'Aigerim', phone_number: '+77015554433')
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact)
      assistant = create(:captain_assistant, account: account)

      described_class.with_scope(account_id: account.id, scope_id: described_class.conversation_scope_id(conversation)) do
        masked = Llm::OutboundIinRedactor.redact_text("ИИН: #{invalid_checksum_iin}")
        expect(masked).not_to include(invalid_checksum_iin)
        bad_token = masked[described_class::TOKEN_PATTERN]
        expect(bad_token).to be_present

        ctx = Struct.new(:state, :context).new({ conversation: { id: conversation.id } }, {})
        adapter = Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: 'update_my_contact')
        raw_res = adapter.execute(ctx, iin: bad_token)
        parsed = raw_res.is_a?(String) ? JSON.parse(raw_res) : raw_res.with_indifferent_access
        expect(parsed['success']).to be(false)
        expect(parsed['reason']).to eq('validation_error')
      end
    end
  end

  describe 'end-to-end tool detokenization for clinic workflows' do
    let(:user) { create(:user, account: account, role: :administrator) }
    let(:inbox) { create(:inbox, account: account) }
    let(:contact) { create(:contact, account: account, name: 'Алия', last_name: 'Серикова', phone_number: '+77017778899') }
    let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
    let(:assistant) { create(:captain_assistant, account: account) }

    it 'saves the real 12-digit IIN via UpdateMyContactService and returns a tokenized IIN to the LLM' do
      described_class.with_scope(account_id: account.id, scope_id: described_class.conversation_scope_id(conversation)) do
        patient_msg_for_llm = Llm::OutboundIinRedactor.redact_text("Мой ИИН #{valid_adult_iin}")
        token = patient_msg_for_llm[described_class::TOKEN_PATTERN]
        expect(token).to be_present

        ctx = Struct.new(:state, :context).new({ conversation: { id: conversation.id } }, {})
        adapter = Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: 'update_my_contact')
        res = adapter.execute(ctx, iin: token)
        parsed = res.is_a?(String) ? JSON.parse(res) : res.with_indifferent_access

        expect(parsed['success']).to be(true)
        # LLM receives tokenized IIN, never raw 12 digits
        expect(res.to_s).not_to include(valid_adult_iin)
        expect(parsed.dig('contact', 'iin')).to eq(token)

        # Database holds the real 12-digit IIN for clinic staff and MedElement
        contact.reload
        expect(contact.identifier).to eq(valid_adult_iin)
        expect(contact.custom_attributes['iin']).to eq(valid_adult_iin)
      end
    end

    it 'writes the real 12-digit IIN into internal staff notes via AddPrivateNoteService while re-tokenizing the tool result' do
      described_class.with_scope(account_id: account.id, scope_id: described_class.conversation_scope_id(conversation)) do
        token = described_class.tokenize(valid_adult_iin)
        tool = Captain::Tools::Account::AddPrivateNoteService.new(assistant, user: user, conversation: conversation)

        res = tool.execute(note: "Больничный лист: Алия Серикова, ИИН #{token}")
        expect(res.to_s).not_to include(valid_adult_iin)
        expect(res.to_s).to include(token)

        saved_note = conversation.messages.where(private: true).order(:id).last
        expect(saved_note.content).to eq("Больничный лист: Алия Серикова, ИИН #{valid_adult_iin}")
      end
    end

    it 'creates a child patient card with the real 12-digit child IIN when booking for a child' do
      described_class.with_scope(account_id: account.id, scope_id: described_class.conversation_scope_id(conversation)) do
        child_token = described_class.tokenize(valid_child_iin)
        detokenized_patient = described_class.detokenize_deep(
          { first_name: 'Алихан', last_name: 'Сериков', birth_date: '2018-05-15', iin: child_token }
        )

        booking_ctx = Captain::Tools::Agent::PatientBookingContext.new(
          assistant: assistant,
          conversation: conversation,
          patient: detokenized_patient
        ).perform

        child_card = account.contacts.find(booking_ctx[:patient_contact_id])
        expect([child_card.identifier, child_card.custom_attributes['iin']]).to include(valid_child_iin)
      end
    end

    it 'strips both raw IINs and [IIN_TOKEN_...] placeholders from customer-facing outgoing messages' do
      described_class.with_scope(account_id: account.id, scope_id: 'conv:999') do
        token = described_class.tokenize(valid_adult_iin)
        leaked_reply = "Вы записаны! Ваш токен #{token} и ИИН #{valid_adult_iin}."

        cleaned = Scheduling::IinValidator.redact_customer_text(leaked_reply)
        expect(cleaned).not_to include(token)
        expect(cleaned).not_to include(valid_adult_iin)
        expect(cleaned).to eq('Вы записаны! Ваш токен [ИИН СКРЫТ] и ИИН [ИИН СКРЫТ].')
      end
    end

    it 'returns tokenized identifier and custom_attributes[iin] from GetContactService inside a vault and hides them outside' do
      contact.update!(identifier: valid_adult_iin, custom_attributes: { 'iin' => valid_adult_iin, 'city' => 'Almaty' })
      tool = Captain::Tools::Account::GetContactService.new(assistant, user: user, conversation: conversation)

      outside = JSON.parse(tool.execute(contact_id: contact.id))
      expect(outside.dig('contact', 'identifier')).to be_nil
      expect(outside.dig('contact', 'custom_attributes')).to eq('city' => 'Almaty')

      described_class.with_scope(account_id: account.id, scope_id: described_class.conversation_scope_id(conversation)) do
        token = described_class.tokenize(valid_adult_iin)
        inside_raw = tool.execute(contact_id: contact.id)
        expect(inside_raw).not_to include(valid_adult_iin)
        inside = JSON.parse(inside_raw)
        expect(inside.dig('contact', 'identifier')).to eq(token)
        expect(inside.dig('contact', 'custom_attributes')).to eq('iin' => token, 'city' => 'Almaty')
      end
    end

    it 'refuses to detokenize arguments for external HTTP, MCP, script and web tools (P0-3)' do
      expect(described_class.detokenizable_tool?(Captain::Tools::Account::UpdateMyContactService)).to be(true)
      expect(described_class.detokenizable_tool?(Captain::Tools::Account::CustomHttpTool)).to be(false)
      expect(described_class.detokenizable_tool?(Captain::Tools::CustomHttpTool)).to be(false)
      expect(described_class.detokenizable_tool?(Captain::Tools::McpTool)).to be(false)
      expect(described_class.detokenizable_tool?(Captain::Tools::Account::McpTool)).to be(false)
      expect(described_class.detokenizable_tool?(Captain::Tools::SkillScriptTool)).to be(false)
      expect(described_class.detokenizable_tool?(Captain::Tools::Account::WebSearchService)).to be(false)
    end

    it 'propagates vault scope across multi-threaded Council ThreadScope workers and re-tokenizes unlabeled invalid-checksum digits' do
      described_class.with_scope(account_id: account.id, scope_id: described_class.conversation_scope_id(conversation)) do
        typo_token = Llm::OutboundIinRedactor.redact_text("ИИН: #{invalid_checksum_iin}")[described_class::TOKEN_PATTERN]
        expect(Llm::OutboundIinRedactor.redact_text("Ошибка в #{invalid_checksum_iin}")).to eq("Ошибка в #{typo_token}")

        captured = Captain::Runtime::Council::ThreadScope.capture
        worker_resolved = Thread.new { captured.run { described_class.detokenize_text(typo_token) } }.value
        expect(worker_resolved).to eq(invalid_checksum_iin)
      end
    end
  end
end
