# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::PiiSessionPseudonymizer do
  let(:account) { create(:account, name: 'Клиника Достар Мед') }
  let(:other_account) { create(:account, name: 'Другая Клиника') }
  let(:contact) do
    create(
      :contact,
      account: account,
      name: 'Айгерим',
      last_name: 'Ахметова',
      middle_name: 'Сериковна',
      phone_number: '+77015556677'
    )
  end
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }

  before do
    create(:scheduling_resource, account: account, name: 'Иванов Петр Сергеевич')
    create(:scheduling_service, account: account, name: 'УЗИ брюшной полости')
    described_class.clear_whitelist_cache!
  end

  # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
  it 'masks patient FIO (even when sharing a patronymic with a doctor), phones, and IINs while keeping clinic doctors and services' do
    intro_text = [
      'Здравствуйте! Меня зовут Оспанова Динара Сергеевна, мой номер 8 (701) 555-66-77,',
      'ИИН 950412400123. Запишите меня на УЗИ брюшной полости к Иванову Петру Сергеевичу в Алматы.'
    ].join(' ')
    payload = {
      model: 'openai/gpt-6-luna',
      messages: [
        { role: 'user', content: intro_text },
        { role: 'user', content: 'Также со мной придёт муж Нурлан Сергеевич, телефон +7 707 888 99 00.' }
      ],
      tools: [
        {
          type: 'function',
          function: {
            name: 'create_appointment',
            description: 'Создать запись пациента Иванова Петра в MedElement'
          }
        }
      ]
    }

    redacted = nil
    Llm::IinTokenVault.with_scope(account_id: account.id, scope_id: "conv:#{conversation.id}") do
      described_class.with_scope(account_id: account.id, scope_id: "conv:#{conversation.id}", conversation: conversation) do
        redacted = Llm::OutboundIinRedactor.redact_payload(payload)
        msg1 = redacted[:messages][0][:content]
        msg2 = redacted[:messages][1][:content]

        expect(msg1).not_to include('Оспанова')
        expect(msg1).not_to include('Динара')
        expect(msg1).not_to include('555-66-77')
        expect(msg1).not_to include('950412400123')
        expect(msg1).to match(/\[PII_NAME_[0-9A-F]{8}\]/)
        expect(msg1).to match(/\[PII_PHONE_[0-9A-F]{8}\]/)
        expect(msg1).to match(/\[IIN_TOKEN_[0-9A-F]{10}\]/)

        expect(msg1).to include('УЗИ брюшной полости')
        expect(msg1).to include('Иванову Петру Сергеевичу')
        expect(msg1).to include('Алматы')

        expect(msg2).not_to include('Нурлан Сергеевич')
        expect(msg2).not_to include('888 99 00')
        expect(msg2).to match(/\[PII_NAME_[0-9A-F]{8}\]/)
        expect(msg2).to match(/\[PII_PHONE_[0-9A-F]{8}\]/)
        expect(redacted[:tools][0][:function][:name]).to eq('create_appointment')

        name_token = msg1[/\[PII_NAME_[0-9A-F]{8}\]/]
        husband_token = msg2[/\[PII_NAME_[0-9A-F]{8}\]/]
        phone_token = msg1[/\[PII_PHONE_[0-9A-F]{8}\]/]
        iin_token = msg1[/\[IIN_TOKEN_[0-9A-F]{10}\]/]

        raw_tool_args = { client_name: name_token, client_phone: phone_token, iin: iin_token }
        detokenized_tool_args = described_class.unmask_deep(Llm::IinTokenVault.detokenize_deep(raw_tool_args))
        expect(detokenized_tool_args[:client_name]).to include('Оспанова Динара Сергеевна')
        expect(detokenized_tool_args[:client_phone]).to eq('+77015556677')
        expect(detokenized_tool_args[:iin]).to eq('950412400123')

        unmasked_husband = described_class.unmask_deep({ first_name: husband_token, last_name: husband_token })
        assistant = instance_double(Captain::Assistant, id: 1, account_id: account.id, account: account)
        booking_ctx = Captain::Tools::Agent::PatientBookingContext.new(
          assistant: assistant, conversation: conversation, patient: unmasked_husband
        )
        expect(booking_ctx.send(:patient)[:first_name]).to eq('Нурлан')
        expect(booking_ctx.send(:patient)[:last_name]).to eq('Сергеевич')

        customer_out = Scheduling::IinValidator.redact_customer_text(
          "Готово, #{name_token}! Номер #{phone_token}, ИИН #{iin_token}, чужой [PII_NAME_DEADBEEF]."
        )
        expect(customer_out).to include('Оспанова Динара Сергеевна')
        expect(customer_out).to include('+77015556677')
        expect(customer_out).to include('[ИИН СКРЫТ]')
        expect(customer_out).not_to include('DEADBEEF')
        expect(customer_out).to include('[СКРЫТО]')
      end
    end

    token_from_msg = redacted[:messages][0][:content][/\[PII_NAME_[0-9A-F]{8}\]/]
    described_class.with_scope(account_id: other_account.id, scope_id: "conv:#{conversation.id}") do
      expect(described_class.unmask_text(token_from_msg)).to eq(token_from_msg)
      expect(described_class.unmask_customer_text(token_from_msg)).to eq('[СКРЫТО]')
    end
  end
  # rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
end
