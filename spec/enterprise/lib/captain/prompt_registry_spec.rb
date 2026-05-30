require 'rails_helper'

RSpec.describe Captain::PromptRegistry do
  before do
    described_class.clear_cache!
  end

  describe '.fetch_task!' do
    it 'loads task prompts from the unified Captain prompt tree' do
      prompt = described_class.fetch_task!('summary')

      expect(prompt).to include('As an AI-powered summarization tool')
    end

    it 'raises a helpful error when the prompt is missing' do
      expect do
        described_class.fetch_task!('missing_prompt')
      end.to raise_error(Captain::PromptRegistry::MissingPromptError, %r{tasks/missing_prompt})
    end
  end

  describe '.resolve' do
    it 'resolves task prompts from the Captain prompt tree' do
      path = described_class.resolve('reply', category: :tasks)

      expect(path.to_s).to end_with('/enterprise/lib/captain/prompts/tasks/reply.liquid')
    end
  end

  describe '.render!' do
    it 'renders variables through the unified Liquid path' do
      prompt = described_class.render!('follow_up', category: :tasks, variables: { action_context: 'reply suggestion' })

      expect(prompt).to include('reply suggestion')
      expect(prompt).to include('help them refine the result')
    end

    it 'reuses cached prompt contents and templates between fetch and render calls' do
      path = described_class.resolve('follow_up', category: :tasks)

      expect(File).to receive(:read).with(path).once.and_call_original

      described_class.fetch_task!('follow_up')
      described_class.render!('follow_up', category: :tasks, variables: { action_context: 'reply suggestion' })
    end
  end

  describe '.render_inline!' do
    it 'renders inline Liquid templates through the shared strict renderer' do
      prompt = described_class.render_inline!('Hello {{ person.name }}', variables: { person: { name: 'Captain' } })

      expect(prompt).to eq('Hello Captain')
    end

    it 'renders reference glossary headings without inherited list indentation' do
      prompt = described_class.render_inline!(
        "{% render 'reference_glossary', context_glossary: context_glossary, tool_glossary: tool_glossary, intro: intro %}",
        variables: {
          intro: 'Use these references.',
          context_glossary: [
            {
              group_name: 'Conversation',
              entries: [
                { title: 'Conversation ID', id: 'conversation.display_id', description: 'conversation.display_id' }
              ]
            }
          ],
          tool_glossary: [
            { group_name: 'Knowledge', entries: [{ title: 'FAQ Lookup', id: 'faq_lookup', description: 'Search FAQ' }] },
            { group_name: 'Conversations', entries: [{ title: 'Add Note', id: 'add_private_note', description: 'Add note' }] },
            { group_name: 'Custom tools', entries: [{ title: 'Fetch Order', id: 'custom_fetch-order', description: 'Gets order details' }] }
          ]
        },
        include_snippets: true
      )

      expect(prompt.lines.select { |line| line.match?(/^\s+#/) }).to be_empty
      expect(prompt).to include("\n## Available Tools\n")
      expect(prompt).to include("\n### Knowledge\n- FAQ Lookup")
      expect(prompt).to include("\n### Conversations\n- Add Note")
      expect(prompt).to include("\n### Custom tools\n- Fetch Order")
    end
  end
end
