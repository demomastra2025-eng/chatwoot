require 'rails_helper'

RSpec.describe Captain::SkillCatalog do
  around do |example|
    Rails.cache.clear
    example.run
    Rails.cache.clear
  end

  describe '.all' do
    it 'discovers skills from configured directories and exposes preview tree metadata' do
      Dir.mktmpdir do |dir|
        skill_dir = File.join(dir, 'skills', 'support')
        FileUtils.mkdir_p(File.join(skill_dir, 'references'))
        File.write(
          File.join(skill_dir, 'SKILL.md'),
          <<~MARKDOWN
            ---
            name: Support Flow
            description: Handles support escalation behavior.
            ---
            Use account-specific escalation policy.
          MARKDOWN
        )
        File.write(File.join(skill_dir, 'references', 'handoff.md'), 'Escalate to a human when needed.')
        FileUtils.mkdir_p(File.join(skill_dir, 'scripts'))
        File.write(File.join(skill_dir, 'scripts', 'summarize.rb'), 'puts STDIN.read')
        File.write(
          File.join(skill_dir, 'skill.json'),
          JSON.generate(
            scripts: [
              {
                id: 'summarize',
                title: 'Summarize',
                description: 'Summarize skill input.',
                command: 'scripts/summarize.rb',
                runtime: 'ruby',
                risk: 'low',
                parameters: {
                  type: 'object',
                  properties: {
                    text: { type: 'string' }
                  },
                  required: ['text']
                }
              },
              {
                id: 'escape',
                command: '../escape.rb',
                runtime: 'ruby'
              }
            ]
          )
        )

        with_modified_env('CAPTAIN_SKILL_DIRS' => dir) do
          skills = described_class.all
          skill = skills.find { |entry| entry[:id] == 'support-flow' }

          expect(skill).to include(
            title: 'Support Flow',
            description: 'Handles support escalation behavior.',
            group_name: 'Skills'
          )
          expect(skill[:content]).to include('Use account-specific escalation policy.')
          expect(skill[:tree]).to include(hash_including(path: 'references', type: 'directory'))
          expect(skill[:tree]).to include(hash_including(path: 'references/handoff.md', type: 'file'))
          expect(skill[:scripts]).to contain_exactly(
            hash_including(
              id: 'summarize',
              title: 'Summarize',
              runtime: 'ruby',
              command: 'scripts/summarize.rb',
              risk_level: 'low',
              requires_confirmation: false,
              parameters_schema: hash_including('required' => ['text'])
            )
          )
        end
      end
    end
  end

  describe '.script_tools_for' do
    it 'returns tool metadata for allowlisted skill scripts' do
      Dir.mktmpdir do |dir|
        skill_dir = File.join(dir, 'support')
        FileUtils.mkdir_p(File.join(skill_dir, 'scripts'))
        File.write(
          File.join(skill_dir, 'SKILL.md'),
          <<~MARKDOWN
            ---
            name: Support Flow
            description: Handles support escalation behavior.
            ---
            Escalate with context.
          MARKDOWN
        )
        File.write(File.join(skill_dir, 'scripts', 'summarize.rb'), 'puts STDIN.read')
        File.write(
          File.join(skill_dir, 'skill.json'),
          JSON.generate(scripts: [{ id: 'summarize', command: 'scripts/summarize.rb', runtime: 'ruby', risk: 'medium' }])
        )

        with_modified_env('CAPTAIN_SKILL_DIRS' => dir) do
          tools = described_class.script_tools_for(skill_ids: ['support-flow'])

          expect(tools).to contain_exactly(
            hash_including(
              provider: 'skill_script',
              skill_id: 'support-flow',
              skill_script_id: 'summarize',
              risk_level: 'medium',
              requires_confirmation: true,
              selected_by_default: false
            )
          )
          expect(described_class.script_for_tool_id(tools.first[:id])[:command]).to eq('scripts/summarize.rb')
        end
      end
    end
  end

  describe '.extract_skill_ids_from_text' do
    it 'normalizes markdown skill references' do
      text = 'Use [Support Flow](skill://support-flow) and [RU](skill://Русский Навык).'

      expect(described_class.extract_skill_ids_from_text(text)).to eq(['support-flow', 'skill-50afd9149324'])
    end
  end

  describe '.render_skill_references' do
    it 'renders skill links as plain prompt references' do
      text = 'Follow [Support Flow](skill://support-flow).'

      expect(described_class.render_skill_references(text)).to eq('Follow `Support Flow` skill.')
    end
  end

  describe '.prompt_blocks_for' do
    it 'returns prompt-ready skill content for referenced ids only' do
      Dir.mktmpdir do |dir|
        skill_dir = File.join(dir, 'support')
        FileUtils.mkdir_p(skill_dir)
        File.write(
          File.join(skill_dir, 'SKILL.md'),
          <<~MARKDOWN
            ---
            name: Support Flow
            description: Handles support escalation behavior.
            ---
            Escalate with context.
          MARKDOWN
        )

        with_modified_env('CAPTAIN_SKILL_DIRS' => dir) do
          blocks = described_class.prompt_blocks_for(account: nil, skill_ids: ['support-flow', 'missing'])

          expect(blocks).to contain_exactly(
            hash_including(
              id: 'support-flow',
              title: 'Support Flow',
              content: 'Escalate with context.'
            )
          )
        end
      end
    end
  end
end
