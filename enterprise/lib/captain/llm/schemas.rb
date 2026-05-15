# frozen_string_literal: true

require 'ruby_llm/schema'

module Captain
  module Llm
    module Schemas
      class FaqItem < RubyLLM::Schema
        string :question, description: 'The FAQ question'
        string :answer, description: 'The FAQ answer'
      end

      class FaqCollection < RubyLLM::Schema
        array :faqs, of: FaqItem, description: 'Generated FAQ entries'
      end

      class NoteCollection < RubyLLM::Schema
        array :notes, of: :string, description: 'Generated CRM notes'
      end

      class SearchTermCollection < RubyLLM::Schema
        array :search_terms, of: :string, description: 'Generated help center search terms'
      end

      class ContactAttributeItem < RubyLLM::Schema
        string :attribute, description: 'Contact attribute key'

        any_of :value, description: 'Contact attribute value' do
          string
          number
          boolean
          null
        end
      end

      class ContactAttributeCollection < RubyLLM::Schema
        array :attributes, of: ContactAttributeItem, description: 'Generated contact attributes'
      end

      class PaginatedFaqChunk < RubyLLM::Schema
        array :faqs, of: FaqItem, description: 'FAQ entries found in the current chunk'
        boolean :has_content, description: 'Whether the processed chunk still has meaningful document content'
      end

      class WebsiteAnalysis < RubyLLM::Schema
        string :business_name, description: 'The detected business or brand name'
        string :suggested_assistant_name, description: 'Suggested friendly assistant name'
        string :description, description: 'High-level assistant persona and business scope'
      end

      class CopilotUiAction < RubyLLM::Schema
        string :type,
               description: 'Whitelisted dashboard UI action type such as open_contact, open_deal, ' \
                            'open_assistant_settings, open_custom_tool_editor, or create_task'
        string :label, description: 'Short button label for the support agent'
        string :target_id,
               description: 'Entity ID string, empty for list/settings pages, or compact JSON for prefill/admin actions'
      end

      class CopilotResponse < RubyLLM::Schema
        string :reasoning, description: 'Why the copilot chose this response'
        string :content, description: 'The response content for the operator'
        boolean :reply_suggestion, description: 'Whether this content is a suggested reply to send to the customer'
        array :ui_actions,
              of: CopilotUiAction,
              description: 'Safe dashboard navigation actions for the operator. Return [] when no UI navigation is needed.'
      end
    end
  end
end
