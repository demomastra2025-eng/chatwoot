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

  describe '.available_ids' do
    it 'falls back to file skills after an account query error without aborting the caller transaction' do
      account = create(:account)
      invalid_account_skills = account.captain_skills.select('captain_skills.codex_savepoint_missing_column')
      allow(account).to receive(:captain_skills).and_return(invalid_account_skills)
      # PostgreSQL rejects the unknown column while the statement is prepared, which happens before Rails
      # instruments sql.active_record, so observe the database error itself where the query is loaded.
      query_error = nil
      allow(invalid_account_skills).to receive(:ordered).and_wrap_original do |ordered|
        ordered.call.tap do |relation|
          allow(relation).to receive(:map).and_wrap_original do |map, *args, &block|
            map.call(*args, &block)
          rescue ActiveRecord::StatementInvalid => e
            query_error = e
            raise
          end
        end
      end

      Dir.mktmpdir do |dir|
        skill_dir = File.join(dir, 'fallback-skill')
        FileUtils.mkdir_p(skill_dir)
        File.write(
          File.join(skill_dir, 'SKILL.md'),
          <<~MARKDOWN
            ---
            name: Fallback Skill
            description: Keeps file skills available when the account catalog query fails.
            ---
            Use this local skill.
          MARKDOWN
        )

        with_modified_env('CAPTAIN_SKILL_DIRS' => dir) do
          ActiveRecord::Base.transaction do
            expect(described_class.available_ids(account: account)).to include('fallback-skill')
            expect(ActiveRecord::Base.connection.select_value('SELECT 1')).to eq(1)
          end
        end
      end

      expect(query_error).to be_a(ActiveRecord::StatementInvalid)
      expect(query_error.cause).to be_a(PG::UndefinedColumn)
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

    it 'falls back to direct file discovery when Rails cache write fails' do
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
          JSON.generate(scripts: [{ id: 'summarize', command: 'scripts/summarize.rb', runtime: 'ruby', risk: 'low' }])
        )

        with_modified_env('CAPTAIN_SKILL_DIRS' => dir) do
          allow(Rails.cache).to receive(:fetch).and_raise(Errno::ENOENT, 'rb_file_s_rename')
          allow(Rails.logger).to receive(:warn)

          tools = described_class.script_tools_for(skill_ids: ['support-flow'])

          expect(tools).to contain_exactly(hash_including(provider: 'skill_script', skill_id: 'support-flow'))
          expect(Rails.logger).to have_received(:warn).with(
            a_string_including('Captain::SkillCatalog cache unavailable; rebuilding without cache')
          )
        end
      end
    end

    it 'does not build preview trees while compiling runtime tool metadata' do
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
          JSON.generate(scripts: [{ id: 'summarize', command: 'scripts/summarize.rb', runtime: 'ruby', risk: 'low' }])
        )

        with_modified_env('CAPTAIN_SKILL_DIRS' => dir) do
          allow(described_class).to receive(:tree_for).and_raise('tree building should not run in runtime path')

          expect(described_class.script_tools_for(skill_ids: ['support-flow']).pluck(:skill_id)).to eq(['support-flow'])
        end
      end
    end
  end

  describe '.extract_skill_ids_from_text' do
    it 'normalizes markdown skill references' do
      text = 'Use [Support Flow](skill://support-flow) and [RU](skill://Русский Навык).'

      expect(described_class.extract_skill_ids_from_text(text)).to eq(%w[support-flow skill-50afd9149324])
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
          blocks = described_class.prompt_blocks_for(account: nil, skill_ids: %w[support-flow missing])

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
