# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Knowledge::FaqMergerService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:other_assistant) { create(:captain_assistant, account: account) }

  describe '.merge_records!' do
    it 'merges duplicate FAQs losslessly into one canonical approved FAQ and updates the Knowledge Graph' do
      canonical_faq = create(
        :captain_assistant_response,
        account: account, assistant: assistant, status: :approved, visibility: :personal,
        allowed_assistant_ids: [assistant.id],
        question: 'УЗИ органов брюшной полости (ОБП) в клинике?',
        answer: "RU: Стоимость УЗИ брюшной полости — 7 000 ₸. Проводит Кудлай Сергей Павлович в каб. №217.\n" \
                'KZ: Құрсақ қуысының УДЗ бағасы — 7 000 ₸.'
      )
      duplicate_faq = create(
        :captain_assistant_response,
        account: account, assistant: assistant, status: :pending, visibility: :personal,
        allowed_assistant_ids: [other_assistant.id],
        question: 'Как подготовиться к УЗИ брюшной полости?',
        answer: "RU: Стоимость УЗИ брюшной полости — 7 000 ₸. Подготовка: строго натощак — 6–8 часов без еды и воды.\n" \
                'KZ: Дайындық: аш қарынға 6–8 сағат.'
      )

      merged = described_class.merge_records!([canonical_faq, duplicate_faq], use_llm: false)
      service_node = Captain::KnowledgeNode.find_by(account_id: account.id, node_type: 'service', canonical_name: 'УЗИ брюшной полости')

      expect(merged.id).to eq(canonical_faq.id)
      expect(merged.answer).to include('Кудлай Сергей Павлович', '6–8 часов без еды и воды', '6–8 сағат')
      expect(merged.allowed_assistant_ids).to contain_exactly(assistant.id, other_assistant.id)
      expect(Captain::AssistantResponse.exists?(duplicate_faq.id)).to be(false)
      expect(service_node.attributes_data).to include('primary_price_kzt' => 7000, 'preparation' => a_string_including('6–8 часов'))
      expect(service_node.evidence_response_ids).to eq([canonical_faq.id])
    end
  end

  describe '.canonicalize_on_approve!' do
    it 'merges a newly approved pending FAQ into an existing approved duplicate instead of creating a duplicate' do
      existing = create(
        :captain_assistant_response,
        account: account,
        assistant: assistant,
        status: :approved,
        question: 'Как подготовиться к УЗИ брюшной полости?',
        answer: 'Исследование проводится строго натощак — 6–8 часов без еды.'
      )
      pending_dup = create(
        :captain_assistant_response,
        account: account,
        assistant: assistant,
        status: :pending,
        question: 'Какая подготовка нужна к УЗИ брюшной полости?',
        answer: 'Исследование проводится строго натощак — 6–8 часов без еды. За 2 дня исключить газообразующие продукты.'
      )

      result = described_class.canonicalize_on_approve!(pending_dup, use_llm: false)

      expect(result.id).to eq(existing.id)
      expect(result.status).to eq('approved')
      expect(result.answer).to include('6–8 часов без еды', 'исключить газообразующие продукты')
      expect(Captain::AssistantResponse.exists?(pending_dup.id)).to be(false)
    end

    it 'does not merge FAQs with different numbers or distinct medical services' do
      mri_brain = create(
        :captain_assistant_response,
        account: account,
        assistant: assistant,
        status: :approved,
        question: 'Проводится ли МРТ головного мозга?',
        answer: 'МРТ головного мозга стоит 22 000 ₸.'
      )
      mri_spine = create(
        :captain_assistant_response,
        account: account,
        assistant: assistant,
        status: :pending,
        question: 'Проводится ли МРТ позвоночника?',
        answer: 'МРТ позвоночника стоит 24 000 ₸.'
      )

      result = described_class.canonicalize_on_approve!(mri_spine, use_llm: false)

      expect(result.id).to eq(mri_spine.id)
      expect(result.status).to eq('approved')
      expect(Captain::AssistantResponse.exists?(mri_brain.id)).to be(true)
      expect(Captain::AssistantResponse.exists?(mri_spine.id)).to be(true)
    end
  end

  describe '.deduplicate_scope!' do
    it 'clusters and merges duplicate approved FAQs while preserving unique ones' do
      faq1 = create(
        :captain_assistant_response,
        account: account,
        assistant: assistant,
        status: :approved,
        question: 'Сколько стоит ЭКГ в клинике?',
        answer: 'Стоимость ЭКГ — 3 500 ₸.'
      )
      faq2 = create(
        :captain_assistant_response,
        account: account,
        assistant: assistant,
        status: :approved,
        question: 'Какая цена на ЭКГ в клинике?',
        answer: 'Стоимость ЭКГ — 3 500 ₸. Расшифровка выдается сразу.'
      )
      unique_faq = create(
        :captain_assistant_response,
        account: account,
        assistant: assistant,
        status: :approved,
        question: 'Есть ли в клинике уролог?',
        answer: 'Да, принимает взрослый уролог с 18 лет.'
      )

      summary = described_class.deduplicate_scope!(account.captain_assistant_responses.approved, use_llm: false)

      expect(summary[:merged_clusters_count]).to eq(1)
      expect(summary[:removed_duplicates_count]).to eq(1)
      expect(summary[:canonical_records].map(&:id)).to contain_exactly(faq1.id, unique_faq.id)
      expect(faq1.reload.answer).to include('Расшифровка выдается сразу')
      expect(Captain::AssistantResponse.exists?(faq2.id)).to be(false)
    end
  end

  describe 'the semantic neighbour' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:merger) { described_class.new(account) }

    def faq(question, vector, model_name: 'google/gemini-embedding-001')
      create(:captain_assistant_response, account: account, assistant: assistant, question: question, answer: 'Ответ', status: :approved)
        .tap { |record| record.update_columns(embedding: vector, embedding_model: model_name) } # rubocop:disable Rails/SkipsModelValidations
    end

    it 'is a FAQ at cosine similarity 0.95 or more: different FAQs written from one template are 0.88-0.92 close' do
      record = faq('Где принимает врач А?', unit_vector(0))
      template_twin = faq('Где принимает врач Б?', vector_at(0, 0.92))
      paraphrase = faq('Где ведёт приём врач А?', vector_at(0, 0.97))

      ids = merger.send(:semantic_duplicate_ids, record, account.captain_assistant_responses.where.not(id: record.id))

      expect(ids).to eq(Set[paraphrase.id])
      expect(ids).not_to include(template_twin.id)
      expect(described_class::EMBEDDING_DUPLICATE_DISTANCE).to eq(0.05)
    end

    it 'is searched only among the FAQs whose vector the model of the record made, and not at all for a record without a model' do
      record = faq('Где принимает врач А?', unit_vector(0))
      same_model = faq('Где ведёт приём врач А?', vector_at(0, 0.97))
      faq('Где врач А принимает?', vector_at(0, 0.99), model_name: 'text-embedding-3-large')
      scope = account.captain_assistant_responses.where.not(id: record.id)

      expect(merger.send(:semantic_duplicate_ids, record, scope)).to eq(Set[same_model.id])

      record.update_columns(embedding_model: nil) # rubocop:disable Rails/SkipsModelValidations
      expect(merger.send(:semantic_duplicate_ids, record.reload, scope)).to eq(Set.new)
    end
  end
end
