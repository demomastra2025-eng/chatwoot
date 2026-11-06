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

  it 'masks inflected FIO, single first names, and non-suffix surnames while keeping doctor context' do
    Llm::PiiNameLexicon.clear_cache!
    Llm::IinTokenVault.with_scope(account_id: account.id, scope_id: "conv:#{conversation.id}") do
      described_class.with_scope(account_id: account.id, scope_id: "conv:#{conversation.id}", conversation: conversation) do
        expect(Llm::OutboundIinRedactor.redact_text('Запишите Серика Оспанова на завтра')).not_to include('Оспанова')
        expect(Llm::OutboundIinRedactor.redact_text('Здравствуйте Айгуль Сейтова хотела записаться')).not_to include('Сейтова')
        expect(Llm::OutboundIinRedactor.redact_text('Это Айжан, можно на завтра к лору?')).not_to include('Айжан')
        expect(Llm::OutboundIinRedactor.redact_text('ИИН ребенка 190825 501 234')).not_to include('190825')
        expect(Llm::OutboundIinRedactor.redact_text('Дәрігер Сейітова қашан қабылдайды?')).to include('Сейітова')

        kim_redacted = Llm::OutboundIinRedactor.redact_text('Запишите Ким Анна на УЗИ')
        expect(kim_redacted).not_to include('Ким')
        expect(kim_redacted).not_to include('Анна')
        kim_token = kim_redacted[/\[PII_NAME_[0-9A-F]{8}\]/]

        unmasked_kim = described_class.unmask_deep({ first_name: kim_token, last_name: kim_token })
        assistant = instance_double(Captain::Assistant, id: 1, account_id: account.id, account: account)
        booking_ctx = Captain::Tools::Agent::PatientBookingContext.new(
          assistant: assistant, conversation: conversation, patient: unmasked_kim
        )
        expect(booking_ctx.send(:patient)[:first_name]).to eq('Анна')
        expect(booking_ctx.send(:patient)[:last_name]).to eq('Ким')
      end
    end
  end

  it 'handles lower/UPPER/TitleCase RU/KK/LAT self-introductions, hyphenated foreign names, and preserves doctor and product negatives' do
    described_class.with_scope(account_id: account.id, scope_id: "conv:#{conversation.id}", conversation: conversation) do
      expect(described_class.mask_text('My name is JOHN SMITH')).to match(/\[PII_NAME_[0-9A-F]{8}\]/)
      expect(described_class.mask_text('my name is john smith')).to match(/\[PII_NAME_[0-9A-F]{8}\]/)
      expect(described_class.mask_text('My name is John Smith')).to match(/\[PII_NAME_[0-9A-F]{8}\]/)
      expect(described_class.mask_text('меня зовут иван петров')).to match(/\[PII_NAME_[0-9A-F]{8}\]/)
      expect(described_class.mask_text('МЕНЯ ЗОВУТ ИВАН ПЕТРОВ')).to match(/\[PII_NAME_[0-9A-F]{8}\]/)
      expect(described_class.mask_text('Пациент Айгүл Сейтова')).to match(/\[PII_NAME_[0-9A-F]{8}\]/)
      expect(described_class.mask_text('Patient name Anne-Marie Smith')).to match(/\[PII_NAME_[0-9A-F]{8}\]/)

      expect(described_class.mask_text('Can Doctor John Smith see me?')).to eq('Can Doctor John Smith see me?')
      expect(described_class.mask_text('Dr John Smith')).to eq('Dr John Smith')
      expect(described_class.mask_text('Дәрігер Сейітова қашан қабылдайды?')).to eq('Дәрігер Сейітова қашан қабылдайды?')
      expect(described_class.mask_text('Можно записать ребёнка 7 лет к травматологу-ортопеду Жумабеку Жанибеку?'))
        .to include('Жумабеку Жанибеку')
      expect(described_class.mask_text('Open John Smith Report')).to eq('Open John Smith Report')
      expect(described_class.mask_text('У меня Samsung Galaxy')).to eq('У меня Samsung Galaxy')
    end

    cache = described_class.instance_variable_get(:@seeded_pattern_cache)
    expect(cache).to be_empty
  end

  it 'enforces shadow audit kill-switch, deduplication, ZDR provider routing, hostile-decider quarantine, and tenant/key isolation' do
    Llm::PiiShadowAuditor.reset_stats!
    Llm::PiiNameLexicon.clear_cache!

    # 1. Kill-switch OFF blocks already-enqueued job execution
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('PII_SHADOW_AUDIT_ENABLED').and_return('false')
    expect(Llm::OpenRouterDecisionClient).not_to receive(:choose)
    res_off = Llm::PiiShadowAuditJob.new.perform('Алгоритмическая проверка', account_id: account.id)
    expect(res_off[:status]).to eq(:disabled)

    # 2. Provider request compilation for standard / sensitive / zdr_required without HTTP
    %w[standard sensitive zdr_required].each do |prof|
      opts = Llm::PiiShadowAuditor.compile_decision_request_options(
        account_id: account.id, account: account, privacy_profile: prof
      )
      expect(opts[:provider][:data_collection]).to eq('deny')
      expect(opts[:provider][:zdr]).to be(true)
      expect(opts[:provider][:allow_fallbacks]).to eq(prof != 'zdr_required')
      expect(opts[:privacy_profile]).to eq(prof)
    end

    # 3. Hostile decider answer (overall=clean or unverified) is quarantined and never poisons active lexicon or other tenants
    allow(ENV).to receive(:[]).with('PII_SHADOW_AUDIT_ENABLED').and_return('true')
    contradictory_client = Class.new do
      def self.choose(questions:, **)
        ans = questions.to_h do |k, _|
          [k, OpenStruct.new(choice: k == 'overall' ? 'clean' : 'patient_last_name', confidence: 0.99)]
        end
        OpenStruct.new(answers: ans)
      end
    end
    audit_contradictory = Llm::PiiShadowAuditor.audit_masked_message!(
      'Лексемопроба', account_id: account.id, decision_client: contradictory_client
    )
    expect(audit_contradictory[:quarantined]).to be_empty
    expect(Llm::PiiNameLexicon.unambiguous_single_name?('Лексемопроба', account_id: account.id)).to be(false)

    Llm::PiiShadowAuditor.reset_stats!
    flagged_client = Class.new do
      def self.choose(questions:, **)
        ans = questions.to_h do |k, _|
          [k, OpenStruct.new(choice: k == 'overall' ? 'missed_patient_name' : 'patient_last_name', confidence: 0.95)]
        end
        OpenStruct.new(answers: ans)
      end
    end
    audit_flagged = Llm::PiiShadowAuditor.audit_masked_message!(
      'Редкофамилия', account_id: account.id, decision_client: flagged_client
    )
    expect(audit_flagged[:quarantined].map { |x| x[:word] }).to include('Редкофамилия')
    expect(Llm::PiiNameLexicon.unambiguous_single_name?('Редкофамилия', account_id: account.id)).to be(false)
    expect(Llm::PiiNameLexicon.unambiguous_single_name?('Редкофамилия', account_id: other_account.id)).to be(false)

    # 4. Routing profile `only` + `Llm::Config.api_key(:openrouter, account:)` + transient retry & cross-worker Redis dedup
    routed_opts = Llm::PiiShadowAuditor.compile_decision_request_options(
      account_id: account.id, account: account, privacy_profile: 'zdr_required',
      runtime_preferences: { openrouter_provider_only: ['synthetic-approved-provider'] }
    )
    expect(routed_opts[:provider][:only]).to eq(['synthetic-approved-provider'])
    allow(Llm::Config).to receive(:api_key).with(:openrouter, account: account).and_return('acct-scoped-key')
    expect(Llm::PiiShadowAuditor.send(:resolve_api_key, account, account.id)).to eq('acct-scoped-key')

    RSpec::Mocks.space.proxy_for(Llm::OpenRouterDecisionClient).reset
    attempts = 0
    allow(Llm::OpenRouterDecisionClient).to receive(:choose) do |**_opts|
      attempts += 1
      raise Llm::OpenRouterDecisionClient::Error, 'transient' if attempts == 1

      OpenStruct.new(answers: { 'overall' => OpenStruct.new(choice: 'clean', confidence: 0.99) })
    end
    expect { Llm::PiiShadowAuditJob.new.perform('Повторпроверка', account_id: account.id) }
      .to raise_error(Llm::OpenRouterDecisionClient::Error)
    retry_res = Llm::PiiShadowAuditJob.new.perform('Повторпроверка', account_id: account.id)
    expect(retry_res[:status]).to eq(:completed)
    expect(attempts).to eq(2)

    # 5. Atomic lease ownership on inflight/complete/release & fail-closed on Redis error
    expect(Llm::PiiShadowAuditor.acquire_inflight_audit!('lease-digest-1', lease_token: 'owner-1')).to be(true)
    expect(Llm::PiiShadowAuditor.acquire_inflight_audit!('lease-digest-1', lease_token: 'owner-2')).to be(false)
    expect(Llm::PiiShadowAuditor.release_inflight_audit!('lease-digest-1', lease_token: 'owner-2')).to be(false)
    expect(Llm::PiiShadowAuditor.mark_audited_digest!('lease-digest-1', lease_token: 'owner-2')).to be(false)
    expect(Llm::PiiShadowAuditor.release_inflight_audit!('lease-digest-1', lease_token: 'owner-1')).to be(true)
    expect(Llm::PiiShadowAuditor.acquire_inflight_audit!('lease-digest-1', lease_token: 'owner-2')).to be(true)
    expect(Llm::PiiShadowAuditor.mark_audited_digest!('lease-digest-1', lease_token: 'owner-2')).to be(true)
    expect(Llm::PiiShadowAuditor.acquire_inflight_audit!('lease-digest-1', lease_token: 'owner-3')).to be(false)

    # 6. Enqueue failure compensation when perform_later returns false (ActiveJob::EnqueueError) or crosses a minute boundary
    allow(Llm::PiiShadowAuditJob).to receive(:perform_later).and_return(false)
    expect(Llm::PiiShadowAuditor.enqueue_shadow_audit!('Адаптеротказфраза', account_id: account.id)).to be(false)
    allow(Llm::PiiShadowAuditJob).to receive(:perform_later).and_return(OpenStruct.new(successfully_enqueued?: true))
    expect(Llm::PiiShadowAuditor.enqueue_shadow_audit!('Адаптеротказфраза', account_id: account.id)).to be(true)

    old_min = 2_000_000
    allow(Llm::PiiShadowAuditor).to receive(:current_minute_bucket).and_return(old_min)
    allow(Llm::PiiShadowAuditJob).to receive(:perform_later) do |*_args, **_kwargs|
      allow(Llm::PiiShadowAuditor).to receive(:current_minute_bucket).and_return(old_min + 1)
      raise StandardError, 'enqueue boom across minute boundary'
    end
    expect(Llm::PiiShadowAuditor.enqueue_shadow_audit!('Границаминутыфраза', account_id: account.id)).to be(false)
    rate_windows = Llm::PiiShadowAuditor.instance_variable_get(:@rate_windows)
    expect(rate_windows["#{account.id}:#{old_min}"].to_i).to eq(0)
    expect(rate_windows["#{account.id}:#{old_min + 1}"].to_i).to eq(0)

    # Promoting quarantine activates only for `account.id`, never for `other_account.id`
    expect(Llm::PiiNameLexicon.promote_quarantined_word!('Редкофамилия', category: :last_name, account_id: account.id, verified: true)).to be(true)
    expect(Llm::PiiNameLexicon.unambiguous_single_name?('Редкофамилия', account_id: account.id)).to be(true)
    expect(Llm::PiiNameLexicon.unambiguous_single_name?('Редкофамилия', account_id: other_account.id)).to be(false)
  end

  # rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
end
