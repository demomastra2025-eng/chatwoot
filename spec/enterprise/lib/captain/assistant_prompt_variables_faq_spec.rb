# frozen_string_literal: true

require 'rails_helper'

# The FAQ answers that a reply suggestion found for the latest message of the patient (Captain::ReplySuggestion::FaqPreload) reach the
# prompt as a block of their own, labelled as reference text to use only if it matches the question (#variables). All data is synthetic.
RSpec.describe Captain::AssistantPrompt, '#variables' do
  let(:assistant) { create(:captain_assistant) }
  let(:context) { { instruction: 'Clinic rules', global_system_instruction: 'Shared', runtime_tool_ids: %w[faq_lookup] } }
  let(:faq) do
    [{ question: 'Как подготовиться к УЗИ?', answer: "Не есть за 6 часов.\nВзять направление.", score: 0.83 },
     { question: 'Сколько стоит МРТ?', answer: 'От 20 000 ₸.', score: 0.74 }]
  end

  def prompt_variables(preload: { faq: faq }, suggestion: true)
    described_class.new(assistant: assistant, context: context, state: {}, prompt_state: {}, suggestion: suggestion, preload: preload).variables
  end

  def volatile(variables)
    template_variables = variables.merge(reply_suggestion_mode: true, council_part: false, prompt_section: 'volatile', faq_enabled: false,
                                         human_handoff_enabled: false)
    Captain::PromptRenderer.render('assistant', template_variables.with_indifferent_access)
  end

  it 'are lines of question, answer and score, an answer of several lines kept together' do
    expect(prompt_variables[:faq_lines]).to eq(
      ["- Q: Как подготовиться к УЗИ?\n  A: Не есть за 6 часов.\n  Взять направление.\n  (match 0.83)",
       "- Q: Сколько стоит МРТ?\n  A: От 20 000 ₸.\n  (match 0.74)"]
    )
  end

  it 'form a block of their own after the Patient block that says to use an answer only if it matches the question' do
    rendered = volatile(prompt_variables.merge(patient_lines: ['Aigerim, +77000000000.']))

    expect(rendered).to include("# Patient\nAigerim, +77000000000.\n\n# Possibly relevant FAQ\nReference answers of the clinic found for the " \
                                "patient's latest message. Use one only if it answers what the patient asks; otherwise ignore it.")
    expect(rendered).to include("- Q: Сколько стоит МРТ?\n  A: От 20 000 ₸.\n  (match 0.74)")
  end

  it 'leave no block when there are none, and are no variable of the prompt of a conversation' do
    expect(prompt_variables(preload: {})[:faq_lines]).to eq([])
    expect(volatile(prompt_variables(preload: {}))).not_to include('Possibly relevant FAQ')
    expect(prompt_variables(suggestion: false)).not_to have_key(:faq_lines)
  end

  it 'are no source of times for the check of a draft: a knowledge text is no schedule' do
    context_with_faq = { captain_v2_completed_tool_names: ['search_available_slots'], suggestion_preload: { faq: [{ answer: 'Работаем до 21:00' }] } }

    expect(Captain::ReplySuggestion::DraftTimes.unverified(draft: 'Ждём вас в 21:00.', context: context_with_faq)).to eq(['21:00'])
  end
end
