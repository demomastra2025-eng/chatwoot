# frozen_string_literal: true

class Whatsapp::TemplateLanguageResolver
  LANGUAGE_SUFFIX_PATTERN = /_(?:[a-z]{2}(?:_[a-z]{2})?)\z/i

  def initialize(reminder:, template_params:, conversation: nil)
    @reminder = reminder
    @template_params = (template_params || {}).deep_stringify_keys
    @conversation = conversation
  end

  def call
    return @template_params if @template_params['name'].blank?
    return @template_params if account&.bilingual_templates_enabled?

    approved_templates = available_approved_templates
    return @template_params if approved_templates.empty?

    expected_body_count = expected_body_param_count(approved_templates)
    candidate_languages.each do |target_lang|
      matched = find_matching_template(approved_templates, target_lang, expected_body_count)
      next unless matched

      return @template_params.merge(
        'name' => matched['name'],
        'language' => matched['language'],
        'category' => matched['category'].presence || @template_params['category']
      ).compact
    end

    @template_params
  end

  private

  def account
    @reminder.account
  end

  def inbox
    @reminder.target_inbox || @conversation&.inbox || @reminder.conversation&.inbox
  end

  def contact
    @reminder.target_contact ||
      @reminder.remindable.try(:patient_contact) ||
      @reminder.remindable.try(:contact) ||
      @conversation&.contact ||
      @reminder.conversation&.contact
  end

  def candidate_languages
    [
      contact&.preferred_client_language,
      account&.primary_client_language,
      @template_params['language']
    ].filter_map { |lang| Whatsapp::SupportedLanguages.normalize_code(lang) }.uniq
  end

  def available_approved_templates
    channel = inbox&.channel
    return [] unless channel.respond_to?(:message_templates)

    Array(channel.message_templates).filter_map do |tpl|
      normalized = tpl.is_a?(Hash) ? tpl.deep_stringify_keys : nil
      normalized if normalized && normalized['status'].to_s.upcase == 'APPROVED'
    end
  end

  def expected_body_param_count(approved_templates)
    processed_body = @template_params.dig('processed_params', 'body')
    return processed_body.size if processed_body.is_a?(Hash) || processed_body.is_a?(Array)

    configured = approved_templates.find do |tpl|
      tpl['name'].to_s.casecmp?(@template_params['name'].to_s) &&
        Whatsapp::SupportedLanguages.normalize_code(tpl['language']) == Whatsapp::SupportedLanguages.normalize_code(@template_params['language'])
    end
    configured ? template_body_param_count(configured) : nil
  end

  def template_body_param_count(template)
    body_comp = Array(template['components']).find { |c| c.to_h['type'].to_s.upcase == 'BODY' }
    text = body_comp.to_h['text'].to_s
    text.scan(/\{\{\s*(\d+)\s*\}\}/).flatten.uniq.size
  end

  def find_matching_template(approved_templates, target_lang, expected_body_count)
    configured_name = @template_params['name'].to_s
    base_name = configured_name.sub(LANGUAGE_SUFFIX_PATTERN, '')
    candidate_names = [
      "#{base_name}_#{target_lang.downcase}",
      configured_name,
      base_name
    ].uniq

    candidate_names.each do |candidate_name|
      matched = approved_templates.find do |tpl|
        tpl['name'].to_s.casecmp?(candidate_name) &&
          Whatsapp::SupportedLanguages.normalize_code(tpl['language']) == target_lang &&
          (expected_body_count.nil? || template_body_param_count(tpl) == expected_body_count)
      end
      return matched if matched
    end

    nil
  end
end
