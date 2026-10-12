require 'rails_helper'

RSpec.describe Captain::Assistant, type: :model do
  describe 'message sender payloads' do
    it 'exposes only public identity fields in events and webhooks' do
      assistant = build(:captain_assistant, description: 'Private agent instructions', config: { 'model' => 'private-model' })
      expected = {
        id: assistant.id,
        name: assistant.name,
        avatar_url: assistant.avatar_url,
        created_at: assistant.created_at,
        type: 'captain_assistant'
      }

      expect(assistant.push_event_data).to eq(expected)
      expect(assistant.webhook_data).to eq(expected)
    end
  end

  describe '#use_audio_transcriptions?' do
    it 'defaults to enabled for existing assistants' do
      expect(build(:captain_assistant, config: {}).use_audio_transcriptions?).to be(true)
    end

    it 'ignores the old per-agent disabled capability' do
      expect(build(:captain_assistant, config: { 'use_audio_transcriptions' => false }).use_audio_transcriptions?).to be(true)
    end
  end

  describe '#resolved_agent_model' do
    it 'uses a valid per-assistant model and canonicalizes it at runtime' do
      account = create(:account)
      assistant = build(:captain_assistant, account: account, config: { 'model' => 'openai/gpt-5.4' })
      allow(Llm::Models).to receive(:valid_model_for?)
        .with(:assistant, 'openai/gpt-5.4', account: account).and_return(true)
      allow(Llm::Models).to receive(:canonical_model_name)
        .with('openai/gpt-5.4').and_return('openai/gpt-5.4')

      expect(assistant.resolved_agent_model).to eq('openai/gpt-5.4')
    end

    it 'keeps the shared assistant model fallback when an agent has no model setting' do
      account = create(:account)
      assistant = build(:captain_assistant, account: account, config: {})

      expect(Llm::Config).to receive(:model_for).with(
        feature: :assistant,
        account: account,
        fallback: LlmConstants::DEFAULT_MODEL
      ).and_return('openai/gpt-6-luna')

      expect(assistant.resolved_agent_model).to eq('openai/gpt-6-luna')
    end
  end

  describe 'validations' do
    it { is_expected.to validate_length_of(:description).is_at_most(Captain::Assistant::DESCRIPTION_MAX_LENGTH) }

    it 'allows prompt instructions up to the product limit' do
      assistant = build(:captain_assistant, account: create(:account), description: 'a' * Captain::Assistant::DESCRIPTION_MAX_LENGTH)

      expect(assistant).to be_valid
    end

    it 'preserves prompt line breaks and surrounding whitespace when saved' do
      prompt = "\nUse the customer’s exact account name.\n\n- Keep the heading.\n"
      assistant = create(:captain_assistant, account: create(:account), description: prompt)

      expect(assistant.reload.description).to eq(prompt)
      expect(assistant.system_instruction).to eq(prompt.strip)
    end

    it 'rejects prompt instructions above the product limit' do
      assistant = build(:captain_assistant, account: create(:account), description: 'a' * (Captain::Assistant::DESCRIPTION_MAX_LENGTH + 1))

      expect(assistant).not_to be_valid
      expect(assistant.errors.details[:description]).to include(error: :too_long, count: Captain::Assistant::DESCRIPTION_MAX_LENGTH)
    end

    it 'does not validate the legacy safety settings stored on the agent, because nothing reads them any more' do
      [
        { 'moderation_enabled' => true, 'prompt_injection_action' => 'flag' },
        { 'prompt_injection_action' => 'warn_only' },
        { 'custom_prompt_rule' => true },
        'not an object'
      ].each do |legacy|
        assistant = create(:captain_assistant, account: create(:account), config: { 'safety_settings' => legacy })

        expect(assistant.update(name: 'Renamed')).to be(true)
        expect(assistant.reload.config['safety_settings']).to eq(legacy)
      end
    end

    it 'rejects a model that is not enabled for Captain assistants' do
      account = create(:account)
      model = 'unknown/provider-model'
      allow(Llm::Models).to receive(:valid_model_for?)
        .with(:assistant, model, account: account).and_return(false)
      assistant = build(:captain_assistant, account: account, config: { 'model' => model })

      expect(assistant).not_to be_valid
      expect(assistant.errors.of_kind?(:config, :assistant_model_not_allowed)).to be(true)
    end

    context 'with a short model list curated by the platform' do
      let(:account) { create(:account) }
      let(:listed_model) { 'openai/gpt-5.6-luna' }
      let(:unlisted_model) { 'openai/gpt-6-luna' }

      def curate_list
        upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', JSON.generate([listed_model]))
      end

      it 'accepts a newly chosen model from the list' do
        curate_list

        expect(build(:captain_assistant, account: account, config: { 'model' => listed_model })).to be_valid
      end

      it 'rejects a newly chosen model outside the list' do
        curate_list
        assistant = build(:captain_assistant, account: account, config: { 'model' => unlisted_model })

        expect(assistant).not_to be_valid
        expect(assistant.errors.of_kind?(:config, :assistant_model_not_allowed)).to be(true)
      end

      it 'keeps an agent that already uses a model outside the list valid and editable' do
        stored_assistant = create(:captain_assistant, account: account, config: { 'model' => unlisted_model })
        curate_list
        assistant = described_class.find(stored_assistant.id)

        assistant.name = 'Renamed agent'
        expect(assistant).to be_valid
        expect(assistant.resolved_agent_model).to eq(unlisted_model)

        assistant.config = assistant.config.merge('model' => listed_model)
        expect(assistant).to be_valid
      end

      it 'does not let an agent move to another model outside the list' do
        stored_assistant = create(:captain_assistant, account: account, config: { 'model' => unlisted_model })
        curate_list
        assistant = described_class.find(stored_assistant.id)

        assistant.config = assistant.config.merge('model' => 'gpt-5.1')
        expect(assistant).not_to be_valid
      end
    end

    it 'allows follow-up chains with more than five steps' do
      steps = Array.new(7) do |index|
        { 'mode' => 'static', 'message' => "Follow-up #{index + 1}", 'delay_seconds' => 60 }
      end
      assistant = build(
        :captain_assistant,
        account: create(:account),
        config: { 'follow_up_settings' => { 'enabled' => true, 'steps' => steps } }
      )

      expect(assistant).to be_valid
    end

    it 'allows external assistants with names that do not transliterate into ASCII' do
      assistant = build(:captain_assistant, account: create(:account), name: 'Арманище')

      expect(assistant).to be_valid
      expect(assistant.handoff_target_name).to match(/\Aassistant_[a-f0-9]{12}\z/)
      expect(assistant.handoff_tool_name).to match(/\Ahandoff_to_assistant_[a-f0-9]{12}\z/)
    end

    it 'truncates long external assistant names to stay within the runtime limit' do
      assistant = build(
        :captain_assistant,
        account: create(:account),
        name: 'a' * (Captain::HandoffNaming::MAX_TARGET_NAME_LENGTH + 20)
      )

      expect(assistant).to be_valid
      expect(assistant.handoff_target_name.length).to be <= Captain::HandoffNaming::MAX_TARGET_NAME_LENGTH
      expect(assistant.handoff_tool_name.length).to be <= Captain::HandoffNaming::MAX_TOOL_NAME_LENGTH
    end

    it 'allows internal assistants to keep names that are not handoff-safe' do
      assistant = build(
        :captain_assistant,
        account: create(:account),
        usage_mode: 'internal_assistant',
        name: '!!!'
      )

      expect(assistant).to be_valid
    end

    it 'allows unrelated updates for legacy assistants with already-invalid names' do
      assistant = create(:captain_assistant)
      assistant.update_column(:name, '!!!')

      assistant.description = 'Updated without renaming the assistant.'

      expect { assistant.save! }.not_to raise_error
      expect(assistant.reload.description).to eq('Updated without renaming the assistant.')
    end

    it 'falls back to a stable internal handoff name for legacy assistants with invalid names' do
      assistant = create(:captain_assistant)
      assistant.update_column(:name, '!!!')

      expect(assistant.handoff_target_name).to eq("assistant_#{assistant.id}")
      expect(assistant.handoff_tool_name).to eq("handoff_to_assistant_#{assistant.id}")
      expect(assistant.agent.name).to eq("assistant_#{assistant.id}")
    end

    describe 'Fish voice references' do
      let(:account) { create(:account) }
      let(:assistant) do
        build(
          :captain_assistant,
          account: account,
          config: { 'voice_settings' => { 'provider' => 'fish', 'voice' => provider_model_id } }
        )
      end
      let(:provider_model_id) { Captain::Assistant::FISH_DEFAULT_VOICE_ID }

      def create_fish_voice(account:, state: 'trained', visibility: 'private')
        Telephony::AiVoice::FishVoice.create!(
          account: account,
          provider_model_id: SecureRandom.hex(16),
          title: 'Managed voice',
          state: state,
          visibility: visibility
        )
      end

      it 'accepts the provider default voice without a registry entry' do
        expect(assistant).to be_valid
      end

      it 'accepts a trained private voice owned by the assistant account' do
        voice = create_fish_voice(account: account)
        assistant.config['voice_settings']['voice'] = voice.provider_model_id

        expect(assistant).to be_valid
      end

      it 'rejects cross-account, non-trained, and non-private references', :aggregate_failures do
        other_voice = create_fish_voice(account: create(:account))
        pending_voice = create_fish_voice(account: account, state: 'training')
        public_voice = create_fish_voice(account: account, visibility: 'public')

        [other_voice, pending_voice, public_voice].each do |voice|
          assistant.config['voice_settings']['voice'] = voice.provider_model_id
          expect(assistant).not_to be_valid
          expect(assistant.errors.of_kind?(:config, :fish_voice_invalid_reference)).to be true
        end
      end

      it 'fails closed when an unchanged legacy reference is no longer selectable' do
        voice = create_fish_voice(account: account)
        persisted_assistant = create(
          :captain_assistant,
          account: account,
          config: { 'voice_settings' => { 'provider' => 'fish', 'voice' => voice.provider_model_id } }
        )
        voice.update!(state: 'failed')

        persisted_assistant.description = 'Unrelated change'

        expect(persisted_assistant).not_to be_valid
        expect(persisted_assistant.errors.of_kind?(:config, :fish_voice_invalid_reference)).to be true
      end
    end
  end

  describe 'shared knowledge ownership' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    it 'nullifies assistant ownership for workspace-level knowledge records' do
      %i[documents document_chunks knowledge_answer_cache_entries responses].each do |association_name|
        association = described_class.reflect_on_association(association_name)

        expect(association.options[:dependent]).to eq(:nullify)
      end
    end

    it 'keeps workspace knowledge when an assistant is deleted' do
      document = create(:captain_document, account: account, assistant: assistant)
      chunk = create(:captain_document_chunk, account: account, assistant: assistant, document: document)
      response = create(:captain_assistant_response, account: account, assistant: assistant)
      cache_entry = Captain::KnowledgeAnswerCacheEntry.create!(
        account: account,
        assistant: assistant,
        query: 'shipping policy',
        query_sha256: Digest::SHA256.hexdigest('shipping policy'),
        source_fingerprint: 'shared-workspace-kb',
        payload: { answer: 'Use shared docs.' }
      )

      expect { assistant.destroy }.to change { described_class.exists?(assistant.id) }.from(true).to(false)
      expect(Captain::Document.exists?(document.id)).to be true
      expect(Captain::DocumentChunk.exists?(chunk.id)).to be true
      expect(Captain::AssistantResponse.exists?(response.id)).to be true
      expect(Captain::KnowledgeAnswerCacheEntry.exists?(cache_entry.id)).to be true
      expect(document.reload.assistant_id).to be_nil
      expect(chunk.reload.assistant_id).to be_nil
      expect(response.reload.assistant_id).to be_nil
      expect(cache_entry.reload.assistant_id).to be_nil
    end

    it 'removes assistant-personal knowledge when an assistant is deleted' do
      personal_document = create(:captain_document, account: account, assistant: assistant, visibility: :personal)
      personal_chunk = create(:captain_document_chunk, account: account, assistant: assistant, document: personal_document)
      personal_response = create(:captain_assistant_response, account: account, assistant: assistant, visibility: :personal)

      assistant.destroy

      expect(Captain::Document.exists?(personal_document.id)).to be false
      expect(Captain::DocumentChunk.exists?(personal_chunk.id)).to be false
      expect(Captain::AssistantResponse.exists?(personal_response.id)).to be false
    end
  end

  describe '#runtime_state_for' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:conversation) { create(:conversation, account: account) }

    before do
      account.enable_features!('communication_threads')
    end

    it 'keeps the assistant runtime-state path compatible while delegating to ContextFields' do
      state = assistant.send(:runtime_state_for, conversation)

      expect(state[:conversation]).to include(
        id: conversation.id,
        display_id: conversation.display_id,
        inbox_id: conversation.inbox_id
      )
      expect(state[:contact]).to include(id: conversation.contact_id)
      expect(state[:communication_thread]).to include(
        display_id: conversation.reload.communication_thread.display_id,
        current_conversation_id: conversation.display_id,
        current_channel_key: "conversation:#{conversation.display_id}"
      )
      expect(state).not_to have_key(:channel_type)
    end
  end

  describe '#resolve_runtime_prompt_context' do
    let(:assistant) { create(:captain_assistant) }

    it 'calculates allowed context fields once for the whole nested payload' do
      allowed_fields = [{ id: 'contact.name' }]
      prompt_state = { contact: { 'name' => 'Jane' } }
      context = {
        title: '[Name](field://contact.name)',
        nested: ['plain text', { label: '[Name](field://contact.name)' }]
      }

      allow(assistant).to receive(:allowed_context_fields).with(['contact.name']).and_return(allowed_fields)

      result = assistant.resolve_runtime_prompt_context(context, prompt_state, field_ids: ['contact.name'])

      expect(result).to eq(
        title: 'Name (contact.name: Jane)',
        nested: ['plain text', { label: 'Name (contact.name: Jane)' }]
      )
      expect(assistant).to have_received(:allowed_context_fields).once
    end
  end

  describe 'tool access' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    it 'keeps the default agent runtime on faq and handoff by default' do
      expect(assistant.allowed_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff', 'resolve_conversation')
    end

    it 'keeps the direct agent runtime on faq and handoff by default' do
      expect(assistant.direct_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff', 'resolve_conversation')
    end

    it 'keeps selected FAQ lookup available when FAQ generation is disabled' do
      assistant.update!(config: { 'feature_faq' => false,
                                  'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['faq_lookup'] } } })

      expect(assistant.selected_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff', 'resolve_conversation')
      expect(assistant.allowed_agent_tool_ids).to include('faq_lookup')
      expect(assistant.prompt_runtime_agent_tools.pluck(:id)).to include('faq_lookup')
      expect(assistant.faq_enabled?).to be(true)
    end

    it 'exposes FAQ lookup even when it is not selected in the old agent config' do
      assistant.update!(config: { 'feature_faq' => false,
                                  'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['handoff'] } } })

      expect(assistant.selected_agent_tool_ids).to include('faq_lookup', 'handoff')
      expect(assistant.allowed_agent_tool_ids).to include('faq_lookup', 'handoff')
      expect(assistant.faq_enabled?).to be(true)
    end

    it 'keeps FAQ lookup available when the old agent tool list is empty' do
      assistant.update!(config: { 'feature_faq' => true,
                                  'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => [] } } })

      expect(assistant.selected_agent_tool_ids).to include('faq_lookup', 'handoff')
      expect(assistant.allowed_agent_tool_ids).to include('faq_lookup', 'handoff')
      expect(assistant.faq_enabled?).to be(true)
    end

    it 'keeps scenario default runtime limited to human handoff' do
      expect(assistant.send(:scenario_default_tool_ids)).to eq(['handoff'])
      expect(assistant.scenario_agent_tool_ids).to eq(['handoff'])
    end

    it 'includes enabled custom tools in the assistant scope catalog by default' do
      custom_tool = create(:captain_custom_tool, account: account)

      expect(assistant.available_assistant_tool_ids).to include(custom_tool.slug)
      expect(assistant.allowed_assistant_tool_ids).to include(custom_tool.slug)
    end

    it 'keeps account-private tools scoped to the assistant account only' do
      own_tool = create(:captain_custom_tool, account: account, slug: 'custom_own-tool')
      create(:captain_custom_tool, account: create(:account), slug: 'custom_other-tool')

      expect(assistant.available_tool_ids).to include(own_tool.slug)
      expect(assistant.available_assistant_tool_ids).to include(own_tool.slug)
      expect(assistant.available_tool_ids).not_to include('custom_other-tool')
      expect(assistant.available_assistant_tool_ids).not_to include('custom_other-tool')
    end

    it 'keeps every shared built-in agent tool available in the assistant catalog' do
      # These client-scoped tools act on the customer of the current conversation, which the assistant scope does not have.
      client_scoped_tool_ids = %w[get_my_contact update_my_contact list_my_deals]
      missing_tool_ids = assistant.available_tool_ids - assistant.available_assistant_tool_ids

      expect(missing_tool_ids).to match_array(client_scoped_tool_ids)
      expect(assistant.available_assistant_tool_ids).to include('faq_lookup', 'create_deal', 'create_task', 'create_appointment', 'create_touch')
    end

    it 'builds direct agent runtime tools through the shared tool catalog' do
      allow(Captain::ToolCatalog).to receive(:build_tool).and_call_original

      assistant.send(:agent_tools)

      expect(Captain::ToolCatalog).to have_received(:build_tool).at_least(:once).with(
        hash_including(:id),
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )
    end

    it 'respects configured tool access for both scopes' do
      assistant.update!(
        config: {
          'context_access' => {},
          'tool_access' => {
            'agent' => {
              'enabled' => true,
              'tool_ids' => ['faq_lookup']
            },
            'assistant' => {
              'enabled' => true,
              'tool_ids' => ['search_documentation']
            }
          }
        }
      )

      expect(assistant.allowed_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff', 'resolve_conversation')
      expect(assistant.direct_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff', 'resolve_conversation')
      expect(assistant.allowed_assistant_tool_ids).to eq(['search_documentation'])
    end

    it 'keeps mandatory agent tools when the old agent tool scope is empty' do
      assistant.update!(
        config: {
          'context_access' => {},
          'tool_access' => {
            'agent' => {
              'enabled' => true,
              'tool_ids' => []
            }
          }
        }
      )

      expect(assistant.allowed_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff', 'resolve_conversation')
      expect(assistant.direct_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff', 'resolve_conversation')
      expect(assistant.scenario_agent_tool_ids).to eq(['handoff'])
    end

    it 'keeps checked capability tools in the prompt glossary together with referenced fields' do
      assistant.update!(
        description: 'Use [Handoff to Human](tool://handoff) and greet [Email](field://contact.email).',
        config: {
          'context_access' => {
            'contact' => {
              'enabled' => true,
              'field_ids' => ['contact.name']
            }
          },
          'tool_access' => {
            'agent' => {
              'enabled' => true,
              'tool_ids' => %w[faq_lookup handoff]
            }
          }
        }
      )

      prompt_context = assistant.send(:prompt_context)

      glossary_tool_ids = prompt_context[:tool_glossary].flat_map do |group|
        group[:entries].map { |entry| entry[:id] }
      end
      glossary_field_ids = prompt_context[:context_glossary].flat_map do |group|
        group[:entries].map { |entry| entry[:id] }
      end

      expect(assistant.allowed_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff', 'resolve_conversation')
      expect(glossary_tool_ids).to contain_exactly('faq_lookup', 'handoff', 'resolve_conversation')
      expect(glossary_field_ids).to include('contact.email')
    end

    it 'keeps the always-available handoff and completion tools when instructions mention handoff and the old selection omits it' do
      assistant.description = 'Use [Handoff to Human](tool://handoff) when needed.'
      assistant.config = {
        'context_access' => {},
        'tool_access' => {
          'agent' => {
            'enabled' => true,
            'tool_ids' => ['faq_lookup']
          }
        }
      }

      expect(assistant).to be_valid
      # Human handoff and FAQ lookup are always on for an external agent; resolve_conversation follows the workspace setting (default on).
      expect(assistant.allowed_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff', 'resolve_conversation')
    end

    it 'drops resolve_conversation from the tool set when workspace auto completion is turned off' do
      Captain::AccountSettings.new(account).update!('handoff' => { 'auto_completion_enabled' => false })

      expect(assistant.allowed_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff')
    end

    it 'includes explicitly selected ordinary tools and their required read companions without a prompt mention' do
      account.enable_features!('crm_deals')
      assistant.update!(config: {
        'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => %w[faq_lookup handoff create_deal] } }
      })
      expected = %w[faq_lookup handoff resolve_conversation create_deal get_deal search_deals list_deal_pipelines list_deal_stages
                    list_deal_custom_fields]
      expect(assistant.allowed_agent_tool_ids).to match_array(expected)
      expect(assistant.prompt_runtime_agent_tools.pluck(:id)).to match_array(expected)
    end

    it 'keeps explicitly referenced custom tools in the final runtime tool set' do
      create(
        :captain_custom_tool,
        account: account,
        slug: 'custom_fetch-order',
        title: 'Fetch Order',
        description: 'Gets order details'
      )

      assistant.update!(
        description: 'Use [@Fetch Order](tool://custom_fetch-order) when the customer asks.',
        config: {
          'context_access' => {},
          'tool_access' => {
            'agent' => {
              'enabled' => true,
              'tool_ids' => ['faq_lookup']
            }
          }
        }
      )

      expect(assistant.allowed_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff', 'resolve_conversation', 'custom_fetch-order')
      expect(assistant.prompt_runtime_agent_tools.pluck(:id))
        .to contain_exactly('faq_lookup', 'handoff', 'resolve_conversation', 'custom_fetch-order')

      tools = assistant.send(:agent_tools)
      expect(tools.map(&:class)).to include(Captain::Tools::FaqLookupTool)
      expect(tools.any?(Captain::Tools::HttpTool)).to be(true)
    end

    it 'keeps explicitly referenced non-default built-in tools in the final runtime tool set without extra runtime policy gates' do
      account.enable_features!('crm_deals')

      assistant.update!(
        description: 'Use [@Create Deal](tool://create_deal) when greeted.',
        config: {
          'context_access' => {},
          'tool_access' => {
            'agent' => {
              'enabled' => true,
              'tool_ids' => ['faq_lookup']
            }
          }
        }
      )

      expected_tool_ids = %w[faq_lookup handoff resolve_conversation create_deal get_deal search_deals list_deal_pipelines list_deal_stages
                             list_deal_custom_fields]

      expect(assistant.allowed_agent_tool_ids).to match_array(expected_tool_ids)
      expect(assistant.prompt_runtime_agent_tools.pluck(:id)).to match_array(expected_tool_ids)
      expect(assistant.send(:agent_tools).map(&:name)).to match_array(expected_tool_ids)
    end

    it 'adds the Captain document catalog companion for message tools with artifact attachments' do
      assistant.update!(
        description: 'Use [@Send Message to Conversation](tool://send_message_to_conversation) when the customer asks for a file.',
        config: {
          'context_access' => {},
          'tool_access' => {
            'agent' => {
              'enabled' => true,
              'tool_ids' => ['faq_lookup']
            }
          }
        }
      )

      expect(assistant.allowed_agent_tool_ids).to include('send_message_to_conversation', 'list_captain_documents')
      expect(assistant.prompt_runtime_agent_tools.pluck(:id)).to include('send_message_to_conversation', 'list_captain_documents')
    end

    it 'adds CRM custom-field catalog companions for task and appointment write tools' do
      account.enable_features!('crm_tasks', 'scheduling')

      assistant.update!(
        description: 'Use [@Create Task](tool://create_task) and [@Create Appointment](tool://create_appointment) when needed.',
        config: {
          'context_access' => {},
          'tool_access' => {
            'agent' => {
              'enabled' => true,
              'tool_ids' => ['faq_lookup']
            }
          }
        }
      )

      expect(assistant.allowed_agent_tool_ids).to include(
        'create_task',
        'list_task_custom_fields',
        'create_appointment',
        'list_appointment_custom_fields'
      )
      expect(assistant.prompt_runtime_agent_tools.pluck(:id)).to include('create_task', 'list_task_custom_fields')
      expect(assistant.allowed_agent_tool_ids).not_to include('get_appointment_provider_status')
      expect(assistant.allowed_agent_tools.pluck(:id)).not_to include('get_appointment_provider_status')
      expect(assistant.prompt_runtime_agent_tools.pluck(:id)).not_to include('get_appointment_provider_status')
    end

    it 'keeps already saved provider-status references without offering the tool to patients' do
      account.enable_features!('scheduling')
      description = 'Use [Provider Status](tool://get_appointment_provider_status) when needed.'
      assistant.update_column(:description, description)

      expect(assistant.reload.description).to eq(description)
      expect(assistant.prompt_runtime_agent_tools.pluck(:id)).not_to include('get_appointment_provider_status')
    end

    it 'filters provider status from hash and object tool definitions' do
      visible_tool = { id: 'faq_lookup' }
      tools = [
        visible_tool,
        { id: 'get_appointment_provider_status' },
        { 'id' => 'get_appointment_provider_status' },
        Struct.new(:id).new('get_appointment_provider_status')
      ]
      allow(assistant).to receive(:prompt_visible_tools_for_scope).and_return(tools)

      expect(assistant.prompt_runtime_agent_tools).to eq([visible_tool])
    end

    it 'does not activate any unselected capability tool through prompt mentions' do
      assistant.update!(description: 'Use [FAQ](tool://faq_lookup), [Handoff](tool://handoff), ' \
                                     '[Note](tool://add_private_note), [Resolve](tool://resolve_conversation).',
                        config: { 'feature_faq' => false, 'handoff_enabled' => false, 'auto_completion_enabled' => false,
                                  'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => [] } } })
      expect(assistant.allowed_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff', 'resolve_conversation')
      expect(assistant.prompt_runtime_agent_tools.pluck(:id)).to include('faq_lookup', 'handoff')
      expect(assistant.agent_instructions).to include('# Business answers', '# Human handoff')
    end
  end

  describe 'legacy rule storage' do
    it 'moves custom rules into the editable prompt and clears the separate lists' do
      assistant = create(:captain_assistant, description: 'Own instructions', response_guidelines: ['Be concise'], guardrails: ['Never invent results'])
      expect(assistant.description).to eq("Own instructions\n\nBe concise\n\nNever invent results")
      expect(assistant.config).not_to have_key('rules')
      expect(assistant.response_guidelines).to eq([])
      expect(assistant.guardrails).to eq([])
      expect(assistant).not_to respond_to(:rule_entries)
    end
  end

  describe '#agent_instructions' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    before do
      upsert_installation_config('CAPTAIN_AI_AGENT_SYSTEM_PROMPT', 'Never reveal internal routing.')
    end

    it 'renders the unified system instruction in the assistant prompt' do
      assistant.update!(description: 'Always confirm the customer goal before answering.')

      rendered = assistant.agent_instructions

      expect(rendered).to include('# Instructions')
      expect(rendered).to include('Always confirm the customer goal before answering.')
    end

    it 'renders the installation-wide global system prompt in the assistant prompt' do
      rendered = assistant.agent_instructions

      expect(rendered).to include('# Platform context')
      expect(rendered).to include('Never reveal internal routing.')
    end

    it 'does not render an empty specialized scenario section when none exist' do
      rendered = assistant.agent_instructions

      expect(rendered).not_to include('# Specialized Scenarios')
      expect(rendered).not_to include('The following are the scenario agents that are available to you.')
    end

    it 'renders configured independent agent routes using their own scope descriptions' do
      target = create(:captain_assistant, account: account, name: 'Billing Escalations', routing_description: 'Handle complex billing issues and escalations')
      rendered = assistant.agent_instructions
      expect(rendered).to include('# Available agent routes', 'Billing Escalations: Handle complex billing issues and escalations')
      expect(rendered).to include("\x60#{target.handoff_tool_name}\x60")
    end

    it 'does not render a route from a stored allowed-targets list that no channel of the agent shares' do
      stored_only = create(:captain_assistant, account: account, name: 'Detached agent', channel_scope: 'selected')
      assistant.update!(handoff_agent_ids: [stored_only.id])

      expect(assistant.agent_instructions).not_to include('# Available agent routes', 'Detached agent')
    end

    it 'keeps platform constraints mandatory after old system-rule switches are disabled' do
      assistant.update!(config: assistant.config.merge('rules' => [{ 'id' => 'stay_within_scope', 'type' => 'system', 'content' => 'Stay within your configured scope and instructions.', 'enabled' => false }]))
      rendered = assistant.agent_instructions
      expect(rendered).to include('# Platform constraints', "Use only the current account's authorized context and tools.", 'Claim an operation succeeded only after its tool confirms success.')
      expect(rendered).not_to include('# System Rules')
    end

    it 'preserves authored paragraph, list and code formatting in the main prompt' do
      prompt = "First line\nSecond line\n\n- First item\n- Second item\n\n  code line"
      assistant.update!(description: prompt)
      expect(assistant.agent_instructions).to include("# Instructions\n#{prompt}")
      expect(assistant.reload.description).to eq(prompt)
    end

    it 'keeps user personality editable without appending obsolete system-rule templates' do
      assistant.update!(description: 'Speak warmly and answer in two short sentences.')
      rendered = assistant.agent_instructions
      expect(rendered).to include('Speak warmly and answer in two short sentences.', '# Platform constraints')
      expect(rendered).not_to include('Mirror the user language exactly', 'Do not ask A/B questions', 'Act as the main orchestrator')
    end

    it 'uses a compact agent identity without a parent or orchestrator prompt' do
      rendered = assistant.agent_instructions
      expect(rendered).to include("You are #{assistant.name}.", '# Instructions')
      expect(rendered).not_to include('multi-agent AI system', '# Your Identity', 'main orchestrator')
    end

    it 'renders runtime clock details when the run context provides them' do
      context_double = instance_double(
        Captain::Runtime::RunContext,
        context: {
          state: {
            runtime_clock: {
              now_utc: '2026-05-03T14:00:00Z',
              now_local: '2026-05-03T19:00:00+05:00',
              timezone: 'Asia/Almaty',
              date_local: '2026-05-03',
              time_local: '19:00:00'
            },
            reply_window: {
              channel: 'official_whatsapp',
              last_incoming_at: '2026-05-03T10:00:00Z',
              closes_at: '2026-05-04T10:00:00Z',
              open_now: true
            }
          }
        }
      )

      rendered = assistant.agent_instructions(context_double)

      expect(rendered).to include('# Current Date and Time')
      expect(rendered).to include('Current local time: 2026-05-03T19:00:00+05:00')
      expect(rendered).to include('Timezone: Asia/Almaty')
      expect(rendered).to include('# Official WhatsApp Reply Window')
      expect(rendered).to include('24-hour window closes at: 2026-05-04T10:00:00Z')
    end

    it 'checks configured facts before FAQ and requires human handoff for an unanswered business question only when enabled' do
      assistant.update!(config: assistant.config.merge('feature_faq' => false))
      rendered = assistant.agent_instructions
      expect(rendered).to include('Use the configured instructions, current conversation facts and verified live records',
                                 'If a business answer is missing, use the enabled FAQ lookup.',
                                 'Do not replace verified live records with an older FAQ answer.',
                                 'FAQ lookup has no suitable answer, you must hand off to a human.')
      assistant.update!(config: assistant.config.merge('handoff_enabled' => false))
      expect(assistant.agent_instructions).to include('# Business answers')
      expect(assistant.agent_instructions).to include('you must hand off to a human', '# Human handoff')
    end

    it 'does not present outcome reason IDs or classification instructions to the primary agent' do
      assistant.update!(config: assistant.config.merge('outcome_reason_settings' => {
        'handoff_reasons' => [{ 'id' => 'unique_reason_id', 'label' => 'Unique reason label', 'active' => true }]
      }))
      expect(assistant.agent_instructions).not_to include('unique_reason_id', 'Unique reason label', '# Conversation Outcome Reasons')
    end

    it 'renders the default runtime tools in the prompt glossary' do
      rendered = assistant.agent_instructions

      expect(rendered).to include('# Reference Glossary')
      expect(rendered).to include('FAQ Lookup (faq_lookup): Search FAQ responses using semantic similarity')
      expect(rendered).to include('Handoff to Human (handoff): Hand off the current conversation to a human team')
      expect(rendered).to include('# Human handoff')
    end

    it 'renders referenced fields alongside the effective runtime tool glossary' do
      assistant.update!(
        description: 'Use [FAQ Lookup](tool://faq_lookup) and greet [Name](field://contact.name).',
        response_guidelines: ['Mention [Conversation ID](field://conversation.display_id) when escalation starts.']
      )

      rendered = assistant.agent_instructions

      expect(rendered).to include('# Reference Glossary')
      expect(rendered).to include('Name (contact.name)')
      expect(rendered).to include('Conversation ID (conversation.display_id)')
      expect(rendered).to include('FAQ Lookup (faq_lookup): Search FAQ responses using semantic similarity')
      expect(rendered).to include('Handoff to Human (handoff): Hand off the current conversation to a human team')
      expect(rendered).not_to include('Add Private Note (add_private_note): Add a private note to a conversation')
    end

    it 'handles array-based rules and restrictions when building the prompt glossary' do
      assistant.update!(
        description: 'Start with [Name](field://contact.name).',
        response_guidelines: ['Use [FAQ Lookup](tool://faq_lookup) before replying.'],
        guardrails: ['Never expose [Conversation ID](field://conversation.display_id) to the customer.']
      )

      rendered = assistant.agent_instructions

      expect(rendered).to include('Name (contact.name)')
      expect(rendered).to include('Conversation ID (conversation.display_id)')
      expect(rendered).to include('FAQ Lookup (faq_lookup): Search FAQ responses using semantic similarity')
      expect(rendered).to include('Handoff to Human (handoff): Hand off the current conversation to a human team')
    end

    it 'renders tool references in instructions as readable tool mentions' do
      assistant.update!(
        description: 'Use [FAQ Lookup](tool://faq_lookup) before replying.'
      )

      rendered = assistant.agent_instructions

      expect(rendered).to include('Use `FAQ Lookup` tool before replying.')
      expect(rendered).not_to include('(tool://faq_lookup)')
    end

    it 'renders handoff guidance by default when the capability is enabled in tool access' do
      rendered = assistant.agent_instructions

      expect(rendered).to include('Handoff to Human (handoff): Hand off the current conversation to a human team')
      expect(rendered).to include('# Human handoff')
    end

    it 'renders deal and task context using explicitly passed visible fields' do
      context_double = instance_double(
        Captain::Runtime::RunContext,
        context: {
          state: {
            assistant_config: { 'context_access' => {} },
            prompt_context: {
              deal: {
                'stage_name' => 'Negotiation'
              },
              task: {
                'status_name' => 'In progress'
              },
              visible_fields: {
                deal: ['stage_name'],
                task: ['status_name']
              }
            }
          }
        }
      )

      rendered = assistant.agent_instructions(context_double)

      expect(rendered).to include('Linked Deal Context')
      expect(rendered).to include('Stage Name: Negotiation')
      expect(rendered).to include('Linked Task Context')
      expect(rendered).to include('Status Name: In progress')
    end

    it 'renders appointment context using explicitly passed visible fields' do
      context_double = instance_double(
        Captain::Runtime::RunContext,
        context: {
          state: {
            assistant_config: { 'context_access' => {} },
            prompt_context: {
              appointment: {
                'status' => 'confirmed'
              },
              visible_fields: {
                appointment: ['status']
              }
            }
          }
        }
      )

      rendered = assistant.agent_instructions(context_double)

      expect(rendered).to include('Linked Appointment Context')
      expect(rendered).to include('Status: confirmed')
    end

    it 'renders unified communication thread metadata without changing send tools' do
      context_double = instance_double(
        Captain::Runtime::RunContext,
        context: {
          state: {
            assistant_config: { 'context_access' => {} },
            prompt_context: {
              communication_thread: {
                'display_id' => 12,
                'current_conversation_id' => 34,
                'conversation_ids' => [34, 35],
                'current_channel_key' => 'conversation:34',
                'current_channel' => {
                  'inbox_name' => 'WhatsApp',
                  'channel' => 'Channel::Whatsapp',
                  'channel_key' => 'conversation:34',
                  'can_send_text' => true
                },
                'channels' => [
                  {
                    'channel_key' => 'conversation:34',
                    'inbox_name' => 'WhatsApp',
                    'channel' => 'Channel::Whatsapp',
                    'conversation_id' => 34,
                    'can_send_text' => true,
                    'requires_template' => false
                  }
                ]
              }
            }
          }
        }
      )

      rendered = assistant.agent_instructions(context_double)

      expect(rendered).to include('Unified Communication Thread Context')
      expect(rendered).to include('Communication Thread ID: 12')
      expect(rendered).to include('Linked Conversation IDs: 34, 35')
      expect(rendered).to include('Current Channel Key: conversation:34')
    end

    it 'renders custom attribute labels together with raw keys' do
      context_double = instance_double(
        Captain::Runtime::RunContext,
        context: {
          state: {
            assistant_config: { 'context_access' => {} },
            prompt_context: {
              contact: {
                custom_attributes: {
                  'vip_level' => 'gold'
                }
              },
              contact_custom_attribute_labels: {
                'vip_level' => 'VIP Level'
              }
            }
          }
        }
      )

      rendered = assistant.agent_instructions(context_double)

      expect(rendered).to include('VIP Level (vip_level): gold')
    end
  end

  describe 'instruction and rule reference validation' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    before do
      assistant.update!(
        config: {
          'context_access' => {
            'contact' => {
              'enabled' => true,
              'field_ids' => ['contact.name']
            }
          },
          'tool_access' => {
            'agent' => {
              'enabled' => true,
              'tool_ids' => ['faq_lookup']
            }
          }
        }
      )
    end

    it 'does not enable a handoff tool mentioned in instructions when its checkbox is off' do
      assistant.description = 'Use [Handoff to Human](tool://handoff) if needed.'

      expect(assistant).to be_valid
      expect(assistant.allowed_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff', 'resolve_conversation')
    end

    it 'accepts capability tools in instructions when their checkbox is on' do
      assistant.config['tool_access']['agent']['tool_ids'] = %w[faq_lookup handoff]
      assistant.description = 'Use [Handoff to Human](tool://handoff) if needed.'

      expect(assistant).to be_valid
      expect(assistant.allowed_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff', 'resolve_conversation')
    end

    it 'accepts fields in response guidelines when they are explicitly referenced' do
      assistant.response_guidelines = [
        'Mention [Email](field://contact.email) only when asked.'
      ]

      expect(assistant).to be_valid
      expect(assistant.send(:prompt_context)[:context_glossary].flat_map do |group|
        group[:entries].map do |entry|
          entry[:id]
        end
      end).to include('contact.email')
    end
  end
end
